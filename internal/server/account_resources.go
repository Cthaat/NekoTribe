package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"github.com/redis/go-redis/v9"
)

var accountResourceSQL = func() map[string]string {
	var spec struct{ SQL map[string]string }
	if err := json.Unmarshal(contracts.AccountResourcesContract, &spec); err != nil {
		panic("invalid account resources contract")
	}
	return spec.SQL
}()

type accountQuota struct {
	Used   *int64 `json:"used_units"`
	Limit  *int64 `json:"limit_units"`
	Window int64  `json:"window_seconds"`
}

type accountUsage struct {
	Quota accountQuota `json:"ai_quota"`
	Media struct {
		Bytes int64 `json:"bytes"`
		Files int64 `json:"files"`
	} `json:"media"`
	History struct {
		Conversations int64 `json:"conversations"`
	} `json:"ai_history"`
}

type exportBookmark struct {
	PostID    int64  `json:"post_id"`
	CreatedAt string `json:"created_at"`
}

type exportPost struct {
	exportBookmark
	Content *string `json:"content"`
}

type accountExport struct {
	Posts     []exportPost     `json:"posts"`
	Bookmarks []exportBookmark `json:"bookmarks"`
}

type accountResourceStore interface {
	AccountUsage(context.Context, int64) (accountUsage, error)
	AccountExport(context.Context, int64) (accountExport, error)
}

func (s OracleSessions) AccountUsage(ctx context.Context, actor int64) (accountUsage, error) {
	var usage accountUsage
	err := s.DB.QueryRowContext(ctx, accountResourceSQL["usage"], sql.Named("user_id", actor)).
		Scan(&usage.Media.Files, &usage.Media.Bytes, &usage.History.Conversations)
	return usage, err
}

func (s OracleSessions) AccountExport(ctx context.Context, actor int64) (accountExport, error) {
	data := accountExport{Posts: []exportPost{}, Bookmarks: []exportBookmark{}}
	bind := sql.Named("user_id", actor)
	err := readAccountRows(ctx, s.DB, accountResourceSQL["posts"], bind, func(rows *sql.Rows) error {
		var post exportPost
		if err := rows.Scan(&post.PostID, &post.Content, &post.CreatedAt); err != nil {
			return err
		}
		data.Posts = append(data.Posts, post)
		return nil
	})
	if err != nil {
		return accountExport{}, err
	}
	err = readAccountRows(ctx, s.DB, accountResourceSQL["bookmarks"], bind, func(rows *sql.Rows) error {
		var bookmark exportBookmark
		if err := rows.Scan(&bookmark.PostID, &bookmark.CreatedAt); err != nil {
			return err
		}
		data.Bookmarks = append(data.Bookmarks, bookmark)
		return nil
	})
	return data, err
}

func readAccountRows(ctx context.Context, db *sql.DB, query string, actor sql.NamedArg, scan func(*sql.Rows) error) error {
	rows, err := db.QueryContext(ctx, query, actor)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		if err := scan(rows); err != nil {
			return err
		}
	}
	return rows.Err()
}

func (l *RedisAIModelQuota) readQuotaUnits(ctx context.Context, scope string) *int64 {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	units, err := l.client.Get(ctx, aiQuotaContract.KeyPrefix+":"+scope).Int64()
	if err == redis.Nil {
		units = 0
	} else if err != nil || units < 0 || units > aiQuotaContract.MaxLimit {
		return nil
	}
	return &units
}

func (e accountExport) markdown() string {
	var out strings.Builder
	out.WriteString("# NekoTribe account export\n\n## Posts\n\n")
	for _, post := range e.Posts {
		fmt.Fprintf(&out, "### Post %d\n\n%s\n\n", post.PostID, post.CreatedAt)
		if post.Content != nil && *post.Content != "" {
			content := strings.NewReplacer("\r\n", "\n", "\r", "\n").Replace(*post.Content)
			fmt.Fprintf(&out, "    %s\n\n", strings.ReplaceAll(content, "\n", "\n    "))
		}
	}
	out.WriteString("## Bookmarks\n\n")
	for _, bookmark := range e.Bookmarks {
		fmt.Fprintf(&out, "- Post %d · %s\n", bookmark.PostID, bookmark.CreatedAt)
	}
	return out.String()
}

func handleAccountResources(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, limiter AIModelQuotaLimiter) bool {
	const usagePath = "/api/v2/users/me/usage"
	const exportPath = "/api/v2/users/me/export"
	path := r.URL.EscapedPath()
	if r.Method != http.MethodGet || (path != usagePath && path != exportPath) {
		return false
	}
	w.Header().Set("Cache-Control", "private, no-store")
	actor, ok := interactionActor(w, r, codec, repository)
	if !ok {
		return true
	}
	format := "json"
	if values, found := r.URL.Query()["format"]; path == exportPath && found {
		if len(values) != 1 || (values[0] != "json" && values[0] != "markdown") {
			respond(w, 400, 40001, "format 参数错误", nil)
			return true
		}
		format = values[0]
	}
	store, ok := repository.(accountResourceStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	if path == usagePath {
		usage, err := store.AccountUsage(r.Context(), actor)
		if err != nil {
			respond(w, 500, 50001, "服务器内部错误", nil)
			return true
		}
		usage.Quota.Window = aiQuotaContract.WindowMilliseconds / 1000
		limit := aiQuotaLimit(os.LookupEnv, "AI_QUOTA_ACTOR_PER_MINUTE", aiQuotaContract.ActorLimit)
		if quota, ok := limiter.(*RedisAIModelQuota); ok {
			limit = quota.actorLimit
			usage.Quota.Used = quota.readQuotaUnits(r.Context(), "actor:"+strconv.FormatInt(actor, 10))
		}
		if limit > 0 {
			usage.Quota.Limit = &limit
		}
		respond(w, 200, 200, "success", usage)
		return true
	}
	data, err := store.AccountExport(r.Context(), actor)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	if format == "markdown" {
		w.Header().Set("Content-Type", "text/markdown; charset=utf-8")
		w.Header().Set("Content-Disposition", `attachment; filename="nekotribe-account.md"`)
		_, _ = io.WriteString(w, data.markdown())
	} else {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Content-Disposition", `attachment; filename="nekotribe-account.json"`)
		_ = json.NewEncoder(w).Encode(data)
	}
	return true
}
