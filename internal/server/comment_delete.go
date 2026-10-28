package server

import (
	"context"
	"database/sql"
	"errors"
	"net/http"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type commentDeleteResult uint8

const (
	commentMissing commentDeleteResult = iota
	commentNotOwner
	commentDeleted
)

type commentDeleteStore interface {
	DeletePostComment(context.Context, int64, int64) (commentDeleteResult, error)
}

func deletePostComment(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, raw string) {
	user, id, ok := interactionIdentity(w, r, codec, repository, raw)
	if !ok {
		return
	}
	store, ok := repository.(commentDeleteStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	result, err := store.DeletePostComment(r.Context(), user, id)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	switch result {
	case commentMissing:
		respond(w, 404, 40401, "评论不存在", nil)
	case commentNotOwner:
		respond(w, 422, 42201, "只能删除自己的评论", nil)
	case commentDeleted:
		respond(w, 200, 200, "comment deleted", nil)
	default:
		respond(w, 500, 50001, "服务器内部错误", nil)
	}
}

func (s OracleSessions) DeletePostComment(ctx context.Context, user, id int64) (commentDeleteResult, error) {
	const read = `SELECT c.user_id FROM n_comments c JOIN n_posts p ON p.post_id=c.post_id WHERE c.comment_id=:comment_id AND c.is_deleted=0 AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,c.post_id)=1`
	var owner int64
	err := s.DB.QueryRowContext(ctx, read, sql.Named("comment_id", id), sql.Named("viewer_id", user)).Scan(&owner)
	if errors.Is(err, sql.ErrNoRows) {
		return commentMissing, nil
	}
	if err != nil {
		return commentMissing, errSessionStore
	}
	if owner != user {
		return commentNotOwner, nil
	}
	const update = `UPDATE n_comments c SET is_deleted=1 WHERE c.comment_id=:comment_id AND c.user_id=:user_id AND c.is_deleted=0 AND fn_can_view_post(:user_id,c.post_id)=1 AND EXISTS (SELECT 1 FROM n_posts p WHERE p.post_id=c.post_id AND p.is_deleted=0)`
	changed, err := s.execute(ctx, update, sql.Named("comment_id", id), sql.Named("user_id", user))
	if err != nil {
		return commentMissing, err
	}
	if changed == 0 {
		return commentMissing, nil
	}
	return commentDeleted, nil
}
