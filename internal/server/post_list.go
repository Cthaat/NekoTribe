package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"golang.org/x/text/cases"
	"golang.org/x/text/language"
)

type PostListQuery struct {
	Page                                    SessionPage
	Mode, Timeline, Sort, Search, TagSearch string
	TargetID                                int64
	TagName                                 string
}
type postListStore interface {
	ListVisiblePosts(context.Context, *int64, PostListQuery) ([]PostDetail, int64, error)
}

func listQueryString(values url.Values, key, fallback string) string {
	if len(values[key]) != 1 {
		return fallback
	}
	return values[key][0]
}
func parsePostListQuery(raw string) PostListQuery {
	values := parseSessionQuery(raw)
	search := cases.Lower(language.Und).String(strings.TrimFunc(listQueryString(values, "q", ""), jsTrimSpace))
	tag := strings.TrimFunc(strings.TrimLeft(search, "#"), jsTrimSpace)
	if tag == "" {
		tag = search
	}
	return PostListQuery{Page: sessionPagination(values), Timeline: listQueryString(values, "timeline", "home"), Sort: listQueryString(values, "sort", "newest"), Search: search, TagSearch: tag}
}
func listPosts(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig, mode, rawTarget string) {
	token := accessToken(r)
	var viewer *int64
	if token == "" && mode != "all" && mode != "trending" {
		respond(w, 401, 40101, "请先登录", nil)
		return
	}
	if token != "" {
		claims, err := codec.Verify(token, auth.Access)
		if err != nil {
			respond(w, 401, 40101, "Token无效或已过期", nil)
			return
		}
		if count, err := repository.Touch(r.Context(), claims); err != nil || count != 1 {
			respond(w, 401, 40101, "Token无效或已过期", nil)
			return
		}
		viewer = &claims.UserID
	}
	query := parsePostListQuery(r.URL.RawQuery)
	query.Mode = mode
	if rawTarget != "" {
		target, err := url.PathUnescape(rawTarget)
		if err != nil || !utf8.ValidString(target) || target == "" {
			respond(w, 400, 40001, "id 参数错误", nil)
			return
		}
		if mode == "tag" {
			query.TagName = target
		} else {
			id, err := strconv.ParseInt(target, 10, 64)
			if err != nil || !publicID.MatchString(target) || id > 9007199254740991 {
				respond(w, 400, 40001, "id 参数错误", nil)
				return
			}
			query.TargetID = id
		}
	}
	if mode == "trending" {
		query.Sort = "popular"
	}
	if viewer == nil && (query.Timeline == "following" || query.Timeline == "mentions") {
		respond(w, 401, 40101, "未认证或 token 无效", nil)
		return
	}
	list, ok := repository.(postListStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	rows, total, err := list.ListVisiblePosts(r.Context(), viewer, query)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	items := make([]PostDetail, 0, len(rows))
	if len(rows) > 0 {
		detail, ok := repository.(postDetailStore)
		if !ok {
			respond(w, 500, 50001, "服务器内部错误", nil)
			return
		}
		for _, row := range rows {
			post, failure := hydratePost(r.Context(), detail, viewer, row, config.Storage)
			if failure != nil {
				respond(w, failure.status, failure.status*100+1, failure.message, nil)
				return
			}
			items = append(items, post)
		}
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "private, no-store")
	_ = json.NewEncoder(w).Encode(struct {
		Code    int          `json:"code"`
		Message string       `json:"message"`
		Data    []PostDetail `json:"data"`
		Meta    any          `json:"meta"`
	}{200, "success", items, map[string]any{"page": query.Page.Page, "page_size": query.Page.PageSize, "total": total, "has_next": query.Page.End < float64(total)}})
}

func postListSQL(viewer *int64, query PostListQuery, personalize bool) (string, string, []any, []any) {
	where := " WHERE fn_can_view_post(:viewer_id,v.post_id)=1"
	args := []any{sql.Named("viewer_id", nullableViewer(viewer))}
	switch query.Mode {
	case "me":
		where += " AND v.author_id=:viewer_id"
	case "bookmarks":
		where += " AND EXISTS (SELECT 1 FROM n_post_bookmarks b WHERE b.post_id=v.post_id AND b.user_id=:viewer_id)"
	case "likes":
		where += " AND EXISTS (SELECT 1 FROM n_post_likes l WHERE l.post_id=v.post_id AND l.user_id=:viewer_id)"
	case "user":
		where += " AND v.author_id=:author_id"
		args = append(args, sql.Named("author_id", query.TargetID))
	case "tag":
		where += " AND EXISTS (SELECT 1 FROM n_post_tags pt JOIN n_tags t ON t.tag_id=pt.tag_id WHERE pt.post_id=v.post_id AND t.name_lower=LOWER(:tag_name))"
		args = append(args, sql.Named("tag_name", query.TagName))
	case "replies":
		where += " AND v.reply_to_post_id=:target_post_id"
		args = append(args, sql.Named("target_post_id", query.TargetID))
	case "retweets":
		where += " AND v.repost_of_post_id=:target_post_id"
		args = append(args, sql.Named("target_post_id", query.TargetID))
	}
	switch query.Timeline {
	case "following":
		where += " AND EXISTS (SELECT 1 FROM n_user_follows f WHERE f.follower_id=:viewer_id AND f.following_id=v.author_id AND f.status='active')"
	case "mentions":
		where += " AND EXISTS (SELECT 1 FROM n_post_mentions pm WHERE pm.post_id=v.post_id AND pm.mentioned_user_id=:viewer_id)"
	}
	if query.Search != "" {
		where += " AND (LOWER(DBMS_LOB.SUBSTR(v.content,4000,1)) LIKE :q OR LOWER(NVL(v.location,'')) LIKE :q OR EXISTS (SELECT 1 FROM n_post_tags pt JOIN n_tags t ON t.tag_id=pt.tag_id WHERE pt.post_id=v.post_id AND t.name_lower LIKE :tag_q))"
		args = append(args, sql.Named("q", "%"+query.Search+"%"), sql.Named("tag_q", "%"+query.TagSearch+"%"))
	}
	order := "v.created_at DESC"
	if query.Sort == "oldest" {
		order = "v.created_at ASC"
	} else if query.Sort == "popular" {
		order = "v.engagement_score DESC,v.created_at DESC"
	}
	if query.Mode == "likes" && query.Sort != "popular" {
		direction := "DESC"
		if query.Sort == "oldest" {
			direction = "ASC"
		}
		order = "(SELECT MAX(l.created_at) FROM n_post_likes l WHERE l.post_id=v.post_id AND l.user_id=:viewer_id) " + direction
	}
	recommended := query.Mode == "all" && query.Timeline == "recommended" && query.Search == ""
	if recommended {
		order = homeFeed.RecommendationRecency
		if viewer != nil {
			order = "(" + homeFeed.RecommendationScore + ") DESC, " + order
		}
	}
	if personalize {
		where += " " + recommendationFeedbackSQL.FeedFilter
		order = recommendationFeedbackSQL.FeedOrder + ", " + order
	}
	const separator = " FROM v_post_feed_item v WHERE "
	columns, _, found := strings.Cut(postDetailSQL, separator)
	if !found {
		panic("invalid post detail SQL")
	}
	count := "SELECT COUNT(*) FROM v_post_feed_item v" + where
	rows := "SELECT * FROM (" + columns + ",ROW_NUMBER() OVER (ORDER BY " + order + ") AS rn FROM v_post_feed_item v" + where + ") WHERE rn BETWEEN :start_row AND :end_row"
	if recommended {
		rows += " ORDER BY rn"
	}
	rowArgs := append(append([]any{}, args...), sql.Named("start_row", query.Page.Start), sql.Named("end_row", query.Page.End))
	return count, rows, args, rowArgs
}

func (s OracleSessions) ListVisiblePosts(ctx context.Context, viewer *int64, query PostListQuery) ([]PostDetail, int64, error) {
	var personalize bool
	if viewer != nil && (query.Mode == "all" || query.Mode == "trending") &&
		query.Search == "" && query.Timeline != "mentions" && query.Timeline != "following" {
		var err error
		personalize, err = feedbackSchemaReady(ctx, s.DB)
		if err != nil {
			return nil, 0, errSessionStore
		}
	}
	countSQL, listSQL, countArgs, listArgs := postListSQL(viewer, query, personalize)
	var total int64
	if err := s.DB.QueryRowContext(ctx, countSQL, countArgs...).Scan(&total); err != nil {
		return nil, 0, errSessionStore
	}
	rows, err := s.DB.QueryContext(ctx, listSQL, listArgs...)
	if err != nil {
		return nil, 0, errSessionStore
	}
	items := []PostDetail{}
	for rows.Next() {
		// ROW_NUMBER is deliberately not exposed in the returned object.
		var rank any
		item, _, err := scanPostWithExtra(rows, viewer, &rank)
		if err != nil {
			_ = rows.Close()
			return nil, 0, errSessionStore
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
