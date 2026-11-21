package server

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"golang.org/x/text/cases"
	"golang.org/x/text/language"
)

type groupMembershipChange interface {
	ChangeGroupMembership(context.Context, int64, int64, bool, string) (*groupMembershipResult, error)
}

type groupMembershipResult struct {
	MemberID int64  `json:"member_id"`
	GroupID  int64  `json:"group_id"`
	UserID   int64  `json:"user_id"`
	Role     string `json:"role"`
	Status   string `json:"status"`
}

type groupMembershipFailure struct {
	status  int
	message string
}

func (e *groupMembershipFailure) Error() string { return e.message }

const membershipGroupSQL = `SELECT owner_id, privacy, join_approval, is_active, is_deleted FROM n_groups WHERE group_id=:group_id FOR UPDATE`
const membershipReadSQL = `SELECT role,status FROM n_group_members WHERE group_id=:group_id AND user_id=:user_id FOR UPDATE`
const membershipInviteSQL = `SELECT invite_id,inviter_id FROM n_group_invites WHERE group_id=:group_id AND invite_code=:invite_code
AND status='pending' AND (invitee_id IS NULL OR invitee_id=:user_id)
AND (max_uses IS NULL OR used_count<max_uses) AND (expires_at IS NULL OR expires_at>=SYSTIMESTAMP)`
const membershipConsumeSQL = `UPDATE n_group_invites SET used_count=used_count+1,
status=CASE WHEN max_uses IS NOT NULL AND used_count+1>=max_uses THEN 'accepted' ELSE status END,
responded_at=CASE WHEN max_uses IS NOT NULL AND used_count+1>=max_uses THEN SYSTIMESTAMP ELSE responded_at END
WHERE invite_id=:invite_id AND group_id=:group_id AND invite_code=:invite_code
AND status='pending' AND (invitee_id IS NULL OR invitee_id=:user_id)
AND (max_uses IS NULL OR used_count<max_uses) AND (expires_at IS NULL OR expires_at>=SYSTIMESTAMP)`
const membershipInsertSQL = `INSERT INTO n_group_members (member_id,group_id,user_id,role,status,invited_by)
VALUES (:member_id,:group_id,:user_id,'member',:status,:invited_by)`
const membershipDeleteSQL = `DELETE FROM n_group_members WHERE group_id=:group_id AND user_id=:user_id AND role<>'owner' AND status<>'banned'`

func (s OracleSessions) ChangeGroupMembership(ctx context.Context, user, group int64, join bool, invite string) (*groupMembershipResult, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, errSessionStore
	}
	defer tx.Rollback()
	gb, ub := sql.Named("group_id", group), sql.Named("user_id", user)
	var owner, approval, active, deleted int64
	var privacy string
	err = tx.QueryRowContext(ctx, membershipGroupSQL, gb).Scan(&owner, &privacy, &approval, &active, &deleted)
	if errors.Is(err, sql.ErrNoRows) || err == nil && join && (active != 1 || deleted != 0) {
		message := "群组不存在"
		if !join {
			message = "成员不存在"
		}
		return nil, &groupMembershipFailure{404, message}
	}
	if err != nil {
		return nil, errSessionStore
	}
	var role, status string
	err = tx.QueryRowContext(ctx, membershipReadSQL, gb, ub).Scan(&role, &status)
	missing := errors.Is(err, sql.ErrNoRows)
	if err != nil && !missing {
		return nil, errSessionStore
	}

	if !join {
		if missing {
			return nil, &groupMembershipFailure{404, "成员不存在"}
		}
		if role == "owner" || user == owner {
			return nil, &groupMembershipFailure{422, "群主不能退出群组"}
		}
		if status == "banned" {
			return nil, &groupMembershipFailure{422, "被封禁的成员不能退出群组"}
		}
		if writeOneChatRow(ctx, tx, membershipDeleteSQL, gb, ub) != nil || tx.Commit() != nil {
			return nil, errSessionStore
		}
		return nil, nil
	}
	if !missing {
		return nil, &groupMembershipFailure{422, "您已经是群组成员"}
	}
	status = "active"
	if privacy != "public" || approval == 1 {
		status = "pending"
	}
	var invitedBy *int64
	if invite != "" {
		code := sql.Named("invite_code", invite)
		var invitation, inviter int64
		err := tx.QueryRowContext(ctx, membershipInviteSQL, gb, code, ub).Scan(&invitation, &inviter)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, &groupMembershipFailure{422, "邀请码无效或已过期"}
		}
		if err != nil {
			return nil, errSessionStore
		}
		result, err := tx.ExecContext(ctx, membershipConsumeSQL, sql.Named("invite_id", invitation), gb, code, ub)
		if err != nil {
			return nil, errSessionStore
		}
		rows, err := result.RowsAffected()
		if err != nil || rows > 1 {
			return nil, errSessionStore
		}
		if rows == 0 {
			return nil, &groupMembershipFailure{422, "邀请码无效或已过期"}
		}
		invitedBy, status = &inviter, "active"
	} else if privacy == "secret" {
		return nil, &groupMembershipFailure{422, "该群组仅限邀请加入"}
	}
	var id int64
	if tx.QueryRowContext(ctx, "SELECT seq_group_member_id.NEXTVAL FROM dual").Scan(&id) != nil || id < 1 || id > maxSocketID {
		return nil, errSessionStore
	}
	if writeOneChatRow(ctx, tx, membershipInsertSQL, sql.Named("member_id", id), gb, ub, sql.Named("status", status), sql.Named("invited_by", invitedBy)) != nil ||
		tx.Commit() != nil {
		return nil, errSessionStore
	}
	return &groupMembershipResult{id, group, user, "member", status}, nil
}

func groupMembershipRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository) bool {
	join := r.Method == http.MethodPost
	if !join && r.Method != http.MethodDelete {
		return false
	}
	path, ok := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/groups/")
	raw, match := strings.CutSuffix(path, "/members/current")
	if !ok || !match || raw == "" || strings.Contains(raw, "/") {
		return false
	}
	user, group, valid := interactionIdentity(w, r, codec, repo, raw)
	if !valid {
		return true
	}
	invite := ""
	if join {
		var err bool
		invite, err = groupInviteBody(r)
		if err {
			respond(w, 400, 40001, "invite_code 参数错误", nil)
			return true
		}
	}
	store, ok := repo.(groupMembershipChange)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	result, err := store.ChangeGroupMembership(r.Context(), user, group, join, invite)
	var failure *groupMembershipFailure
	switch {
	case errors.As(err, &failure):
		respond(w, failure.status, failure.status*100+1, failure.message, nil)
	case err != nil:
		respond(w, 500, 50001, "服务器内部错误", nil)
	case !join:
		respond(w, 200, 200, "left group", nil)
	case result.Status == "pending":
		respond(w, 200, 200, "pending approval", result)
	default:
		respond(w, 200, 200, "joined", result)
	}
	return true
}

func groupInviteBody(r *http.Request) (string, bool) {
	raw, err := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
	if err != nil || len(raw) > 1<<20 {
		return "", true
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		return "", false
	}
	var body map[string]any
	if json.Unmarshal(raw, &body) != nil || body == nil {
		return "", true
	}
	if body["invite_code"] == nil {
		return "", false
	}
	value, ok := body["invite_code"].(string)
	if !ok {
		return "", true
	}
	value = cases.Upper(language.Und).String(strings.TrimFunc(value, jsTrimSpace))
	return value, len(value) > 32
}
