package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"slices"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

var moderationUsersContract = func() struct {
	Sorts []string
	SQL   string
} {
	var spec struct {
		Sorts []string
		SQL   string
	}
	if err := json.Unmarshal(contracts.ModerationUserQueueContract, &spec); err != nil {
		panic("invalid moderation user queue contract")
	}
	return spec
}()

type moderationQueueUser struct {
	ID               int64   `json:"user_id"`
	Username         string  `json:"username"`
	DisplayName      string  `json:"display_name"`
	AvatarURL        string  `json:"avatar_url"`
	Email            string  `json:"email"`
	Status           string  `json:"status"`
	Active           int64   `json:"is_active"`
	Verified         int64   `json:"is_verified"`
	Followers        int64   `json:"followers_count"`
	Posts            int64   `json:"posts_count"`
	Likes            int64   `json:"likes_count"`
	Reports          int64   `json:"report_count"`
	Restriction      *string `json:"active_restriction"`
	RestrictionUntil *string `json:"restriction_until"`
	Created          string  `json:"created_at"`
	Updated          string  `json:"updated_at"`
}

type moderationUserFilters struct{ Status, Search, Sort string }

type moderationUserQueueStore interface {
	ModerationAllowed(context.Context, int64, moderationPolicy) (bool, error)
	ModerationUsers(context.Context, moderationUserFilters, SessionPage, StorageURLPolicy) ([]moderationQueueUser, int64, error)
}

func (s OracleSessions) ModerationUsers(ctx context.Context, f moderationUserFilters, page SessionPage, storage StorageURLPolicy) ([]moderationQueueUser, int64, error) {
	return readModerationUsers(ctx, s.DB, sql.NullInt64{}, f, page, storage)
}

func readModerationUsers(ctx context.Context, db contentQueueReader, user sql.NullInt64, f moderationUserFilters, page SessionPage, storage StorageURLPolicy) ([]moderationQueueUser, int64, error) {
	rows, err := db.QueryContext(ctx, moderationUsersContract.SQL, sql.Named("status", nullablePostString(f.Status)),
		sql.Named("user_id", user),
		sql.Named("q", nullablePostString(f.Search)), sql.Named("sort", f.Sort),
		sql.Named("start_row", page.Start), sql.Named("end_row", page.End))
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var total int64
	items := []moderationQueueUser{}
	for rows.Next() {
		var id, active, verified, reports sql.NullInt64
		var name, display, avatar, email, state, restriction, until, created, updated sql.NullString
		var item moderationQueueUser
		if err := rows.Scan(&id, &name, &display, &avatar, &email, &state, &active, &verified,
			&item.Followers, &item.Posts, &item.Likes, &reports, &restriction, &until, &created, &updated, &total); err != nil {
			return nil, 0, err
		}
		if id.Int64 <= 0 {
			continue
		}
		item.ID, item.Active, item.Verified, item.Reports = id.Int64, active.Int64, verified.Int64, reports.Int64
		item.Username, item.DisplayName, item.Email, item.Status = name.String, display.String, email.String, state.String
		item.Created, item.Updated = created.String, updated.String
		if restriction.Valid {
			item.Restriction = &restriction.String
		}
		if until.Valid {
			item.RestrictionUntil = &until.String
		}
		item.AvatarURL, err = normalizeAvatarURL(storage, avatar.String)
		if err != nil {
			return nil, 0, err
		}
		items = append(items, item)
	}
	return items, total, rows.Err()
}

func handleModerationUserQueue(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository, config RefreshConfig) bool {
	if r.URL.EscapedPath() != "/api/v2/moderation/users" || r.Method != http.MethodGet {
		return false
	}
	viewer, ok := interactionActor(w, r, codec, repo)
	if !ok {
		return true
	}
	serverError := func() { respond(w, 500, 50001, "服务器内部错误", nil) }
	store, ok := repo.(moderationUserQueueStore)
	if !ok {
		serverError()
		return true
	}
	ctx := r.Context()
	allowed, err := store.ModerationAllowed(ctx, viewer, conversationPolicy(config.ModerationAllowAll, config.ModerationAdminAccounts))
	if err != nil {
		serverError()
		return true
	}
	if !allowed {
		respond(w, 403, 40301, "需要审核权限", nil)
		return true
	}
	params := parseSessionQuery(r.URL.RawQuery)
	filters := moderationUserFilters{
		Status: listQueryString(params, "status", "all"),
		Search: strings.TrimFunc(listQueryString(params, "q", ""), jsTrimSpace),
		Sort:   listQueryString(params, "sort", "newest"),
	}
	if filters.Status == "all" {
		filters.Status = ""
	}
	if !slices.Contains(moderationUsersContract.Sorts, filters.Sort) {
		filters.Sort = "newest"
	}
	page := sessionPagination(params)
	data, total, err := store.ModerationUsers(ctx, filters, page, config.Storage)
	if err != nil {
		serverError()
		return true
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"code": 200, "message": "moderation users listed", "data": data,
		"meta": map[string]any{"page": page.Page, "page_size": page.PageSize, "total": total, "has_next": page.End < float64(total)},
	})
	return true
}
