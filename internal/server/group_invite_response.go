package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type groupInviteResponse struct {
	InviteID int64  `json:"invite_id"`
	GroupID  int64  `json:"group_id"`
	Status   string `json:"status"`
}

type directedInviteStore interface {
	MyGroupInvites(context.Context, int64, int64, SessionPage, StorageURLPolicy) ([]groupInviteItem, int64, error)
	RespondGroupInvite(context.Context, int64, int64, bool) (groupInviteResponse, error)
}

const groupInviteInboxSQL = `WITH eligible AS (
 SELECT v.invite_id,v.invite_code,v.status,v.message,v.max_uses,v.used_count,v.expires_at,v.created_at,
 v.group_id,v.group_name,v.group_slug,g.description AS group_description,v.group_avatar_url,v.group_privacy,
 v.group_member_count,v.inviter_id,v.invitee_id,1 AS is_valid,
 ROW_NUMBER() OVER (ORDER BY v.created_at DESC,v.invite_id DESC) AS rn
 FROM v_group_invite_details v JOIN n_groups g ON g.group_id=v.group_id
 WHERE v.invitee_id=:viewer_id AND v.status='pending' AND g.is_active=1 AND g.is_deleted=0
 AND (:invite_id=0 OR v.invite_id=:invite_id)
 AND (v.max_uses IS NULL OR NVL(v.used_count,0)<v.max_uses)
 AND (v.expires_at IS NULL OR v.expires_at>=SYSTIMESTAMP)
)
SELECT 1 AS allowed,t.total,e.invite_id,e.invite_code,e.status,e.message,e.max_uses,e.used_count,
 e.expires_at,e.created_at,e.group_id,e.group_name,e.group_slug,e.group_description,e.group_avatar_url,
 e.group_privacy,e.group_member_count,e.inviter_id,e.invitee_id,e.is_valid
FROM (SELECT COUNT(*) AS total FROM eligible) t
LEFT JOIN eligible e ON e.rn BETWEEN :start_row AND :end_row
ORDER BY e.rn`
const directedInviteLookupSQL = `SELECT group_id FROM n_group_invites WHERE invite_id=:invite_id AND invitee_id=:viewer_id`
const directedInviteLockSQL = `SELECT inviter_id FROM n_group_invites WHERE invite_id=:invite_id AND group_id=:group_id AND invitee_id=:viewer_id
 AND status='pending' AND (max_uses IS NULL OR NVL(used_count,0)<max_uses)
 AND (expires_at IS NULL OR expires_at>=SYSTIMESTAMP) FOR UPDATE`
const directedInviteWriteSQL = `UPDATE n_group_invites SET status=:status, responded_at=SYSTIMESTAMP,
 used_count=CASE WHEN :status='accepted' THEN NVL(used_count,0)+1 ELSE used_count END
 WHERE invite_id=:invite_id AND group_id=:group_id AND invitee_id=:viewer_id
 AND status='pending' AND (max_uses IS NULL OR NVL(used_count,0)<max_uses)
 AND (expires_at IS NULL OR expires_at>=SYSTIMESTAMP)`

func (s OracleSessions) MyGroupInvites(ctx context.Context, viewer, inviteID int64, page SessionPage, storage StorageURLPolicy) ([]groupInviteItem, int64, error) {
	rows, err := s.DB.QueryContext(ctx, groupInviteInboxSQL, sql.Named("viewer_id", viewer), sql.Named("invite_id", inviteID), sql.Named("start_row", page.Start), sql.Named("end_row", page.End))
	if err != nil {
		return nil, 0, errSessionStore
	}
	return s.readGroupInvites(ctx, viewer, rows, storage)
}

func directedInviteDecision(raw []byte) (bool, bool) {
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil || fields == nil {
		return false, false
	}
	accept, hasAccept := fields["accept"]
	legacy, hasLegacy := fields["action"]
	if hasAccept == hasLegacy {
		return false, false
	}
	if hasAccept {
		var value *bool
		if json.Unmarshal(accept, &value) != nil || value == nil {
			return false, false
		}
		return *value, true
	}
	var action string
	if json.Unmarshal(legacy, &action) != nil {
		return false, false
	}
	switch action {
	case "accept":
		return true, true
	case "reject", "decline":
		return false, true
	default:
		return false, false
	}
}

func (s OracleSessions) RespondGroupInvite(ctx context.Context, viewer, id int64, accept bool) (groupInviteResponse, error) {
	out := groupInviteResponse{InviteID: id, Status: "rejected"}
	if accept {
		out.Status = "accepted"
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return out, errSessionStore
	}
	defer tx.Rollback()
	ib := sql.Named("invite_id", id)
	vb := sql.Named("viewer_id", viewer)
	err = tx.QueryRowContext(ctx, directedInviteLookupSQL, ib, vb).Scan(&out.GroupID)
	if errors.Is(err, sql.ErrNoRows) {
		return out, &groupMembershipFailure{404, "邀请不存在"}
	}
	if err != nil {
		return out, errSessionStore
	}
	gb := sql.Named("group_id", out.GroupID)
	var owner, approval, active, deleted int64
	var privacy string
	invalid := &groupMembershipFailure{422, "邀请无效或已过期"}
	err = tx.QueryRowContext(ctx, membershipGroupSQL, gb).Scan(&owner, &privacy, &approval, &active, &deleted)
	if errors.Is(err, sql.ErrNoRows) || err == nil && (active != 1 || deleted != 0) {
		return out, invalid
	}
	if err != nil {
		return out, errSessionStore
	}
	var inviter int64
	err = tx.QueryRowContext(ctx, directedInviteLockSQL, ib, gb, vb).Scan(&inviter)
	if errors.Is(err, sql.ErrNoRows) {
		return out, invalid
	}
	if err != nil {
		return out, errSessionStore
	}
	user := sql.Named("user_id", viewer)
	if accept {
		var role, status string
		err = tx.QueryRowContext(ctx, membershipReadSQL, gb, user).Scan(&role, &status)
		if err == nil {
			return out, &groupMembershipFailure{422, "您已经是群组成员"}
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return out, errSessionStore
		}
	}
	result, err := tx.ExecContext(ctx, directedInviteWriteSQL, sql.Named("status", out.Status), ib, gb, vb)
	if err != nil {
		return out, errSessionStore
	}
	affected, err := result.RowsAffected()
	if err != nil || affected > 1 {
		return out, errSessionStore
	}
	if affected == 0 {
		return out, invalid
	}
	if accept {
		var member int64
		if tx.QueryRowContext(ctx, "SELECT seq_group_member_id.NEXTVAL FROM dual").Scan(&member) != nil || member < 1 || member > maxSocketID {
			return out, errSessionStore
		}
		if writeOneChatRow(ctx, tx, membershipInsertSQL, sql.Named("member_id", member), gb, user, sql.Named("status", "active"), sql.Named("invited_by", inviter)) != nil {
			return out, errSessionStore
		}
	}
	if tx.Commit() != nil {
		return out, errSessionStore
	}
	return out, nil
}

func directedInviteRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository, storage StorageURLPolicy) bool {
	path := r.URL.EscapedPath()
	if path == "/api/v2/users/me/group-invites" && r.Method == http.MethodGet {
		viewer, ok := interactionActor(w, r, codec, repo)
		if !ok {
			return true
		}
		store, ok := repo.(directedInviteStore)
		if !ok {
			groupInviteReadError(w, errSessionStore)
			return true
		}
		query := parseSessionQuery(r.URL.RawQuery)
		var inviteID int64
		if values := query["invite_id"]; len(values) > 0 {
			id, err := strconv.ParseInt(values[0], 10, 64)
			if len(values) != 1 || err != nil || !publicID.MatchString(values[0]) || id > maxSocketID {
				respond(w, 400, 40001, "invite_id 参数错误", nil)
				return true
			}
			inviteID = id
		}
		page := sessionPagination(query)
		items, total, err := store.MyGroupInvites(r.Context(), viewer, inviteID, page, storage)
		if err != nil {
			groupInviteReadError(w, err)
			return true
		}
		writeGroupInvitePage(w, items, total, page)
		return true
	}
	suffix, prefixed := strings.CutPrefix(path, "/api/v2/groups/invites/")
	id, matched := strings.CutSuffix(suffix, "/responses")
	if r.Method != http.MethodPost || !prefixed || !matched || id == "" || strings.Contains(id, "/") {
		return false
	}
	viewer, invite, ok := interactionIdentity(w, r, codec, repo, id)
	if !ok {
		return true
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
	accept, valid := directedInviteDecision(raw)
	if err != nil || len(raw) > 1<<20 || !valid {
		respond(w, 400, 40001, "accept 参数错误", nil)
		return true
	}
	store, ok := repo.(directedInviteStore)
	if !ok {
		groupInviteReadError(w, errSessionStore)
		return true
	}
	out, err := store.RespondGroupInvite(r.Context(), viewer, invite, accept)
	if err != nil {
		groupInviteReadError(w, err)
		return true
	}
	respond(w, 200, 200, "invite "+out.Status, out)
	return true
}
