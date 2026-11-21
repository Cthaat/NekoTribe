package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"math"
	"net/http"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

var contentAnalyticsSQL = func() struct{ Post, Summary, Daily string } {
	var spec struct{ Post, Summary, Daily string }
	if err := json.Unmarshal(contracts.ContentAnalyticsSQL, &spec); err != nil {
		panic("invalid content analytics SQL")
	}
	return spec
}()

var errAnalyticsNotOwner = errors.New("post analytics requires ownership")

type postAnalytics struct {
	PostID          int64   `json:"post_id"`
	ViewsCount      int64   `json:"views_count"`
	LikesCount      int64   `json:"likes_count"`
	CommentsCount   int64   `json:"comments_count"`
	RepliesCount    int64   `json:"replies_count"`
	RetweetsCount   int64   `json:"retweets_count"`
	EngagementScore float64 `json:"engagement_score"`
	LikeRate        float64 `json:"like_rate"`
}

type userAnalytics struct {
	UserID             int64   `json:"user_id"`
	TotalPosts         int64   `json:"total_posts"`
	PostsThisWeek      int64   `json:"posts_this_week"`
	PostsThisMonth     int64   `json:"posts_this_month"`
	TotalLikesReceived int64   `json:"total_likes_received"`
	AvgLikesPerPost    float64 `json:"avg_likes_per_post"`
	TotalLikesGiven    int64   `json:"total_likes_given"`
	TotalCommentsMade  int64   `json:"total_comments_made"`
	EngagementScore    float64 `json:"engagement_score"`
}

type dailyAnalytics struct {
	Day              string `json:"day"`
	PostsCount       int64  `json:"posts_count"`
	LikesReceived    int64  `json:"likes_received"`
	CommentsReceived int64  `json:"comments_received"`
	RetweetsReceived int64  `json:"retweets_received"`
	LikesGiven       int64  `json:"likes_given"`
	CommentsMade     int64  `json:"comments_made"`
	EngagementScore  int64  `json:"engagement_score"`
}

type contentAnalyticsStore interface {
	ReadPostAnalytics(context.Context, int64, int64) (postAnalytics, error)
	ReadUserAnalytics(context.Context, int64, int64) (userAnalytics, error)
	ReadDailyAnalytics(context.Context, int64, int64) ([]dailyAnalytics, error)
}

func (s OracleSessions) ReadPostAnalytics(ctx context.Context, viewer, id int64) (postAnalytics, error) {
	var value postAnalytics
	var owner int64
	var statsID sql.NullInt64
	err := s.DB.QueryRowContext(ctx, contentAnalyticsSQL.Post, sql.Named("target_id", id), sql.Named("viewer_id", viewer)).
		Scan(&value.PostID, &owner, &statsID, &value.ViewsCount, &value.LikesCount, &value.CommentsCount,
			&value.RepliesCount, &value.RetweetsCount, &value.EngagementScore, &value.LikeRate)
	if err != nil {
		return postAnalytics{}, err
	}
	if owner != 1 {
		return postAnalytics{}, errAnalyticsNotOwner
	}
	if !statsID.Valid {
		return postAnalytics{}, sql.ErrNoRows
	}
	return value, nil
}

func (s OracleSessions) ReadUserAnalytics(ctx context.Context, viewer, id int64) (userAnalytics, error) {
	var value userAnalytics
	err := s.DB.QueryRowContext(ctx, contentAnalyticsSQL.Summary, sql.Named("target_id", id), sql.Named("viewer_id", viewer)).
		Scan(&value.UserID, &value.TotalPosts, &value.PostsThisWeek, &value.PostsThisMonth, &value.TotalLikesReceived,
			&value.AvgLikesPerPost, &value.TotalLikesGiven, &value.TotalCommentsMade, &value.EngagementScore)
	return value, err
}

func (s OracleSessions) ReadDailyAnalytics(ctx context.Context, viewer, days int64) ([]dailyAnalytics, error) {
	rows, err := s.DB.QueryContext(ctx, contentAnalyticsSQL.Daily,
		sql.Named("target_id", viewer), sql.Named("viewer_id", viewer), sql.Named("days", days))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var values []dailyAnalytics
	for rows.Next() {
		var row dailyAnalytics
		if err := rows.Scan(&row.Day, &row.PostsCount, &row.LikesReceived, &row.CommentsReceived, &row.RetweetsReceived,
			&row.LikesGiven, &row.CommentsMade, &row.EngagementScore); err != nil {
			return nil, err
		}
		values = append(values, row)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(values) == 0 {
		return nil, sql.ErrNoRows
	}
	return values, nil
}

type analyticsKind int

const (
	postAnalyticsKind analyticsKind = iota
	userAnalyticsKind
	dailyAnalyticsKind
)

func getContentAnalytics(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, raw string, kind analyticsKind) {
	viewer, id, ok := interactionIdentity(w, r, codec, repository, raw)
	if !ok {
		return
	}
	if kind == dailyAnalyticsKind && viewer != id {
		respond(w, 404, 40401, "用户不存在", nil)
		return
	}
	store, ok := repository.(contentAnalyticsStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	ctx := r.Context()
	var data any
	var err error
	message := "success"
	missing := "用户不存在"
	switch kind {
	case postAnalyticsKind:
		missing = "帖子不存在"
		data, err = store.ReadPostAnalytics(ctx, viewer, id)
	case userAnalyticsKind:
		data, err = store.ReadUserAnalytics(ctx, viewer, id)
	case dailyAnalyticsKind:
		message = "user daily analytics"
		days := int64(math.Min(90, math.Max(7, sessionQueryNumber(parseSessionQuery(r.URL.RawQuery), "days", 14))))
		data, err = store.ReadDailyAnalytics(ctx, viewer, days)
	}
	switch {
	case errors.Is(err, errAnalyticsNotOwner):
		respond(w, 422, 42201, "只能查看自己帖子的统计", nil)
	case errors.Is(err, sql.ErrNoRows):
		respond(w, 404, 40401, missing, nil)
	case err != nil:
		respond(w, 500, 50001, "服务器内部错误", nil)
	default:
		respond(w, 200, 200, message, data)
	}
}
