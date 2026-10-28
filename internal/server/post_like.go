package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"unicode/utf16"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type postLikeStore interface {
	AddPostLike(context.Context, int64, int64) (float64, bool, bool, error)
	PreparePostLikeNotification(context.Context, int64, int64) (int64, *notificationStored, error)
	NotificationByID(context.Context, int64, int64) (NotificationItem, bool, error)
}

func addPostLike(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig, raw string) {
	viewer, id, valid := interactionIdentity(w, r, codec, repository, raw)
	if !valid {
		return
	}
	store, ok := repository.(postLikeStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	count, inserted, visible, err := store.AddPostLike(r.Context(), viewer, id)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !visible {
		respond(w, 404, 40401, "帖子不存在", nil)
		return
	}
	if inserted {
		recipient, stored, err := store.PreparePostLikeNotification(r.Context(), viewer, id)
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
				if stored.PushEnabled {
					// Like and notification are already committed. Redis failure degrades
					// delivery, as in Nuxt; it must not create another notification.
					if config.NotificationPublisher == nil || config.NotificationPublisher.Publish(r.Context(), recipient, "notification_created", map[string]interface{}{"notification": item, "notification_type": "like"}) != nil {
						log.Print("notification delivery unavailable")
					}
				}
			}
		}
	}
	respond(w, 200, 200, "success", struct {
		PostID int64   `json:"post_id"`
		Liked  bool    `json:"is_liked"`
		Count  float64 `json:"likes_count"`
	}{id, true, count})
}

const insertPostLikeSQL = `INSERT INTO n_post_likes (post_id,user_id) SELECT :post_id,:user_id FROM dual WHERE fn_can_view_post(:user_id,:post_id)=1 AND NOT EXISTS (SELECT 1 FROM n_post_likes WHERE post_id=:post_id AND user_id=:user_id)`

func (s OracleSessions) AddPostLike(ctx context.Context, viewer, id int64) (float64, bool, bool, error) {
	visible, err := s.bookmarkVisible(ctx, viewer, id)
	if err != nil || !visible {
		return 0, false, visible, err
	}
	changed, err := s.execute(ctx, insertPostLikeSQL, sql.Named("post_id", id), sql.Named("user_id", viewer))
	if err != nil {
		return 0, false, false, err
	}
	if changed == 0 {
		visible, err = s.bookmarkVisible(ctx, viewer, id)
		if err != nil || !visible {
			return 0, false, visible, err
		}
	}
	var count sql.NullFloat64
	err = s.DB.QueryRowContext(ctx, postLikeCountSQL, sql.Named("post_id", id)).Scan(&count)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, false, false, errSessionStore
	}
	return count.Float64, changed > 0, true, nil
}

func (s OracleSessions) PreparePostLikeNotification(ctx context.Context, actor, post int64) (int64, *notificationStored, error) {
	var author sql.NullInt64
	err := s.DB.QueryRowContext(ctx, `SELECT author_id FROM n_posts WHERE post_id=:post_id AND is_deleted=0`, sql.Named("post_id", post)).Scan(&author)
	if errors.Is(err, sql.ErrNoRows) || err == nil && (!author.Valid || author.Int64 <= 0 || author.Int64 == actor) {
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
	var content sql.NullString
	err = s.DB.QueryRowContext(ctx, `SELECT DBMS_LOB.SUBSTR(content,4000,1) FROM n_posts WHERE post_id=:post_id AND is_deleted=0`, sql.Named("post_id", post)).Scan(&content)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, nil, errSessionStore
	}
	if errors.Is(err, sql.ErrNoRows) {
		content = sql.NullString{}
	}
	metadata, err := json.Marshal(struct {
		TargetPostID int64           `json:"target_post_id"`
		PostExcerpt  json.RawMessage `json:"post_excerpt"`
		Event        string          `json:"event"`
	}{post, postLikeExcerpt(content), "post_like"})
	if err != nil {
		return 0, nil, errSessionStore
	}
	resourceType := "post"
	stored, err := s.storeNotification(ctx, notificationInput{UserID: author.Int64, ActorID: &actor, Type: "like", Title: actorName + " 赞了你的推文", Message: "你的推文收到了一次点赞。", ResourceType: &resourceType, ResourceID: &post, Priority: "normal", MetadataJSON: string(metadata)})
	return author.Int64, stored, err
}

func jsWhitespace(r rune) bool {
	return r >= '\t' && r <= '\r' || r == ' ' || r == '\u00a0' || r == '\u1680' || r >= '\u2000' && r <= '\u200a' || r == '\u2028' || r == '\u2029' || r == '\u202f' || r == '\u205f' || r == '\u3000' || r == '\ufeff'
}

// Returns JSON directly so an excerpt ending halfway through a UTF-16 pair
// preserves JavaScript's unpaired-surrogate escape rather than replacing it.
func postLikeExcerpt(value sql.NullString) json.RawMessage {
	if !value.Valid || value.String == "" {
		return json.RawMessage("null")
	}
	var compact strings.Builder
	space := false
	for _, r := range value.String {
		if jsWhitespace(r) {
			space = compact.Len() > 0
			continue
		}
		if space {
			compact.WriteByte(' ')
			space = false
		}
		compact.WriteRune(r)
	}
	text := compact.String()
	units := utf16.Encode([]rune(text))
	if len(units) <= 160 {
		result, _ := json.Marshal(text)
		return result
	}
	units = units[:160]
	if units[len(units)-1] >= 0xD800 && units[len(units)-1] <= 0xDBFF {
		prefix, _ := json.Marshal(string(utf16.Decode(units[:len(units)-1])))
		return json.RawMessage(fmt.Sprintf("%s\\u%04x...\"", prefix[:len(prefix)-1], units[len(units)-1]))
	}
	result, _ := json.Marshal(string(utf16.Decode(units)) + "...")
	return result
}
