package server

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"net/url"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type TagAnalytics struct {
	Name            string  `json:"name"`
	TotalPosts      float64 `json:"total_posts"`
	TotalAuthors    float64 `json:"total_authors"`
	TotalViews      float64 `json:"total_views"`
	TotalLikes      float64 `json:"total_likes"`
	EngagementScore float64 `json:"engagement_score"`
}
type tagAnalyticsStore interface {
	ReadTagAnalytics(context.Context, int64, string) (TagAnalytics, bool, error)
}

const tagAnalyticsSQL = `SELECT t.name,COUNT(DISTINCT p.post_id),COUNT(DISTINCT p.author_id),NVL(SUM(ps.views_count),0),NVL(SUM(ps.likes_count),0),NVL(ROUND(AVG(ps.engagement_score),2),0) FROM n_tags t LEFT JOIN n_post_tags pt ON pt.tag_id=t.tag_id LEFT JOIN n_posts p ON p.post_id=pt.post_id AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,p.post_id)=1 LEFT JOIN n_post_stats ps ON ps.post_id=p.post_id WHERE t.name_lower=LOWER(:name) GROUP BY t.tag_id,t.name`

func tagAnalytics(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, raw string) {
	w.Header().Set("Cache-Control", "private, no-store")
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
	name, err := url.PathUnescape(raw)
	if err != nil || !utf8.ValidString(name) || name == "" {
		respond(w, 400, 40001, "name 参数错误", nil)
		return
	}
	store, ok := repository.(tagAnalyticsStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	data, found, err := store.ReadTagAnalytics(r.Context(), claims.UserID, name)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !found {
		respond(w, 404, 40401, "话题不存在", nil)
		return
	}
	respond(w, 200, 200, "success", data)
}
func (s OracleSessions) ReadTagAnalytics(ctx context.Context, viewer int64, name string) (TagAnalytics, bool, error) {
	var data TagAnalytics
	var value sql.NullString
	var posts, authors, views, likes, score sql.NullFloat64
	err := s.DB.QueryRowContext(ctx, tagAnalyticsSQL, sql.Named("viewer_id", viewer), sql.Named("name", name)).Scan(&value, &posts, &authors, &views, &likes, &score)
	if errors.Is(err, sql.ErrNoRows) {
		return TagAnalytics{}, false, nil
	}
	if err != nil {
		return TagAnalytics{}, false, errSessionStore
	}
	data = TagAnalytics{Name: value.String, TotalPosts: posts.Float64, TotalAuthors: authors.Float64, TotalViews: views.Float64, TotalLikes: likes.Float64, EngagementScore: score.Float64}
	return data, true, nil
}
