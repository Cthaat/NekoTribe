package server

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"math"
	"net/http"
	"strconv"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type commentNoticeContext struct {
	ActorName                   string
	PostAuthor                  int64
	CommentExcerpt, PostExcerpt json.RawMessage
}
type commentParentNotice struct {
	Author  int64
	Excerpt json.RawMessage
}
type commentCreateStore interface {
	CreatePostComment(context.Context, int64, int64, string, *int64) (PostComment, error)
	CommentNoticeContext(context.Context, int64, int64, int64) (commentNoticeContext, error)
	CommentParentNotice(context.Context, int64, int64) (commentParentNotice, error)
	StoreCommentNotification(context.Context, notificationInput) (*notificationStored, error)
	NotificationByID(context.Context, int64, int64) (NotificationItem, bool, error)
}

func optionalCommentParent(value any) (*int64, bool) {
	if value == nil {
		return nil, true
	}
	var id int64
	switch v := value.(type) {
	case string:
		if v == "" {
			return nil, true
		}
		if !publicID.MatchString(v) {
			return nil, false
		}
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			return nil, false
		}
		id = n
	case float64:
		if v < 1 || v > 9007199254740991 || math.Trunc(v) != v {
			return nil, false
		}
		id = int64(v)
	default:
		return nil, false
	}
	if id < 1 || id > 9007199254740991 {
		return nil, false
	}
	return &id, true
}

func createPostComment(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig, raw string) {
	user, post, ok := interactionIdentity(w, r, codec, repository, raw)
	if !ok {
		return
	}
	body, ok := readLoginBody(r)
	if !ok {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return
	}
	parent, ok := optionalCommentParent(body["parent_comment_id"])
	if !ok {
		respond(w, 400, 40001, "parent_comment_id 参数错误", nil)
		return
	}
	content := loginString(body["content"])
	if content == "" {
		respond(w, 400, 40001, "content 不能为空", nil)
		return
	}
	store, ok := repository.(commentCreateStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	comment, err := store.CreatePostComment(r.Context(), user, post, content, parent)
	if err != nil {
		switch {
		case errors.Is(err, errPublishForbidden):
			respond(w, 403, 40301, publishPolicy.Message, nil)
		case errors.Is(err, errCommentPostUnavailable):
			respond(w, 404, 40401, "帖子不存在", nil)
		case errors.Is(err, errCommentParentUnavailable):
			respond(w, 404, 40401, "父评论不存在", nil)
		case errors.Is(err, errCommentUnavailable):
			respond(w, 404, 40401, "评论不存在", nil)
		default:
			respond(w, 500, 50001, "服务器内部错误", nil)
		}
		return
	}
	notice, err := store.CommentNoticeContext(r.Context(), user, post, comment.ID)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	postMeta := struct {
		PostID         int64           `json:"post_id"`
		TargetPostID   int64           `json:"target_post_id"`
		CommentID      int64           `json:"comment_id"`
		CommentExcerpt json.RawMessage `json:"comment_excerpt"`
		PostExcerpt    json.RawMessage `json:"post_excerpt"`
		Event          string          `json:"event"`
	}{post, post, comment.ID, notice.CommentExcerpt, notice.PostExcerpt, "comment_created"}
	if notice.PostAuthor > 0 {
		encoded, e := json.Marshal(postMeta)
		if e != nil {
			respond(w, 500, 50001, "服务器内部错误", nil)
			return
		}
		resource := "comment"
		input := notificationInput{UserID: notice.PostAuthor, ActorID: &user, Type: "comment", Title: notice.ActorName + " 评论了你的推文", Message: "你的推文收到了一条新评论。", ResourceType: &resource, ResourceID: &comment.ID, Priority: "normal", MetadataJSON: string(encoded)}
		if deliverCommentNotification(r.Context(), repository, store, config, input) != nil {
			respond(w, 500, 50001, "服务器内部错误", nil)
			return
		}
	}
	if parent != nil {
		parentNotice, e := store.CommentParentNotice(r.Context(), *parent, notice.PostAuthor)
		if e != nil {
			respond(w, 500, 50001, "服务器内部错误", nil)
			return
		}
		if parentNotice.Author > 0 && parentNotice.Author != notice.PostAuthor {
			meta := struct {
				PostID         int64           `json:"post_id"`
				TargetPostID   int64           `json:"target_post_id"`
				CommentID      int64           `json:"comment_id"`
				ParentID       int64           `json:"parent_comment_id"`
				CommentExcerpt json.RawMessage `json:"comment_excerpt"`
				ParentExcerpt  json.RawMessage `json:"parent_comment_excerpt"`
				PostExcerpt    json.RawMessage `json:"post_excerpt"`
				Event          string          `json:"event"`
			}{post, post, comment.ID, *parent, notice.CommentExcerpt, parentNotice.Excerpt, notice.PostExcerpt, "comment_reply"}
			encoded, e := json.Marshal(meta)
			if e != nil {
				respond(w, 500, 50001, "服务器内部错误", nil)
				return
			}
			resource := "comment"
			input := notificationInput{UserID: parentNotice.Author, ActorID: &user, Type: "comment", Title: notice.ActorName + " 回复了你的评论", Message: "你的评论收到了一条新回复。", ResourceType: &resource, ResourceID: &comment.ID, Priority: "normal", MetadataJSON: string(encoded)}
			if deliverCommentNotification(r.Context(), repository, store, config, input) != nil {
				respond(w, 500, 50001, "服务器内部错误", nil)
				return
			}
		}
	}
	profiles, ok := repository.(publicProfileStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	author, found, err := profiles.PublicProfile(r.Context(), user, user)
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
	comment.Author = author
	comment.Stats = commentStats{comment.LikesCount, comment.RepliesCount}
	comment.Viewer = commentViewer{Liked: false, CanDelete: true}
	respond(w, 200, 200, "comment created", comment)
}

func deliverCommentNotification(ctx context.Context, repository SessionRepository, store commentCreateStore, config RefreshConfig, input notificationInput) error {
	stored, err := store.StoreCommentNotification(ctx, input)
	if err != nil {
		return err
	}
	if stored == nil {
		return nil
	}
	item, found, err := store.NotificationByID(ctx, input.UserID, stored.ID)
	if err != nil {
		return err
	}
	if !found {
		return nil
	}
	if err = hydrateNotification(ctx, repository, input.UserID, &item, config.Storage); err != nil {
		return err
	}
	if stored.PushEnabled && (config.NotificationPublisher == nil || config.NotificationPublisher.Publish(ctx, input.UserID, "notification_created", map[string]any{"notification": item, "notification_type": "comment"}) != nil) {
		log.Print("notification delivery unavailable")
	}
	return nil
}
