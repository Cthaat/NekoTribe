package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"log"
	"net/http"
)

type commentLikeStore interface {
	SetCommentLike(context.Context, int64, int64, bool) (float64, bool, bool, error)
	PrepareCommentLikeNotification(context.Context, int64, int64) (int64, *notificationStored, error)
	NotificationByID(context.Context, int64, int64) (NotificationItem, bool, error)
}

func setCommentLike(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig, raw string) {
	user, id, ok := interactionIdentity(w, r, codec, repository, raw)
	if !ok {
		return
	}
	store, ok := repository.(commentLikeStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	liked := r.Method == http.MethodPost
	count, inserted, visible, err := store.SetCommentLike(r.Context(), user, id, liked)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !visible {
		respond(w, 404, 40401, "评论不存在", nil)
		return
	}
	if inserted {
		recipient, stored, err := store.PrepareCommentLikeNotification(r.Context(), user, id)
		if err != nil {
			respond(w, 500, 50001, "服务器内部错误", nil)
			return
		}
		if stored != nil {
			item, found, err := store.NotificationByID(r.Context(), recipient, stored.ID)
			if err != nil {
				respond(w, 500, 50001, "服务器内部错误", nil)
				return
			}
			if found {
				if hydrateNotification(r.Context(), repository, recipient, &item, config.Storage) != nil {
					respond(w, 500, 50001, "服务器内部错误", nil)
					return
				}
				if stored.PushEnabled && (config.NotificationPublisher == nil || config.NotificationPublisher.Publish(r.Context(), recipient, "notification_created", map[string]any{"notification": item, "notification_type": "like"}) != nil) {
					log.Print("notification delivery unavailable")
				}
			}
		}
	}
	respond(w, 200, 200, "success", struct {
		ID    int64   `json:"comment_id"`
		Liked bool    `json:"is_liked"`
		Count float64 `json:"likes_count"`
	}{id, liked, count})
}

const commentLikeVisibleSQL = `SELECT c.comment_id FROM n_comments c JOIN n_posts p ON p.post_id=c.post_id WHERE c.comment_id=:comment_id AND c.is_deleted=0 AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,c.post_id)=1`
const commentLikeCountSQL = `SELECT NVL(s.likes_count,0) FROM n_comments c JOIN n_posts p ON p.post_id=c.post_id LEFT JOIN n_comment_stats s ON s.comment_id=c.comment_id WHERE c.comment_id=:comment_id AND c.is_deleted=0 AND p.is_deleted=0 AND fn_can_view_post(:viewer_id,c.post_id)=1`
const commentLikeExistsSQL = `EXISTS (SELECT 1 FROM n_comments c JOIN n_posts p ON p.post_id=c.post_id WHERE c.comment_id=:comment_id AND c.is_deleted=0 AND p.is_deleted=0 AND fn_can_view_post(:user_id,c.post_id)=1)`

func (s OracleSessions) commentLikeVisible(ctx context.Context, user, id int64) (bool, error) {
	var found int64
	err := s.DB.QueryRowContext(ctx, commentLikeVisibleSQL, sql.Named("comment_id", id), sql.Named("viewer_id", user)).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, errSessionStore
	}
	return true, nil
}
func (s OracleSessions) SetCommentLike(ctx context.Context, user, id int64, liked bool) (float64, bool, bool, error) {
	visible, err := s.commentLikeVisible(ctx, user, id)
	if err != nil || !visible {
		return 0, false, visible, err
	}
	query := `DELETE FROM n_comment_likes WHERE comment_id=:comment_id AND user_id=:user_id AND ` + commentLikeExistsSQL
	if liked {
		query = `INSERT INTO n_comment_likes (comment_id,user_id) SELECT :comment_id,:user_id FROM dual WHERE ` + commentLikeExistsSQL + ` AND NOT EXISTS (SELECT 1 FROM n_comment_likes WHERE comment_id=:comment_id AND user_id=:user_id)`
	}
	changed, err := s.execute(ctx, query, sql.Named("comment_id", id), sql.Named("user_id", user))
	if err != nil {
		return 0, false, false, err
	}
	if changed == 0 {
		visible, err = s.commentLikeVisible(ctx, user, id)
		if err != nil || !visible {
			return 0, false, visible, err
		}
	}
	var count sql.NullFloat64
	err = s.DB.QueryRowContext(ctx, commentLikeCountSQL, sql.Named("comment_id", id), sql.Named("viewer_id", user)).Scan(&count)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, false, false, nil
	}
	if err != nil {
		return 0, false, false, errSessionStore
	}
	return count.Float64, liked && changed > 0, true, nil
}
func (s OracleSessions) PrepareCommentLikeNotification(ctx context.Context, actor, id int64) (int64, *notificationStored, error) {
	var author, post sql.NullInt64
	var comment sql.NullString
	err := s.DB.QueryRowContext(ctx, `SELECT user_id,post_id,DBMS_LOB.SUBSTR(content,4000,1) FROM n_comments WHERE comment_id=:comment_id AND is_deleted=0`, sql.Named("comment_id", id)).Scan(&author, &post, &comment)
	if errors.Is(err, sql.ErrNoRows) || err == nil && (!author.Valid || author.Int64 <= 0 || author.Int64 == actor || !post.Valid) {
		return 0, nil, nil
	}
	if err != nil {
		return 0, nil, errSessionStore
	}
	var name sql.NullString
	err = s.DB.QueryRowContext(ctx, `SELECT COALESCE(display_name,username) FROM n_users WHERE user_id=:user_id`, sql.Named("user_id", actor)).Scan(&name)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, nil, errSessionStore
	}
	actorName := "有人"
	if name.Valid && name.String != "" {
		actorName = name.String
	}
	var postContent sql.NullString
	err = s.DB.QueryRowContext(ctx, `SELECT DBMS_LOB.SUBSTR(content,4000,1) FROM n_posts WHERE post_id=:post_id AND is_deleted=0`, sql.Named("post_id", post.Int64)).Scan(&postContent)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, nil, errSessionStore
	}
	meta, err := json.Marshal(struct {
		PostID         int64           `json:"post_id"`
		TargetPostID   int64           `json:"target_post_id"`
		CommentID      int64           `json:"comment_id"`
		CommentExcerpt json.RawMessage `json:"comment_excerpt"`
		PostExcerpt    json.RawMessage `json:"post_excerpt"`
		Event          string          `json:"event"`
	}{post.Int64, post.Int64, id, postLikeExcerpt(comment), postLikeExcerpt(postContent), "comment_like"})
	if err != nil {
		return 0, nil, errSessionStore
	}
	resource := "comment"
	stored, err := s.storeNotification(ctx, notificationInput{UserID: author.Int64, ActorID: &actor, Type: "like", Title: actorName + " 赞了你的评论", Message: "你的评论收到了一次点赞。", ResourceType: &resource, ResourceID: &id, Priority: "normal", MetadataJSON: string(meta)})
	return author.Int64, stored, err
}
