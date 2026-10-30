package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"time"
)

type userPresence struct {
	UserID       int64   `json:"user_id"`
	OnlineStatus string  `json:"online_status"`
	LastSeenAt   *string `json:"last_seen_at"`
}

type presencePublisher interface {
	PublishPresence(context.Context, userPresence) error
}

func (s OracleSessions) UserPresence(ctx context.Context, user int64) (userPresence, error) {
	result := userPresence{UserID: user, OnlineStatus: "offline"}
	const query = `SELECT NVL(us.show_online_status,1), (SELECT MAX(s.last_accessed_at) FROM n_auth_sessions s WHERE s.user_id=u.user_id AND s.revoked_at IS NULL), CASE WHEN NVL(us.show_online_status,1)=0 THEN 'hidden' WHEN EXISTS (SELECT 1 FROM n_auth_sessions s WHERE s.user_id=u.user_id AND s.revoked_at IS NULL AND s.last_accessed_at >= CURRENT_TIMESTAMP - NUMTODSINTERVAL(90,'SECOND')) THEN 'online' ELSE 'offline' END FROM n_users u LEFT JOIN n_user_settings us ON us.user_id=u.user_id WHERE u.user_id=:user_id`
	var visible sql.NullInt64
	var lastSeen sql.NullTime
	var status sql.NullString
	err := s.DB.QueryRowContext(ctx, query, sql.Named("user_id", user)).Scan(&visible, &lastSeen, &status)
	if err == sql.ErrNoRows {
		return result, nil
	}
	if err != nil {
		return userPresence{}, errSessionStore
	}
	if status.String != "hidden" && status.String != "online" && status.String != "offline" {
		return userPresence{}, errSessionStore
	}
	result.OnlineStatus = status.String
	if visible.Valid && visible.Int64 == 1 && status.String != "hidden" {
		result.LastSeenAt = profileDate(lastSeen)
	}
	return result, nil
}

func (p *UserEventPublisher) PublishPresence(ctx context.Context, presence userPresence) error {
	if p == nil || p.client == nil || p.clock == nil || ctx.Err() != nil || p.serverID == "" || presence.UserID <= 0 || presence.UserID > 9007199254740991 {
		return errNotificationEvent
	}
	if presence.OnlineStatus != "online" && presence.OnlineStatus != "offline" && presence.OnlineStatus != "hidden" {
		return errNotificationEvent
	}
	if presence.OnlineStatus == "hidden" {
		presence.LastSeenAt = nil
	}
	payload, err := json.Marshal(struct {
		Type string `json:"type"`
		Data struct {
			userPresence
			ServerID string `json:"server_id"`
		} `json:"data"`
		Timestamp int64 `json:"timestamp"`
	}{Type: "presence_update", Data: struct {
		userPresence
		ServerID string `json:"server_id"`
	}{presence, p.serverID}, Timestamp: p.clock().UnixMilli()})
	if err != nil {
		return errNotificationEvent
	}
	ctx, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()
	if p.client.Publish(ctx, "ws:presence", payload).Err() != nil {
		return errNotificationEvent
	}
	return nil
}
