package server

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type groupDissolutionStore interface {
	DissolveGroup(context.Context, int64, int64) error
}

const dissolveGroupSQL = `UPDATE n_groups SET is_deleted=1,is_active=0 WHERE group_id=:group_id AND owner_id=:actor_id AND is_deleted=0`
const dissolveGroupAuditSQL = `INSERT INTO n_group_audit_logs (group_id,actor_id,action) VALUES (:group_id,:actor_id,'delete_group')`

func (s OracleSessions) DissolveGroup(ctx context.Context, actor, group int64) error {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return errSessionStore
	}
	defer tx.Rollback()

	gb := sql.Named("group_id", group)
	var owner, approval, active, deleted int64
	var privacy string
	err = tx.QueryRowContext(ctx, membershipGroupSQL, gb).Scan(&owner, &privacy, &approval, &active, &deleted)
	if errors.Is(err, sql.ErrNoRows) || err == nil && deleted != 0 {
		return &groupMembershipFailure{404, "群组不存在"}
	}
	if err != nil {
		return errSessionStore
	}
	denied := &groupMembershipFailure{422, "只有群主可以解散群组"}
	if owner != actor {
		return denied
	}
	var role, status string
	err = tx.QueryRowContext(ctx, membershipReadSQL, gb, sql.Named("user_id", actor)).Scan(&role, &status)
	if errors.Is(err, sql.ErrNoRows) || err == nil && (role != "owner" || status != "active") {
		return denied
	}
	if err != nil {
		return errSessionStore
	}

	ab := sql.Named("actor_id", actor)
	if writeOneChatRow(ctx, tx, dissolveGroupSQL, gb, ab) != nil ||
		writeOneChatRow(ctx, tx, dissolveGroupAuditSQL, gb, ab) != nil ||
		tx.Commit() != nil {
		return errSessionStore
	}
	return nil
}

func groupDissolutionRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository) bool {
	id, matched := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/groups/")
	if r.Method != http.MethodDelete || !matched || id == "" || strings.Contains(id, "/") {
		return false
	}
	actor, group, valid := interactionIdentity(w, r, codec, repo, id)
	if !valid {
		return true
	}
	store, ok := repo.(groupDissolutionStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	err := store.DissolveGroup(r.Context(), actor, group)
	var failure *groupMembershipFailure
	switch {
	case errors.As(err, &failure):
		respond(w, failure.status, failure.status*100+1, failure.message, nil)
	case err != nil:
		respond(w, 500, 50001, "服务器内部错误", nil)
	default:
		respond(w, 200, 200, "group deleted", nil)
	}
	return true
}
