package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"log"
	"mime"
	"net/http"
	"net/url"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type NotificationReadResult struct {
	NotificationID int64   `json:"notification_id"`
	IsRead         int64   `json:"is_read"`
	ReadAt         *string `json:"read_at"`
}
type notificationReadStore interface {
	SetNotificationRead(context.Context, int64, int64, bool) (NotificationReadResult, bool, error)
}

func readFlag(value any) bool {
	switch v := value.(type) {
	case bool:
		return v
	case float64:
		return v == 1
	case string:
		s := strings.ToLower(v)
		return s == "1" || s == "true" || s == "yes"
	default:
		return false
	}
}
func notificationReadBody(r *http.Request) (bool, error) {
	body, err := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
	if err != nil || len(body) > 1<<20 {
		return false, errSessionStore
	}
	media, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if strings.HasPrefix(media, "text/") {
		return false, errSessionStore
	}
	if media == "application/x-www-form-urlencoded" {
		values, err := url.ParseQuery(string(body))
		if err != nil {
			return false, errSessionStore
		}
		if len(values["is_read"]) != 1 {
			return false, nil
		}
		return readFlag(values.Get("is_read")), nil
	}
	var object map[string]any
	if json.Unmarshal(body, &object) != nil || object == nil {
		return false, errSessionStore
	}
	return readFlag(object["is_read"]), nil
}

func setNotificationRead(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig, raw string) {
	user, id, valid := interactionIdentity(w, r, codec, repository, raw)
	if !valid {
		return
	}
	read, err := notificationReadBody(r)
	if err != nil {
		respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
		return
	}
	store, ok := repository.(notificationReadStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	result, found, err := store.SetNotificationRead(r.Context(), user, id, read)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !found {
		respond(w, 404, 40401, "通知不存在", nil)
		return
	}
	data := map[string]interface{}{"notification_id": result.NotificationID, "is_read": result.IsRead, "read_at": result.ReadAt}
	if config.NotificationPublisher == nil || config.NotificationPublisher.Publish(r.Context(), user, "notification_read_status_updated", data) != nil {
		log.Print("notification delivery unavailable")
	}
	respond(w, 200, 200, "success", result)
}

func (s OracleSessions) SetNotificationRead(ctx context.Context, user, id int64, read bool) (NotificationReadResult, bool, error) {
	flag := int64(0)
	if read {
		flag = 1
	}
	changed, err := s.execute(ctx, `UPDATE n_notifications SET is_read=:is_read,read_at=CASE WHEN :is_read=1 THEN CURRENT_TIMESTAMP ELSE NULL END WHERE notification_id=:notification_id AND user_id=:user_id`, sql.Named("is_read", flag), sql.Named("notification_id", id), sql.Named("user_id", user))
	if err != nil {
		return NotificationReadResult{}, false, err
	}
	if changed == 0 {
		return NotificationReadResult{}, false, nil
	}
	var result NotificationReadResult
	var readAt sql.NullTime
	err = s.DB.QueryRowContext(ctx, `SELECT notification_id,is_read,read_at FROM n_notifications WHERE notification_id=:notification_id AND user_id=:user_id`, sql.Named("notification_id", id), sql.Named("user_id", user)).Scan(&result.NotificationID, &result.IsRead, &readAt)
	if errors.Is(err, sql.ErrNoRows) {
		return NotificationReadResult{}, false, nil
	}
	if err != nil {
		return NotificationReadResult{}, false, errSessionStore
	}
	result.ReadAt = profileDate(readAt)
	return result, true, nil
}
