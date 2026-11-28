package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"time"
)

// Read under the same per-account lock as the subsequent session INSERT.
const loginHistorySQL = `SELECT
  (SELECT COUNT(*) FROM n_auth_sessions WHERE user_id=:user_id AND NVL(device_fingerprint,'unknown')=:device_fingerprint),
  (SELECT ip_address FROM n_auth_sessions WHERE user_id=:user_id ORDER BY created_at DESC, session_id ASC FETCH FIRST 1 ROW ONLY)
FROM dual`

type loginHistory struct {
	knownDevice bool
	previousIP  string
}

var errLoginHistoryUnavailable = errors.New("login history unavailable")

const loginAlertSettingsSQL = `SELECT NVL(us.login_alerts,1),NVL(us.email_notification_enabled,1),u.email FROM n_users u LEFT JOIN n_user_settings us ON us.user_id=u.user_id WHERE u.user_id=:user_id AND u.is_active=1`
const loginAlertTitle = "新设备登录提醒"

type LoginAlertDelivery struct {
	Email, Message string
	NotificationID int64
}

type loginAlertMailer interface {
	SendLoginAlert(context.Context, string, string, string, string) error
}

func deliverLoginAlert(ctx context.Context, store LoginRepository, config RefreshConfig, session LoginSession) {
	delivery, err := store.RecordLoginAlert(ctx, session)
	if err != nil {
		log.Print("login alert storage unavailable")
		return
	}
	if delivery.NotificationID > 0 && config.NotificationPublisher != nil {
		item, found, err := store.NotificationByID(ctx, session.UserID, delivery.NotificationID)
		if err != nil || found && config.NotificationPublisher.Publish(ctx, session.UserID, "notification_created",
			map[string]any{"notification": item, "notification_type": "login_alert"}) != nil {
			log.Print("login alert push unavailable")
		}
	}
	if delivery.Email != "" {
		mailer, ok := config.otpMailer.(loginAlertMailer)
		if !ok {
			log.Print("login alert email unavailable")
			return
		}
		go func() {
			mailCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 15*time.Second)
			defer cancel()
			if mailer.SendLoginAlert(mailCtx, delivery.Email, delivery.Message, session.IPAddress, session.UserAgent) != nil {
				log.Print("login alert email unavailable")
			}
		}()
	}
}

func readLoginHistory(ctx context.Context, tx *sql.Tx, v LoginSession) (loginHistory, error) {
	var known int64
	var prior sql.NullString
	if err := tx.QueryRowContext(ctx, loginHistorySQL, sql.Named("user_id", v.UserID), sql.Named("device_fingerprint", v.DeviceFingerprint)).Scan(&known, &prior); err != nil {
		return loginHistory{}, errLoginHistoryUnavailable
	}
	return loginHistory{known > 0, prior.String}, nil
}

func (s OracleSessions) RecordLoginAlert(ctx context.Context, v LoginSession) (LoginAlertDelivery, error) {
	var enabled, emailEnabled int64
	var email sql.NullString
	if err := s.DB.QueryRowContext(ctx, loginAlertSettingsSQL, sql.Named("user_id", v.UserID)).Scan(&enabled, &emailEnabled, &email); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return LoginAlertDelivery{}, nil
		}
		return LoginAlertDelivery{}, errSessionStore
	}
	if enabled == 0 {
		return LoginAlertDelivery{}, nil
	}
	metadata, err := json.Marshal(map[string]string{"session_id": v.SessionID, "device_info": v.DeviceInfo, "device_fingerprint": v.DeviceFingerprint, "ip_address": v.IPAddress, "user_agent": v.UserAgent})
	if err != nil {
		return LoginAlertDelivery{}, errSessionStore
	}
	device := v.DeviceInfo
	if device == "" {
		device = "unknown"
	}
	delivery := LoginAlertDelivery{Message: "你的账号刚刚通过新设备登录：" + device}
	title := loginAlertTitle
	if v.regionChanged {
		title = "异地登录提醒"
		delivery.Message = "你的账号刚刚在不同地区登录：" + device
	}
	if emailEnabled != 0 {
		delivery.Email = email.String
	}
	resourceType := "auth_session"
	stored, err := s.storeNotification(ctx, notificationInput{UserID: v.UserID, Type: "login_alert", Title: title, Message: delivery.Message, ResourceType: &resourceType, Priority: "high", MetadataJSON: string(metadata)})
	if err != nil {
		return LoginAlertDelivery{}, err
	}
	if stored != nil && stored.PushEnabled {
		delivery.NotificationID = stored.ID
	}
	return delivery, nil
}
