package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"net/url"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type groupListRequest struct {
	mode                      string
	page                      SessionPage
	limit                     float64
	search, privacy, category string
}

type groupListItem struct {
	groupDetail
	ActivityScore *float64 `json:"activity_score,omitempty"`
}

type groupListStore interface {
	ListGroups(context.Context, int64, groupListRequest, StorageURLPolicy) ([]groupListItem, int64, error)
}

const activeGroupWhere = " WHERE g.is_deleted=0 AND g.is_active=1"
const groupListFilter = ` AND (:privacy IS NULL OR g.privacy=:privacy)
 AND (:category IS NULL OR g.category=:category)
 AND (:search IS NULL OR LOWER(g.group_name) LIKE :search OR LOWER(g.description) LIKE :search)`

func (s OracleSessions) ListGroups(ctx context.Context, viewer int64, request groupListRequest, storage StorageURLPolicy) ([]groupListItem, int64, error) {
	from := groupFrom + activeGroupWhere
	order := "g.member_count DESC,g.post_count DESC,g.created_at DESC,g.group_id DESC"
	score := "CAST(NULL AS NUMBER)"
	binds := []any{sql.Named("viewer_id", viewer)}
	if request.mode == "popular" {
		from += " AND g.privacy='public'"
		score = "ROUND(g.member_count*0.3+g.post_count*0.7,2)"
		order = score + " DESC,g.member_count DESC,g.group_id DESC"
	} else {
		from += groupListFilter
		if request.mode == "mine" {
			from += " AND m.status='active'"
			order = "m.joined_at DESC,g.group_id DESC"
		} else {
			from += " AND (g.privacy='public' OR m.status='active')"
		}
		var search any
		if request.search != "" {
			search = "%" + request.search + "%"
		}
		binds = append(binds, sql.Named("privacy", emptyGroupFilter(request.privacy)),
			sql.Named("category", emptyGroupFilter(request.category)), sql.Named("search", search))
	}

	var total int64
	start, end := request.page.Start, request.page.End
	if request.mode == "popular" {
		start, end = 1, request.limit
	} else if err := s.DB.QueryRowContext(ctx, "SELECT COUNT(*) "+from, binds...).Scan(&total); err != nil {
		return nil, 0, errSessionStore
	}
	query := "SELECT * FROM (" + groupColumns + "," + score + " AS activity_score,ROW_NUMBER() OVER (ORDER BY " + order +
		") AS rn " + from + ") WHERE rn BETWEEN :start_row AND :end_row ORDER BY rn"
	binds = append(binds, sql.Named("start_row", start), sql.Named("end_row", end))
	rows, err := s.DB.QueryContext(ctx, query, binds...)
	if err != nil {
		return nil, 0, errSessionStore
	}
	defer rows.Close()
	items := []groupListItem{}
	owners := []int64{}
	for rows.Next() {
		var activity sql.NullFloat64
		var rank int64
		item, owner, err := scanGroupDetail(rows, storage, &activity, &rank)
		if err != nil {
			return nil, 0, err
		}
		items = append(items, groupListItem{item, nullableFloat(activity)})
		owners = append(owners, owner)
	}
	if rows.Err() != nil || rows.Close() != nil {
		return nil, 0, errSessionStore
	}
	for i := range items {
		group, err := s.hydrateGroupDetail(ctx, viewer, items[i].groupDetail, owners[i], storage)
		if err != nil {
			return nil, 0, err
		}
		items[i].groupDetail = group
	}
	return items, total, nil
}

func emptyGroupFilter(value string) any {
	if value == "" {
		return nil
	}
	return value
}

func getGroupFilter(values url.Values, key string) string {
	if len(values[key]) != 1 {
		return ""
	}
	return values[key][0]
}

func groupListRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, storage StorageURLPolicy) bool {
	if r.Method != http.MethodGet {
		return false
	}
	var mode string
	switch r.URL.EscapedPath() {
	case "/api/v2/groups":
		mode = "discover"
	case "/api/v2/groups/popular":
		mode = "popular"
	case "/api/v2/users/me/groups":
		mode = "mine"
	default:
		return false
	}
	viewer, ok := interactionActor(w, r, codec, repository)
	if !ok {
		return true
	}
	values := parseSessionQuery(r.URL.RawQuery)
	list := groupListRequest{mode: mode, page: sessionPagination(values)}
	if mode == "popular" {
		list.limit = math.Min(sessionQueryNumber(values, "limit", 10), 50)
	} else {
		list.search = strings.ToLower(strings.TrimFunc(getGroupFilter(values, "q"), jsTrimSpace))
		list.privacy = getGroupFilter(values, "privacy")
		list.category = strings.TrimFunc(getGroupFilter(values, "category"), jsTrimSpace)
		switch list.category {
		case "", "tech", "game", "music", "art", "life", "study", "work", "other":
		default:
			respond(w, 400, 40001, "category 参数错误", nil)
			return true
		}
	}
	store, ok := repository.(groupListStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	items, total, err := store.ListGroups(r.Context(), viewer, list, storage)
	if errors.Is(err, errGroupOwnerMissing) {
		respond(w, 404, 40401, "用户不存在", nil)
		return true
	}
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	if items == nil {
		items = []groupListItem{}
	}
	var meta any
	if mode == "popular" {
		meta = map[string]float64{"limit": list.limit}
	} else {
		meta = map[string]any{"page": list.page.Page, "page_size": list.page.PageSize, "total": total, "has_next": list.page.End < float64(total)}
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(map[string]any{"code": 200, "message": "success", "data": items, "meta": meta})
	return true
}
