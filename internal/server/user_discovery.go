package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"math"
	"net/http"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"golang.org/x/text/cases"
	"golang.org/x/text/language"
)

var userDiscoverySQL = func() map[string]string {
	var statements map[string]string
	if err := json.Unmarshal(contracts.UserDiscoverySQL, &statements); err != nil {
		panic("invalid user discovery SQL contract")
	}
	return statements
}()

type userSearch struct {
	page          SessionPage
	pattern, sort string
	verified      int
}

type userDiscoveryStore interface {
	SearchUsers(context.Context, int64, userSearch) ([]PublicUser, int64, error)
	RecommendUsers(context.Context, int64, float64) ([]PublicUser, error)
}

func (s OracleSessions) SearchUsers(ctx context.Context, viewer int64, query userSearch) ([]PublicUser, int64, error) {
	return s.queryDiscoveryUsers(ctx, "search", sql.Named("viewer_id", viewer),
		sql.Named("pattern", query.pattern), sql.Named("sort_mode", query.sort), sql.Named("verified_only", query.verified),
		sql.Named("start_row", query.page.Start), sql.Named("end_row", query.page.End))
}

func (s OracleSessions) RecommendUsers(ctx context.Context, viewer int64, limit float64) ([]PublicUser, error) {
	list, _, err := s.queryDiscoveryUsers(ctx, "recommendations", sql.Named("viewer_id", viewer), sql.Named("row_limit", limit))
	return list, err
}

func (s OracleSessions) queryDiscoveryUsers(ctx context.Context, statement string, args ...any) ([]PublicUser, int64, error) {
	rows, err := s.DB.QueryContext(ctx, userDiscoverySQL[statement], args...)
	if err != nil {
		return nil, 0, errSessionStore
	}
	defer rows.Close()
	people := []PublicUser{}
	var total int64
	for rows.Next() {
		user, err := scanPublicUser(rows, &total)
		if err != nil {
			return nil, 0, errSessionStore
		}
		if user.UserID > 0 {
			people = append(people, user)
		}
	}
	if rows.Err() != nil {
		return nil, 0, errSessionStore
	}
	return people, total, nil
}

func listUserDiscovery(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig, recommended bool) {
	viewer, ok := interactionActor(w, r, codec, repository)
	if !ok {
		return
	}
	store, ok := repository.(userDiscoveryStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	params := parseSessionQuery(r.URL.RawQuery)
	page := sessionPagination(params)
	limit := math.Min(sessionQueryNumber(params, "limit", 10), 50)
	var users []PublicUser
	var total int64
	var err error
	if recommended {
		users, err = store.RecommendUsers(r.Context(), viewer, limit)
	} else {
		sort := listQueryString(params, "sort", "popular")
		if sort != "oldest" && sort != "newest" {
			sort = "popular"
		}
		verified := 0
		if listQueryString(params, "verified", "") == "true" {
			verified = 1
		}
		text := cases.Lower(language.Und).String(strings.TrimFunc(listQueryString(params, "q", ""), jsTrimSpace))
		users, total, err = store.SearchUsers(r.Context(), viewer, userSearch{page: page, pattern: "%" + text + "%", sort: sort, verified: verified})
	}
	if err == nil {
		for i := range users {
			users[i].AvatarURL, err = normalizeAvatarURL(config.Storage, users[i].AvatarURL)
			if err != nil {
				break
			}
		}
	}
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !recommended {
		writeRelationshipPage(w, users, total, page)
		return
	}
	if users == nil {
		users = []PublicUser{}
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(map[string]any{"code": 200, "message": "success", "data": users, "meta": map[string]any{"limit": limit}})
}
