package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
)

const knownLoginDeviceSQL = `SELECT COUNT(*) FROM n_auth_sessions WHERE user_id=:user_id AND device_fingerprint=:device_fingerprint`
const loginAlertSettingsSQL = `SELECT NVL(us.login_alerts,1),NVL(us.email_notification_enabled,1) FROM n_users u LEFT JOIN n_user_settings us ON us.user_id=u.user_id WHERE u.user_id=:user_id`

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
	metadata, err := json.Marshal(map[string]string{"session_id": v.SessionID, "device_info": v.DeviceInfo, "device_fingerprint": v.DeviceFingerprint, "ip_address": v.IPAddress, "user_agent": v.UserAgent})
	if err != nil {
		return errSessionStore
	}
	resourceType := "auth_session"
	_, err = s.storeNotification(ctx, notificationInput{UserID: v.UserID, Type: "login_alert", Title: "新设备登录提醒", Message: "你的账号刚刚通过新设备登录：" + v.DeviceInfo, ResourceType: &resourceType, Priority: "high", MetadataJSON: string(metadata)})
	return err
}
