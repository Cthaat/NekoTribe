package server

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"net/url"
	"strconv"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type postBookmarkStore interface {
	SetPostBookmark(context.Context, int64, int64, bool) (bool, error)
}

func interactionIdentity(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, raw string) (int64, int64, bool) {
	user, ok := interactionActor(w, r, codec, repository)
	if !ok {
		return 0, 0, false
	}
	decoded, err := url.PathUnescape(raw)
	if err != nil || !publicID.MatchString(decoded) {
		respond(w, 400, 40001, "id 参数错误", nil)
		return 0, 0, false
	}
	id, err := strconv.ParseInt(decoded, 10, 64)
	if err != nil || id > 9007199254740991 {
		respond(w, 400, 40001, "id 参数错误", nil)
		return 0, 0, false
	}
	return user, id, true
}

func interactionActor(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository) (int64, bool) {
	w.Header().Set("Cache-Control", "private, no-store")
	token := accessToken(r)
	if token == "" {
		respond(w, 401, 40101, "请先登录", nil)
		return 0, false
	}
	claims, err := codec.Verify(token, auth.Access)
	if err != nil {
		respond(w, 401, 40101, "Token无效或已过期", nil)
		return 0, false
	}
	if n, err := repository.Touch(r.Context(), claims); err != nil || n != 1 {
		respond(w, 401, 40101, "Token无效或已过期", nil)
		return 0, false
	}
	return claims.UserID, true
}

func setPostBookmark(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, raw string) {
	viewer, id, valid := interactionIdentity(w, r, codec, repository, raw)
	if !valid {
		return
	}
	store, ok := repository.(postBookmarkStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	saved := r.Method == http.MethodPost
	visible, err := store.SetPostBookmark(r.Context(), viewer, id, saved)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !visible {
		respond(w, 404, 40401, "帖子不存在", nil)
		return
	}
	respond(w, 200, 200, "success", struct {
		PostID int64 `json:"post_id"`
		Saved  bool  `json:"is_bookmarked"`
	}{id, saved})
}

const bookmarkVisibilitySQL = `SELECT p.post_id FROM n_posts p WHERE p.post_id=:post_id AND p.is_deleted=0 AND fn_can_view_post(:user_id,p.post_id)=1`
const insertBookmarkSQL = `INSERT INTO n_post_bookmarks (post_id,user_id) SELECT :post_id,:user_id FROM dual WHERE fn_can_view_post(:user_id,:post_id)=1 AND NOT EXISTS (SELECT 1 FROM n_post_bookmarks WHERE post_id=:post_id AND user_id=:user_id)`
const deleteBookmarkSQL = `DELETE FROM n_post_bookmarks WHERE post_id=:post_id AND user_id=:user_id AND fn_can_view_post(:user_id,:post_id)=1`

func (s OracleSessions) bookmarkVisible(ctx context.Context, viewer, id int64) (bool, error) {
	var found int64
	err := s.DB.QueryRowContext(ctx, bookmarkVisibilitySQL, sql.Named("post_id", id), sql.Named("user_id", viewer)).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, errSessionStore
	}
	return true, nil
}

func (s OracleSessions) SetPostBookmark(ctx context.Context, viewer, id int64, saved bool) (bool, error) {
	visible, err := s.bookmarkVisible(ctx, viewer, id)
	if err != nil || !visible {
		return visible, err
	}
	query := deleteBookmarkSQL
	if saved {
		query = insertBookmarkSQL
	}
	changed, err := s.execute(ctx, query, sql.Named("post_id", id), sql.Named("user_id", viewer))
	if err != nil {
		return false, err
	}
	if changed == 0 {
		return s.bookmarkVisible(ctx, viewer, id)
	}
	return true, nil
}
