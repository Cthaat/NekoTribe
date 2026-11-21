package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type groupOwnershipStore interface {
	TransferGroupOwnership(context.Context, int64, int64, int64) error
}

const demoteGroupOwnerSQL = `UPDATE n_group_members SET role='admin' WHERE group_id=:group_id AND user_id=:user_id AND role='owner' AND status='active'`
const promoteGroupOwnerSQL = `UPDATE n_group_members SET role='owner' WHERE group_id=:group_id AND user_id=:user_id AND role<>'owner' AND status='active'`
const transferGroupOwnershipSQL = `UPDATE n_groups SET owner_id=:new_owner_id WHERE group_id=:group_id AND owner_id=:old_owner_id AND is_active=1 AND is_deleted=0`

func (s OracleSessions) TransferGroupOwnership(ctx context.Context, actor, group, target int64) error {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return errSessionStore
	}
	defer tx.Rollback()

	gb := sql.Named("group_id", group)
	oldMember := sql.Named("user_id", actor)
	newMember := sql.Named("user_id", target)
	var owner, approval, active, deleted int64
	var privacy string
	err = tx.QueryRowContext(ctx, membershipGroupSQL, gb).Scan(&owner, &privacy, &approval, &active, &deleted)
	if errors.Is(err, sql.ErrNoRows) || err == nil && (active != 1 || deleted != 0) {
		return &groupMembershipFailure{404, "群组不存在"}
	}
	if err != nil {
		return errSessionStore
	}
	denied := &groupMembershipFailure{422, "只有群主可以转让群组"}
	if actor != owner {
		return denied
	}
	var role, status string
	err = tx.QueryRowContext(ctx, membershipReadSQL, gb, oldMember).Scan(&role, &status)
	if errors.Is(err, sql.ErrNoRows) || err == nil && (role != "owner" || status != "active") {
		return denied
	}
	if err != nil {
		return errSessionStore
	}
	if actor == target {
		return &groupMembershipFailure{422, "不能转让给自己"}
	}

	err = tx.QueryRowContext(ctx, membershipReadSQL, gb, newMember).Scan(&role, &status)
	if errors.Is(err, sql.ErrNoRows) {
		return &groupMembershipFailure{404, "成员不存在"}
	}
	if err != nil {
		return errSessionStore
	}
	if status != "active" || role == "owner" {
		return &groupMembershipFailure{422, "目标用户不是可接任的活跃成员"}
	}

	if writeOneChatRow(ctx, tx, demoteGroupOwnerSQL, gb, oldMember) != nil ||
		writeOneChatRow(ctx, tx, promoteGroupOwnerSQL, gb, newMember) != nil ||
		writeOneChatRow(ctx, tx, transferGroupOwnershipSQL, gb, sql.Named("old_owner_id", actor), sql.Named("new_owner_id", target)) != nil ||
		writeOneChatRow(ctx, tx, groupAdmissionAuditSQL, gb, sql.Named("actor_id", actor), sql.Named("target_user_id", target),
			sql.Named("action", "transfer_ownership"), sql.Named("details", fmt.Sprintf(`{"from":%d,"to":%d}`, actor, target))) != nil ||
		tx.Commit() != nil {
		return errSessionStore
	}
	return nil
}

func groupOwnershipRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository) bool {
	path, matched := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/groups/")
	id, ownership := strings.CutSuffix(path, "/ownership")
	if r.Method != http.MethodPut || !matched || !ownership || id == "" || strings.Contains(id, "/") {
		return false
	}
	actor, group, valid := interactionIdentity(w, r, codec, repo, id)
	if !valid {
		return true
	}

	raw, err := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
	var fields map[string]json.RawMessage
	var target *float64
	if err != nil || len(raw) > 1<<20 || json.Unmarshal(raw, &fields) != nil ||
		json.Unmarshal(fields["new_owner_id"], &target) != nil || target == nil ||
		*target < 1 || *target > maxSocketID || float64(int64(*target)) != *target {
		respond(w, 400, 40001, "new_owner_id 参数错误", nil)
		return true
	}
	store, ok := repo.(groupOwnershipStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	err = store.TransferGroupOwnership(r.Context(), actor, group, int64(*target))
	var failure *groupMembershipFailure
	switch {
	case errors.As(err, &failure):
		respond(w, failure.status, failure.status*100+1, failure.message, nil)
	case err != nil:
		respond(w, 500, 50001, "服务器内部错误", nil)
	default:
		respond(w, 200, 200, "ownership transferred", map[string]int64{"group_id": group, "owner_id": int64(*target)})
	}
	return true
}
