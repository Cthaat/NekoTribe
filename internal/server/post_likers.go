package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

var postLikersSQL = func() string {
	var statements struct{ List string }
	if err := json.Unmarshal(contracts.PostLikersSQL, &statements); err != nil || statements.List == "" {
		panic("invalid post likers SQL contract")
	}
	return statements.List
}()

type postLikersStore interface {
	ListPostLikers(context.Context, int64, int64, SessionPage) ([]PublicUser, int64, bool, error)
}

func (s OracleSessions) ListPostLikers(ctx context.Context, viewer, id int64, page SessionPage) ([]PublicUser, int64, bool, error) {
	rows, err := s.DB.QueryContext(ctx, postLikersSQL, sql.Named("post_id", id), sql.Named("viewer_id", viewer),
		sql.Named("start_row", page.Start), sql.Named("end_row", page.End))
	if err != nil {
		return nil, 0, false, errSessionStore
	}
	defer rows.Close()
	var found bool
	var total int64
	users := []PublicUser{}
	for rows.Next() {
		found = true
		user, err := scanPublicUser(rows, &total)
		if err != nil {
			return nil, 0, false, errSessionStore
		}
		if user.UserID > 0 {
			users = append(users, user)
		}
	}
	if rows.Err() != nil {
		return nil, 0, false, errSessionStore
	}
	return users, total, found, nil
}

func getPostLikers(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig, raw string) {
	viewer, id, ok := interactionIdentity(w, r, codec, repository, raw)
	if !ok {
		return
	}
	store, ok := repository.(postLikersStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	page := sessionPagination(parseSessionQuery(r.URL.RawQuery))
	users, total, found, err := store.ListPostLikers(r.Context(), viewer, id, page)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !found {
		respond(w, 404, 40401, "帖子不存在", nil)
		return
	}
	for i := range users {
		users[i].AvatarURL, err = normalizeAvatarURL(config.Storage, users[i].AvatarURL)
		if err != nil {
			respond(w, 500, 50001, "服务器内部错误", nil)
			return
		}
	}
	writeRelationshipPage(w, users, total, page)
}
