package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type TagItem struct {
	TagID         int64   `json:"tag_id"`
	Name          string  `json:"name"`
	UsageCount    float64 `json:"usage_count"`
	TrendingScore float64 `json:"trending_score"`
	IsTrending    int64   `json:"is_trending"`
	UpdatedAt     string  `json:"updated_at"`
}
type TagListQuery struct {
	Page     SessionPage
	Q        *string
	Trending bool
}
type tagListStore interface {
	ListTags(context.Context, TagListQuery) ([]TagItem, int64, error)
}

func listTags(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, trending bool) {
	token := accessToken(r)
	if token == "" {
		respond(w, 401, 40101, "请先登录", nil)
		return
	}
	claims, err := codec.Verify(token, auth.Access)
	if err != nil {
		respond(w, 401, 40101, "Token无效或已过期", nil)
		return
	}
	if n, err := repository.Touch(r.Context(), claims); err != nil || n != 1 {
		respond(w, 401, 40101, "Token无效或已过期", nil)
		return
	}
	values := parsePostListQuery(r.URL.RawQuery)
	query := TagListQuery{Page: values.Page, Trending: trending}
	if !trending && values.Search != "" {
		q := "%" + values.Search + "%"
		query.Q = &q
	}
	store, ok := repository.(tagListStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	items, total, err := store.ListTags(r.Context(), query)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if items == nil {
		items = []TagItem{}
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "private, no-store")
	_ = json.NewEncoder(w).Encode(struct {
		Code    int       `json:"code"`
		Message string    `json:"message"`
		Data    []TagItem `json:"data"`
		Meta    any       `json:"meta"`
	}{200, "success", items, map[string]any{"page": query.Page.Page, "page_size": query.Page.PageSize, "total": total, "has_next": query.Page.End < float64(total)}})
}
func tagSQL(query TagListQuery) (string, []any) {
	where := "WHERE (:q IS NULL OR name_lower LIKE :q)"
	args := []any{sql.Named("q", query.Q)}
	if query.Trending {
		where = "WHERE is_trending = 1"
		args = []any{}
	}
	rows := `WITH ranked_tags AS (
	  SELECT tag_id, name, usage_count, trending_score, is_trending, updated_at,
	    ROW_NUMBER() OVER (ORDER BY trending_score DESC, usage_count DESC, updated_at DESC, tag_id DESC) AS rn
	  FROM n_tags ` + where + `
	)
	SELECT p.tag_id, p.name, p.usage_count, p.trending_score, p.is_trending, p.updated_at, totals.total
	FROM (SELECT COUNT(*) AS total FROM ranked_tags) totals
	LEFT JOIN ranked_tags p ON p.rn BETWEEN :start_row AND :end_row
	ORDER BY p.rn`
	return rows, append(args, sql.Named("start_row", query.Page.Start), sql.Named("end_row", query.Page.End))
}
func (s OracleSessions) ListTags(ctx context.Context, query TagListQuery) ([]TagItem, int64, error) {
	rowsSQL, args := tagSQL(query)
	var total int64
	rows, err := s.DB.QueryContext(ctx, rowsSQL, args...)
	if err != nil {
		return nil, 0, errSessionStore
	}
	items := []TagItem{}
	for rows.Next() {
		var item TagItem
		var name sql.NullString
		var usage, score sql.NullFloat64
		var id, trending sql.NullInt64
		var updated sql.NullTime
		if err = rows.Scan(&id, &name, &usage, &score, &trending, &updated, &total); err != nil {
			_ = rows.Close()
			return nil, 0, errSessionStore
		}
		if !id.Valid {
			continue
		}
		item.TagID = id.Int64
		item.Name = name.String
		item.UsageCount = usage.Float64
		item.TrendingScore = score.Float64
		item.IsTrending = trending.Int64
		if value := profileDate(updated); value != nil {
			item.UpdatedAt = *value
		}
		items = append(items, item)
	}
	readErr := rows.Err()
	closeErr := rows.Close()
	if readErr != nil || closeErr != nil {
		return nil, 0, errSessionStore
	}
	return items, total, nil
}
