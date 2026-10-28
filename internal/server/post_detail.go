package server

import (
	"context"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type PostMedia struct {
	MediaID      int64    `json:"media_id"`
	MediaType    string   `json:"media_type"`
	FileName     string   `json:"file_name"`
	PublicURL    string   `json:"public_url"`
	FileSize     int64    `json:"file_size"`
	MIMEType     string   `json:"mime_type"`
	Width        *float64 `json:"width"`
	Height       *float64 `json:"height"`
	Duration     *float64 `json:"duration"`
	ThumbnailURL *string  `json:"thumbnail_url"`
	AltText      *string  `json:"alt_text"`
	Description  *string  `json:"description"`
	Status       string   `json:"status"`
	CreatedAt    string   `json:"created_at"`
}
type PostStats struct {
	LikesCount      float64 `json:"likes_count"`
	CommentsCount   float64 `json:"comments_count"`
	RepliesCount    float64 `json:"replies_count"`
	RetweetsCount   float64 `json:"retweets_count"`
	ViewsCount      float64 `json:"views_count"`
	EngagementScore float64 `json:"engagement_score"`
}
type PostViewerState struct {
	IsLiked      bool `json:"is_liked"`
	IsBookmarked bool `json:"is_bookmarked"`
	CanDelete    bool `json:"can_delete"`
}
type PostDetail struct {
	PostID         int64           `json:"post_id"`
	Author         PublicUser      `json:"author"`
	Content        string          `json:"content"`
	PostType       string          `json:"post_type"`
	Visibility     string          `json:"visibility"`
	Language       string          `json:"language"`
	Location       string          `json:"location"`
	ReplyToPostID  *int64          `json:"reply_to_post_id"`
	RepostOfPostID *int64          `json:"repost_of_post_id"`
	QuotedPostID   *int64          `json:"quoted_post_id"`
	Media          []PostMedia     `json:"media"`
	Tags           []string        `json:"tags"`
	Mentions       []PublicUser    `json:"mentions"`
	Stats          PostStats       `json:"stats"`
	ViewerState    PostViewerState `json:"viewer_state"`
	CreatedAt      string          `json:"created_at"`
	UpdatedAt      string          `json:"updated_at"`
}
type postDetailStore interface {
	ReadVisiblePost(context.Context, *int64, int64) (PostDetail, bool, error)
	ReadPostAuthor(context.Context, *int64, int64) (PublicUser, bool, error)
	CheckMediaSchema(context.Context) error
	ReadPostMedia(context.Context, int64) ([]PostMedia, error)
	ReadPostTags(context.Context, int64) ([]string, error)
	ReadPostMentions(context.Context, *int64, int64) ([]PublicUser, error)
	IncrementPostViews(context.Context, int64) error
}

func postSegment(path string) (string, bool) {
	const prefix = "/api/v2/posts/"
	if !strings.HasPrefix(path, prefix) {
		return "", false
	}
	id := strings.TrimPrefix(path, prefix)
	return id, id != "" && !strings.Contains(id, "/") && id != "trending"
}
func getPostDetail(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig, raw string) {
	w.Header().Set("Cache-Control", "private, no-store")
	token := accessToken(r)
	var viewer *int64
	if token == "" {
		if !publicID.MatchString(raw) {
			respond(w, 401, 40101, "请先登录", nil)
			return
		}
	} else {
		claims, err := codec.Verify(token, auth.Access)
		if err != nil {
			respond(w, 401, 40101, "Token无效或已过期", nil)
			return
		}
		if n, err := repository.Touch(r.Context(), claims); err != nil || n != 1 {
			respond(w, 401, 40101, "Token无效或已过期", nil)
			return
		}
		viewer = &claims.UserID
	}
	decoded, err := url.PathUnescape(raw)
	if err != nil || !publicID.MatchString(decoded) {
		respond(w, 400, 40001, "id 参数错误", nil)
		return
	}
	id, err := strconv.ParseInt(decoded, 10, 64)
	if err != nil || id > 9007199254740991 {
		respond(w, 400, 40001, "id 参数错误", nil)
		return
	}
	store, ok := repository.(postDetailStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	post, found, err := store.ReadVisiblePost(r.Context(), viewer, id)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !found {
		respond(w, 404, 40401, "帖子不存在", nil)
		return
	}
	author, found, err := store.ReadPostAuthor(r.Context(), viewer, post.Author.UserID)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !found {
		respond(w, 404, 40401, "用户不存在", nil)
		return
	}
	author.AvatarURL, err = normalizeAvatarURL(config.Storage, author.AvatarURL)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	post.Author = author
	if err = store.CheckMediaSchema(r.Context()); err != nil {
		respond(w, 503, 50301, "服务暂不可用，请稍后重试。", nil)
		return
	}
	post.Media, err = store.ReadPostMedia(r.Context(), id)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	for i := range post.Media {
		post.Media[i].PublicURL, err = normalizeAvatarURL(config.Storage, post.Media[i].PublicURL)
		if err != nil {
			respond(w, 500, 50001, "服务器内部错误", nil)
			return
		}
		if post.Media[i].ThumbnailURL != nil && *post.Media[i].ThumbnailURL != "" {
			v, e := normalizeAvatarURL(config.Storage, *post.Media[i].ThumbnailURL)
			if e != nil {
				respond(w, 500, 50001, "服务器内部错误", nil)
				return
			}
			post.Media[i].ThumbnailURL = &v
		} else {
			post.Media[i].ThumbnailURL = nil
		}
	}
	post.Tags, err = store.ReadPostTags(r.Context(), id)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	post.Mentions, err = store.ReadPostMentions(r.Context(), viewer, id)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	for i := range post.Mentions {
		post.Mentions[i].AvatarURL, err = normalizeAvatarURL(config.Storage, post.Mentions[i].AvatarURL)
		if err != nil {
			respond(w, 500, 50001, "服务器内部错误", nil)
			return
		}
	}
	if err = store.IncrementPostViews(r.Context(), id); err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	respond(w, 200, 200, "success", post)
}
