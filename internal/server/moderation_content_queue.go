package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"slices"
	"sort"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type contentQueueSpec struct {
	Statuses, Priorities, Sorts, Dates []string
	SQL                                map[string]string
}

var contentQueueContract = func() contentQueueSpec {
	var spec contentQueueSpec
	if err := json.Unmarshal(contracts.ModerationContentQueueContract, &spec); err != nil {
		panic("invalid moderation content queue contract")
	}
	return spec
}()

type contentQueueItem struct {
	CaseID          int64              `json:"case_id"`
	PostID          int64              `json:"post_id"`
	Content         string             `json:"content"`
	Author          PublicUser         `json:"author"`
	Media           []PostMedia        `json:"media"`
	ReportCount     int64              `json:"report_count"`
	Reasons         []string           `json:"report_reasons"`
	Reports         []moderationReport `json:"reports"`
	Status          string             `json:"status"`
	Priority        string             `json:"priority"`
	Assigned        *PublicUser        `json:"assigned_to"`
	Created         string             `json:"created_at"`
	Updated         string             `json:"updated_at"`
	Reported        string             `json:"reported_at"`
	Likes           int64              `json:"likes_count"`
	Retweets        int64              `json:"retweets_count"`
	Replies         int64              `json:"replies_count"`
	SentimentSignal *sentimentSignal   `json:"sentiment_signal,omitempty"`
}

type contentQueueFilters struct{ Status, Priority, Reason, Search, Date, Sort string }

type contentQueueStore interface {
	ModerationAllowed(context.Context, int64, moderationPolicy) (bool, error)
	ModerationContent(context.Context, int64, contentQueueFilters, SessionPage, StorageURLPolicy) ([]contentQueueItem, int64, error)
}

type contentQueueRow struct {
	contentQueueItem
	assigned sql.NullInt64
}

type contentQueueReader interface {
	publicProfileQueryer
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
}

func readContentRows(ctx context.Context, db contentQueueReader, viewer int64, post sql.NullInt64, f contentQueueFilters, page SessionPage) ([]contentQueueRow, int64, error) {
	rows, err := db.QueryContext(ctx, contentQueueContract.SQL["list"],
		sql.Named("post_id", post), sql.Named("status", nullablePostString(f.Status)),
		sql.Named("priority", nullablePostString(f.Priority)), sql.Named("reason", nullablePostString(f.Reason)),
		sql.Named("q", nullablePostString(f.Search)), sql.Named("date_range", f.Date), sql.Named("sort", f.Sort),
		sql.Named("viewer_id", viewer), sql.Named("start_row", page.Start), sql.Named("end_row", page.End))
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	items := []contentQueueRow{}
	var total int64
	for rows.Next() {
		var item contentQueueRow
		var id, post, count, likes, retweets, replies sql.NullInt64
		var content, status, priority, created, updated, reported sql.NullString
		author, err := scanPublicUser(rows, &id, &post, &content, &status, &priority, &item.assigned, &count,
			&created, &updated, &reported, &likes, &retweets, &replies, &total)
		if err != nil {
			return nil, 0, err
		}
		if id.Int64 <= 0 {
			continue
		}
		item.CaseID, item.PostID, item.ReportCount = id.Int64, post.Int64, count.Int64
		item.Likes, item.Retweets, item.Replies = likes.Int64, retweets.Int64, replies.Int64
		item.Content, item.Status, item.Priority = content.String, status.String, priority.String
		item.Created, item.Updated, item.Reported = created.String, updated.String, reported.String
		item.Author = author
		items = append(items, item)
	}
	return items, total, rows.Err()
}

func readContentReports(ctx context.Context, db contentQueueReader, post int64) ([]reportRow, error) {
	rows, err := db.QueryContext(ctx, contentQueueContract.SQL["reports"], sql.Named("target_type", "post"), sql.Named("target_id", post))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ignored int64
	var items []reportRow
	for rows.Next() {
		row, err := scanReport(rows, &ignored)
		if err != nil {
			return nil, err
		}
		items = append(items, row)
	}
	return items, rows.Err()
}

func (s OracleSessions) ModerationContent(ctx context.Context, viewer int64, f contentQueueFilters, page SessionPage, storage StorageURLPolicy) ([]contentQueueItem, int64, error) {
	return readModerationContent(ctx, s.DB, viewer, sql.NullInt64{}, f, page, storage)
}

func readModerationContent(ctx context.Context, db contentQueueReader, viewer int64, post sql.NullInt64, f contentQueueFilters, page SessionPage, storage StorageURLPolicy) ([]contentQueueItem, int64, error) {
	rows, total, err := readContentRows(ctx, db, viewer, post, f, page)
	if err != nil {
		return nil, 0, err
	}
	items := make([]contentQueueItem, 0, len(rows))
	for _, row := range rows {
		item := row.contentQueueItem
		item.Author.AvatarURL, err = normalizeAvatarURL(storage, item.Author.AvatarURL)
		if err != nil {
			return nil, 0, err
		}
		item.Media, err = readPostMedia(ctx, db, item.PostID)
		if err != nil {
			return nil, 0, err
		}
		for i := range item.Media {
			if err := normalizePostMedia(storage, &item.Media[i]); err != nil {
				return nil, 0, err
			}
		}
		if row.assigned.Valid {
			user, found, err := readPublicProfile(ctx, db, viewer, row.assigned.Int64)
			if err != nil {
				return nil, 0, err
			}
			if found {
				user.AvatarURL, err = normalizeAvatarURL(storage, user.AvatarURL)
				if err != nil {
					return nil, 0, err
				}
				item.Assigned = &user
			}
		}
		reports, err := readContentReports(ctx, db, item.PostID)
		if err != nil {
			return nil, 0, err
		}
		item.Reports = make([]moderationReport, 0, len(reports))
		item.Reasons = []string{}
		seen := map[string]bool{}
		for _, record := range reports {
			report, err := record.hydrate(ctx, db, viewer, storage)
			if err != nil {
				return nil, 0, err
			}
			item.Reports = append(item.Reports, report)
			if !seen[report.Reason] {
				item.Reasons = append(item.Reasons, report.Reason)
				seen[report.Reason] = true
			}
		}
		sort.Strings(item.Reasons)
		items = append(items, item)
	}
	return items, total, nil
}

func handleModerationContentQueue(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository, config RefreshConfig) bool {
	if r.URL.EscapedPath() != "/api/v2/moderation/content" || r.Method != http.MethodGet {
		return false
	}
	viewer, ok := interactionActor(w, r, codec, repo)
	if !ok {
		return true
	}
	serverError := func() { respond(w, 500, 50001, "服务器内部错误", nil) }
	store, ok := repo.(contentQueueStore)
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
	selectValue := func(key string, allowed []string, fallback, unknown string) string {
		value := listQueryString(params, key, fallback)
		if value == "" || value == "all" {
			return fallback
		}
		if slices.Contains(allowed, value) {
			return value
		}
		return unknown
	}
	spec := contentQueueContract
	filters := contentQueueFilters{
		Status: selectValue("status", spec.Statuses, "", "pending"), Priority: selectValue("priority", spec.Priorities, "", ""),
		Reason: selectValue("reason", moderationReportsContract.Reasons, "", "other"),
		Search: strings.TrimFunc(listQueryString(params, "q", ""), jsTrimSpace),
		Date:   selectValue("date_range", spec.Dates, "all", "all"), Sort: selectValue("sort", spec.Sorts, "newest", "newest"),
	}
	page := sessionPagination(params)
	data, total, err := store.ModerationContent(ctx, viewer, filters, page, config.Storage)
	if err != nil {
		serverError()
		return true
	}
	if option := params["sentiment_signal"]; len(option) == 1 && option[0] == "1" && config.sentiment != nil {
		if source, ok := repo.(contentQueueSentimentSource); ok {
			addContentQueueSentiment(ctx, source, config.sentiment, viewer, data)
		}
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(map[string]any{"code": 200, "message": "moderation content listed", "data": data,
		"meta": map[string]any{"page": page.Page, "page_size": page.PageSize, "total": total, "has_next": page.End < float64(total)}})
	return true
}
