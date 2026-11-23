package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type homeFeedDefinition struct {
	RecommendationRecency string `json:"recommendationRecency"`
	RecommendationScore   string `json:"recommendationScore"`
	GroupActivity         string `json:"groupActivity"`
}

var homeFeed = func() homeFeedDefinition {
	var definition homeFeedDefinition
	if json.Unmarshal(contracts.HomeFeed, &definition) != nil || definition.RecommendationScore == "" ||
		definition.RecommendationRecency == "" || definition.GroupActivity == "" {
		panic("invalid home feed contract")
	}
	return definition
}()

type groupActivityPost struct {
	groupPost
	GroupName string `json:"group_name"`
}

type groupActivityStore interface {
	ListGroupActivity(context.Context, int64, SessionPage, StorageURLPolicy) ([]groupActivityPost, int64, error)
}

func (s OracleSessions) ListGroupActivity(ctx context.Context, viewer int64, page SessionPage, storage StorageURLPolicy) ([]groupActivityPost, int64, error) {
	conn, err := s.DB.Conn(ctx)
	if err != nil {
		return nil, 0, errSessionStore
	}
	defer conn.Close()
	// The Oracle driver classifies statements by their first keyword.
	query := "SELECT * FROM (" + homeFeed.GroupActivity + ") ORDER BY created_at DESC, post_id DESC"
	rows, err := conn.QueryContext(ctx, query, sql.Named("viewer_id", viewer),
		sql.Named("start_row", page.Start), sql.Named("end_row", page.End))
	if err != nil {
		return nil, 0, errSessionStore
	}
	defer rows.Close()
	type entry struct {
		row  groupPostRow
		name sql.NullString
	}
	var entries []entry
	var allowed, total int64
	for rows.Next() {
		var v entry
		scanner := scannerWithExtra{row: rows, extra: []any{&v.name}}
		if err := v.row.scan(scanner, &allowed, &total); err != nil {
			return nil, 0, errSessionStore
		}
		if v.row.id.Valid {
			entries = append(entries, v)
		}
	}
	if rows.Err() != nil || rows.Close() != nil || allowed != 1 {
		return nil, 0, errSessionStore
	}
	items := make([]groupActivityPost, 0, len(entries))
	for _, entry := range entries {
		post, err := hydrateGroupPost(ctx, conn, viewer, entry.row, storage)
		if err != nil {
			return nil, 0, err
		}
		if err := hydrateGroupPostExtras(ctx, conn, viewer, &post); err != nil {
			return nil, 0, err
		}
		items = append(items, groupActivityPost{groupPost: post, GroupName: entry.name.String})
	}
	return items, total, nil
}

func groupActivityRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository, storage StorageURLPolicy) bool {
	if r.Method != http.MethodGet || r.URL.EscapedPath() != "/api/v2/feed/groups" {
		return false
	}
	viewer, ok := interactionActor(w, r, codec, repo)
	if !ok {
		return true
	}
	store, ok := repo.(groupActivityStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	page := sessionPagination(parseSessionQuery(r.URL.RawQuery))
	items, total, err := store.ListGroupActivity(r.Context(), viewer, page, storage)
	switch {
	case errors.Is(err, errPostPollUnavailable):
		failure := postPollFailure(err)
		respond(w, failure.status, failure.status*100+1, failure.message, nil)
	case errors.Is(err, errPostMarkdownUnavailable):
		failure := postMarkdownFailure(err)
		respond(w, failure.status, failure.status*100+1, failure.message, nil)
	case err != nil:
		respond(w, 500, 50001, "服务器内部错误", nil)
	default:
		meta := map[string]any{"page": page.Page, "page_size": page.PageSize, "total": total, "has_next": page.End < float64(total)}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(map[string]any{"code": 200, "message": "success", "data": items, "meta": meta})
	}
	return true
}
