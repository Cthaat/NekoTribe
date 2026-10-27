package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
)

const knownLoginDeviceSQL = `SELECT COUNT(*) FROM n_auth_sessions WHERE user_id=:user_id AND device_fingerprint=:device_fingerprint`
const loginAlertSettingsSQL = `SELECT NVL(us.login_alerts,1),NVL(us.email_notification_enabled,1) FROM n_users u LEFT JOIN n_user_settings us ON us.user_id=u.user_id WHERE u.user_id=:user_id`
const loginAlertDeliverySQL = `SELECT NVL(us.push_notification_enabled,1),NVL(np.is_enabled,1) FROM n_users u LEFT JOIN n_user_settings us ON us.user_id=u.user_id LEFT JOIN n_notification_preferences np ON np.user_id=u.user_id AND np.notification_type=:notification_type WHERE u.user_id=:user_id AND u.is_active=1`
const insertLoginAlertSQL = `INSERT INTO n_notifications (notification_id,user_id,actor_id,type,title,message,resource_type,resource_id,priority,metadata_json) VALUES (:notification_id,:user_id,:actor_id,:type,:title,:message,:resource_type,:resource_id,:priority,:metadata_json)`

func (s OracleSessions) KnownLoginDevice(ctx context.Context, user int64, fingerprint string) (bool, error) {
	var n int64
	err := s.DB.QueryRowContext(ctx, knownLoginDeviceSQL, sql.Named("user_id", user), sql.Named("device_fingerprint", fingerprint)).Scan(&n)
	if err != nil {
		return false, errSessionStore
	}
	return n > 0, nil
}

// RecordLoginAlert persists the alert according to account and per-type settings.
// Realtime push and email transports are not implemented in this service yet.
func (s OracleSessions) RecordLoginAlert(ctx context.Context, v LoginSession) error {
	var enabled, emailEnabled int64
	if err := s.DB.QueryRowContext(ctx, loginAlertSettingsSQL, sql.Named("user_id", v.UserID)).Scan(&enabled, &emailEnabled); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		return errSessionStore
	}
	if enabled == 0 {
		return nil
	}
	var pushEnabled, typeEnabled int64
	if err := s.DB.QueryRowContext(ctx, loginAlertDeliverySQL, sql.Named("notification_type", "login_alert"), sql.Named("user_id", v.UserID)).Scan(&pushEnabled, &typeEnabled); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		return errSessionStore
	}
	if typeEnabled == 0 {
		return nil
	}
	var id int64
	if err := s.DB.QueryRowContext(ctx, `SELECT seq_notification_id.NEXTVAL FROM dual`).Scan(&id); err != nil {
		return errSessionStore
	}
	metadata, err := json.Marshal(map[string]string{"session_id": v.SessionID, "device_info": v.DeviceInfo, "device_fingerprint": v.DeviceFingerprint, "ip_address": v.IPAddress, "user_agent": v.UserAgent})
	if err != nil {
		return errSessionStore
	}
	_, err = s.execute(ctx, insertLoginAlertSQL, sql.Named("notification_id", id), sql.Named("user_id", v.UserID), sql.Named("actor_id", nil), sql.Named("type", "login_alert"), sql.Named("title", "新设备登录提醒"), sql.Named("message", "你的账号刚刚通过新设备登录："+v.DeviceInfo), sql.Named("resource_type", "auth_session"), sql.Named("resource_id", nil), sql.Named("priority", "high"), sql.Named("metadata_json", string(metadata)))
	return err
}
