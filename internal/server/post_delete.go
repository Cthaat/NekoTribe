package server

import (
	"context"
	"database/sql"
	"errors"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"net/http"
)

type postDeleteResult uint8

const (
	postMissing postDeleteResult = iota
	postNotOwner
	postDeleted
)

type postDeleteStore interface {
	DeletePost(context.Context, int64, int64) (postDeleteResult, error)
}

func deletePost(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, raw string) {
	user, id, ok := interactionIdentity(w, r, codec, repository, raw)
	if !ok {
		return
	}
	store, ok := repository.(postDeleteStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	result, err := store.DeletePost(r.Context(), user, id)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	switch result {
	case postMissing:
		respond(w, 404, 40401, "帖子不存在", nil)
	case postNotOwner:
		respond(w, 422, 42201, "只能删除自己的帖子", nil)
	case postDeleted:
		respond(w, 200, 200, "post deleted", nil)
	default:
		respond(w, 500, 50001, "服务器内部错误", nil)
	}
}

func (s OracleSessions) DeletePost(ctx context.Context, user, id int64) (postDeleteResult, error) {
	const read = `SELECT author_id FROM n_posts WHERE post_id=:post_id AND is_deleted=0`
	var owner int64
	err := s.DB.QueryRowContext(ctx, read, sql.Named("post_id", id)).Scan(&owner)
	if errors.Is(err, sql.ErrNoRows) {
		return postMissing, nil
	}
	if err != nil {
		return postMissing, errSessionStore
	}
	if owner != user {
		return postNotOwner, nil
	}
	const update = `UPDATE n_posts SET is_deleted=1 WHERE post_id=:post_id AND author_id=:user_id AND is_deleted=0`
	changed, err := s.execute(ctx, update, sql.Named("post_id", id), sql.Named("user_id", user))
	if err != nil {
		return postMissing, err
	}
	if changed == 0 {
		return postMissing, nil
	}
	if changed != 1 {
		return postMissing, errSessionStore
	}
	return postDeleted, nil
}
