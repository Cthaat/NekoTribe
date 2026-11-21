package server

import (
	"context"
	"database/sql"
	"errors"
)

const notificationDeliverySQL = `SELECT NVL(us.push_notification_enabled,1),NVL(np.is_enabled,1) FROM n_users u LEFT JOIN n_user_settings us ON us.user_id=u.user_id LEFT JOIN n_notification_preferences np ON np.user_id=u.user_id AND np.notification_type=:notification_type WHERE u.user_id=:user_id AND u.is_active=1`
const insertNotificationSQL = `INSERT INTO n_notifications (notification_id,user_id,actor_id,type,title,message,resource_type,resource_id,priority,metadata_json) VALUES (:notification_id,:user_id,:actor_id,:type,:title,:message,:resource_type,:resource_id,:priority,:metadata_json)`

// notificationInput is built by trusted business logic, never directly from a client.
type notificationInput struct {
	UserID                 int64
	ActorID                *int64
	Type, Title, Message   string
	ResourceType           *string
	ResourceID             *int64
	Priority, MetadataJSON string
}
type notificationStored struct {
	ID          int64
	PushEnabled bool
}

// Store after checking the recipient's type preference; global push preference
// controls delivery, not storage. A nil result means no notification is due.
func (s OracleSessions) storeNotification(ctx context.Context, v notificationInput) (*notificationStored, error) {
	return storeNotificationWith(ctx, s.DB, func(ctx context.Context, query string, args ...any) error {
		_, err := s.execute(ctx, query, args...)
		return err
	}, v)
}

type notificationQueryer interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

func storeNotificationWith(ctx context.Context, query notificationQueryer, insert func(context.Context, string, ...any) error, v notificationInput) (*notificationStored, error) {
	if v.UserID <= 0 || v.ActorID != nil && *v.ActorID == v.UserID {
		return nil, nil
	}
	var pushEnabled, typeEnabled int64
	err := query.QueryRowContext(ctx, notificationDeliverySQL, sql.Named("notification_type", v.Type), sql.Named("user_id", v.UserID)).Scan(&pushEnabled, &typeEnabled)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, errSessionStore
	}
	if typeEnabled == 0 {
		return nil, nil
	}
	var id int64
	if err = query.QueryRowContext(ctx, `SELECT seq_notification_id.NEXTVAL FROM dual`).Scan(&id); err != nil {
		return nil, errSessionStore
	}
	err = insert(ctx, insertNotificationSQL,
		sql.Named("notification_id", id), sql.Named("user_id", v.UserID), sql.Named("actor_id", v.ActorID),
		sql.Named("type", v.Type), sql.Named("title", v.Title), sql.Named("message", v.Message),
		sql.Named("resource_type", v.ResourceType), sql.Named("resource_id", v.ResourceID),
		sql.Named("priority", v.Priority), sql.Named("metadata_json", v.MetadataJSON))
	if err != nil {
		return nil, err
	}
	return &notificationStored{ID: id, PushEnabled: pushEnabled != 0}, nil
}
