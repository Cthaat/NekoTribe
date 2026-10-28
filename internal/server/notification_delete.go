package server

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"net/http"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type notificationDeleteStore interface {
	SetNotificationDeleted(context.Context, int64, int64, bool) (*string, bool, error)
}

func setNotificationDeleted(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig, raw string, restore bool) {
	user, id, valid := interactionIdentity(w, r, codec, repository, raw)
	if !valid {
		return
	}
	store, ok := repository.(notificationDeleteStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	date, found, err := store.SetNotificationDeleted(r.Context(), user, id, restore)
	if err != nil {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	if !found {
		respond(w, 404, 40401, "通知不存在", nil)
		return
	}
	data := map[string]any{"notification_id": id, "deleted_at": date}
	kind := "notification_deleted"
	if restore {
		kind = "notification_restored"
	}
	if config.NotificationPublisher == nil || config.NotificationPublisher.Publish(r.Context(), user, kind, data) != nil {
		log.Print("notification delivery unavailable")
	}
	if restore {
		respond(w, 200, 200, "success", data)
	} else {
		respond(w, 200, 200, "notification deleted", nil)
	}
}

func (s OracleSessions) SetNotificationDeleted(ctx context.Context, user, id int64, restore bool) (*string, bool, error) {
	query := `UPDATE n_notifications SET deleted_at=CURRENT_TIMESTAMP WHERE notification_id=:notification_id AND user_id=:user_id AND deleted_at IS NULL`
	if restore {
		query = `UPDATE n_notifications SET deleted_at=NULL WHERE notification_id=:notification_id AND user_id=:user_id`
	}
	changed, err := s.execute(ctx, query, sql.Named("notification_id", id), sql.Named("user_id", user))
	if err != nil {
		return nil, false, err
	}
	if changed == 0 {
		return nil, false, nil
	}
	if restore {
		return nil, true, nil
	}
	var deletedAt sql.NullTime
	err = s.DB.QueryRowContext(ctx, `SELECT deleted_at FROM n_notifications WHERE notification_id=:notification_id AND user_id=:user_id`, sql.Named("notification_id", id), sql.Named("user_id", user)).Scan(&deletedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, true, nil
	}
	if err != nil {
		return nil, false, errSessionStore
	}
	return profileDate(deletedAt), true, nil
}
