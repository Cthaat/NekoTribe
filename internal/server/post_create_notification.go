package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log"
)

type postCreateNoticeStore interface {
	postNotificationDeliveryStore
	PostCreateActorName(context.Context, int64) (string, error)
	PostCreateSourceAuthor(context.Context, int64) (int64, error)
	PostCreateExcerpt(context.Context, int64) (json.RawMessage, error)
	ResolvePostMentionRecipient(context.Context, float64) (int64, error)
}

type postNotificationDeliveryStore interface {
	StorePostCreateNotification(context.Context, notificationInput) (*notificationStored, error)
	NotificationByID(context.Context, int64, int64) (NotificationItem, bool, error)
}

func notifyPostCreated(ctx context.Context, repository SessionRepository, store postCreateNoticeStore, config RefreshConfig, actor, post int64, input PostCreateInput) error {
	actorName, err := store.PostCreateActorName(ctx, actor)
	if err != nil {
		return err
	}
	resource := "post"
	notice := notificationInput{ActorID: &actor, ResourceType: &resource, ResourceID: &post, Priority: "normal"}
	var source *int64
	meta := struct {
		SourcePostID   int64           `json:"source_post_id"`
		TargetPostID   int64           `json:"target_post_id"`
		ActionPostID   int64           `json:"action_post_id"`
		PostExcerpt    json.RawMessage `json:"post_excerpt"`
		ReplyExcerpt   json.RawMessage `json:"reply_excerpt,omitempty"`
		RetweetExcerpt json.RawMessage `json:"retweet_excerpt,omitempty"`
		QuoteExcerpt   json.RawMessage `json:"quote_excerpt,omitempty"`
		Event          string          `json:"event"`
	}{ActionPostID: post}
	actionExcerpt := postLikeExcerpt(sql.NullString{String: input.Content, Valid: input.Content != ""})
	switch {
	case input.ReplyToPostID != nil:
		source = input.ReplyToPostID
		notice.Type, notice.Title, notice.Message = "comment", actorName+" 回复了你的推文", "你的推文收到了一条新回复。"
		meta.ReplyExcerpt, meta.Event = actionExcerpt, "post_reply"
	case input.RepostOfPostID != nil:
		source = input.RepostOfPostID
		notice.Type, notice.Title, notice.Message = "retweet", actorName+" 转发了你的推文", "你的推文被转发了。"
		meta.RetweetExcerpt, meta.Event = actionExcerpt, "post_repost"
	case input.QuotedPostID != nil:
		source = input.QuotedPostID
		notice.Type, notice.Title, notice.Message = "retweet", actorName+" 引用了你的推文", "你的推文被引用了。"
		meta.QuoteExcerpt, meta.Event = actionExcerpt, "post_quote"
	}
	if source != nil {
		notice.UserID, err = store.PostCreateSourceAuthor(ctx, *source)
		if err != nil {
			return err
		}
		if notice.UserID != 0 {
			meta.SourcePostID, meta.TargetPostID = *source, *source
			meta.PostExcerpt, err = store.PostCreateExcerpt(ctx, *source)
			if err != nil {
				return err
			}
			encoded, err := json.Marshal(meta)
			if err != nil {
				return errSessionStore
			}
			notice.MetadataJSON = string(encoded)
			if err = deliverPostCreateNotification(ctx, repository, store, config, notice); err != nil {
				return err
			}
		}
	}
	seen := make(map[float64]struct{}, len(input.Mentions))
	for _, user := range input.Mentions {
		if _, exists := seen[user]; exists {
			continue
		}
		seen[user] = struct{}{}
		// Nuxt builds each mention's metadata before resolving delivery eligibility.
		// Keep this read per mention, even for missing, inactive, or self recipients.
		excerpt, err := store.PostCreateExcerpt(ctx, post)
		if err != nil {
			return err
		}
		if user <= 0 || user == float64(actor) {
			continue
		}
		recipient, err := store.ResolvePostMentionRecipient(ctx, user)
		if err != nil {
			return err
		}
		if recipient == 0 {
			continue
		}
		encoded, err := json.Marshal(struct {
			TargetPostID int64           `json:"target_post_id"`
			PostExcerpt  json.RawMessage `json:"post_excerpt"`
			Event        string          `json:"event"`
		}{post, excerpt, "post_mention"})
		if err != nil {
			return errSessionStore
		}
		notice.UserID, notice.Type = recipient, "mention"
		notice.Title, notice.Message = actorName+" 提及了你", "你在一条推文中被提及。"
		notice.MetadataJSON = string(encoded)
		if err = deliverPostCreateNotification(ctx, repository, store, config, notice); err != nil {
			return err
		}
	}
	return nil
}

func deliverPostCreateNotification(ctx context.Context, repository SessionRepository, store postNotificationDeliveryStore, config RefreshConfig, input notificationInput) error {
	stored, err := store.StorePostCreateNotification(ctx, input)
	if err != nil || stored == nil {
		return err
	}
	item, found, err := store.NotificationByID(ctx, input.UserID, stored.ID)
	if err != nil || !found {
		return err
	}
	if err = hydrateNotification(ctx, repository, input.UserID, &item, config.Storage); err != nil {
		return err
	}
	if stored.PushEnabled && (config.NotificationPublisher == nil || config.NotificationPublisher.Publish(ctx, input.UserID, "notification_created", map[string]interface{}{"notification": item, "notification_type": input.Type}) != nil) {
		log.Print("notification delivery unavailable")
	}
	return nil
}

func (s OracleSessions) PostCreateActorName(ctx context.Context, actor int64) (string, error) {
	var name sql.NullString
	err := s.DB.QueryRowContext(ctx, `SELECT COALESCE(display_name,username) FROM n_users WHERE user_id=:user_id`, sql.Named("user_id", actor)).Scan(&name)
	if errors.Is(err, sql.ErrNoRows) || err == nil && !name.Valid {
		return "有人", nil
	}
	if err != nil {
		return "", errSessionStore
	}
	return name.String, nil
}

func (s OracleSessions) PostCreateSourceAuthor(ctx context.Context, post int64) (int64, error) {
	var author sql.NullInt64
	err := s.DB.QueryRowContext(ctx, `SELECT author_id FROM n_posts WHERE post_id=:post_id AND is_deleted=0`, sql.Named("post_id", post)).Scan(&author)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, errSessionStore
	}
	return author.Int64, nil
}

func (s OracleSessions) PostCreateExcerpt(ctx context.Context, post int64) (json.RawMessage, error) {
	var content sql.NullString
	err := s.DB.QueryRowContext(ctx, `SELECT DBMS_LOB.SUBSTR(content,4000,1) FROM n_posts WHERE post_id=:post_id AND is_deleted=0`, sql.Named("post_id", post)).Scan(&content)
	if errors.Is(err, sql.ErrNoRows) {
		return json.RawMessage("null"), nil
	}
	if err != nil {
		return nil, errSessionStore
	}
	return postLikeExcerpt(content), nil
}

// Bind the original JavaScript number so a fractional mention cannot notify the
// user whose integer ID would result from truncation. Eligibility stays in storeNotification.
func (s OracleSessions) ResolvePostMentionRecipient(ctx context.Context, user float64) (int64, error) {
	var recipient sql.NullInt64
	err := s.DB.QueryRowContext(ctx, `SELECT user_id FROM n_users WHERE user_id=:user_id`, sql.Named("user_id", user)).Scan(&recipient)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, errSessionStore
	}
	return recipient.Int64, nil
}

func (s OracleSessions) StorePostCreateNotification(ctx context.Context, input notificationInput) (*notificationStored, error) {
	return s.storeNotification(ctx, input)
}
