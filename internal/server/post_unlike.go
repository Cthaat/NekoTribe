package server

import (
	"context"
	"database/sql"
	"errors"
	"net/http"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type postUnlikeStore interface {
	RemovePostLike(context.Context, int64, int64) (float64, bool, error)
}

func removePostLike(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, raw string) {
	viewer, id, valid := interactionIdentity(w, r, codec, repository, raw)
	if !valid {
		return
	}
	store, ok := repository.(postUnlikeStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	count, visible, err := store.RemovePostLike(r.Context(), viewer, id)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !visible {
		respond(w, 404, 40401, "帖子不存在", nil)
		return
	}
	respond(w, 200, 200, "success", struct {
		PostID int64   `json:"post_id"`
		Liked  bool    `json:"is_liked"`
		Count  float64 `json:"likes_count"`
	}{id, false, count})
}

const deletePostLikeSQL = `DELETE FROM n_post_likes WHERE post_id=:post_id AND user_id=:user_id AND fn_can_view_post(:user_id,:post_id)=1`
const postLikeCountSQL = `SELECT likes_count FROM n_post_stats WHERE post_id=:post_id`

func (s OracleSessions) RemovePostLike(ctx context.Context, viewer, id int64) (float64, bool, error) {
	visible, err := s.bookmarkVisible(ctx, viewer, id)
	if err != nil || !visible {
		return 0, visible, err
	}
	changed, err := s.execute(ctx, deletePostLikeSQL, sql.Named("post_id", id), sql.Named("user_id", viewer))
	if err != nil {
		return 0, false, err
	}
	if changed == 0 {
		visible, err = s.bookmarkVisible(ctx, viewer, id)
		if err != nil || !visible {
			return 0, visible, err
		}
	}
	var count sql.NullFloat64
	err = s.DB.QueryRowContext(ctx, postLikeCountSQL, sql.Named("post_id", id)).Scan(&count)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, true, nil
	}
	if err != nil {
		return 0, false, errSessionStore
	}
	return count.Float64, true, nil
}
