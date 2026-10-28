package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"log"
	"math"
	"mime"
	"net/http"
	"net/url"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type notificationBatchStore interface {
	BatchSetNotificationRead(context.Context, int64, []int64, bool) (int64, error)
}

var errNotificationBatchIDs = errors.New("invalid notification IDs")

func notificationBatchBody(r *http.Request) ([]int64, bool, error) {
	body, err := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
	if err != nil || len(body) > 1<<20 {
		return nil, false, errSessionStore
	}
	media, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if strings.HasPrefix(media, "text/") {
		return nil, false, errSessionStore
	}
	var object map[string]any
	if media == "application/x-www-form-urlencoded" {
		values, err := url.ParseQuery(string(body))
		if err != nil {
			return nil, false, errSessionStore
		}
		object = make(map[string]any)
		for key, values := range values {
			if len(values) == 1 {
				object[key] = values[0]
			} else {
				object[key] = values
			}
		}
	} else if json.Unmarshal(body, &object) != nil || object == nil {
		return nil, false, errSessionStore
	}
	var ids []int64
	if raw, exists := object["notification_ids"]; exists {
		values, ok := raw.([]any)
		if !ok || len(values) > 1000 {
			return nil, false, errNotificationBatchIDs
		}
		ids = make([]int64, 0, len(values))
		for _, value := range values {
			number, ok := value.(float64)
			if !ok || number < 1 || number > 9007199254740991 || math.Trunc(number) != number {
				return nil, false, errNotificationBatchIDs
			}
			ids = append(ids, int64(number))
		}
	}
	return ids, readFlag(object["is_read"]), nil
}

func setNotificationBatchRead(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) {
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
	ids, read, err := notificationBatchBody(r)
	if err != nil {
		message := "请求体必须是 JSON 对象"
		if errors.Is(err, errNotificationBatchIDs) {
			message = "notification_ids 参数错误"
		}
		respond(w, 400, 40001, message, nil)
		return
	}
	store, ok := repository.(notificationBatchStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	updated, err := store.BatchSetNotificationRead(r.Context(), claims.UserID, ids, read)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	flag := int64(0)
	if read {
		flag = 1
	}
	data := map[string]any{"is_read": flag, "updated_count": updated}
	if len(ids) == 0 {
		data["all"] = true
	} else {
		data["notification_ids"] = ids
	}
	if config.NotificationPublisher == nil || config.NotificationPublisher.Publish(r.Context(), claims.UserID, "notifications_read_status_updated", data) != nil {
		log.Print("notification delivery unavailable")
	}
	respond(w, 200, 200, "success", map[string]any{"updated_count": updated})
}

func (s OracleSessions) BatchSetNotificationRead(ctx context.Context, user int64, ids []int64, read bool) (int64, error) {
	flag := int64(0)
	if read {
		flag = 1
	}
	base := `UPDATE n_notifications SET is_read=:is_read,read_at=CASE WHEN :is_read=1 THEN CURRENT_TIMESTAMP ELSE NULL END WHERE user_id=:user_id`
	if len(ids) == 0 {
		return s.execute(ctx, base+` AND deleted_at IS NULL`, sql.Named("is_read", flag), sql.Named("user_id", user))
	}
	var total int64
	for _, id := range ids {
		count, err := s.execute(ctx, base+` AND notification_id=:notification_id`, sql.Named("is_read", flag), sql.Named("user_id", user), sql.Named("notification_id", id))
		if err != nil {
			return 0, err
		}
		total += count
	}
	return total, nil
}
