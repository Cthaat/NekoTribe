package server

import (
	"context"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func TestLocalPresenceWebSocketDegradedDeliveryAndRevocation(t *testing.T) {
	for _, state := range []string{"unavailable", "connecting"} {
		t.Run(state, func(t *testing.T) {
			source := &localTestSource{fail: true}
			if state == "connecting" {
				source = &localTestSource{gate: make(chan struct{})}
			}
			hub := newLocalTestHub(t, source, nil)
			codec, tokens := fixture(t)
			sessions := &socketSessions{}
			app := httptest.NewServer(NewHandlerWithConfig(codec, sessions, CorsPolicy{}, RefreshConfig{NotificationEvents: hub, PresencePublisher: hub}))
			defer app.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
			defer cancel()
			endpoint := "ws" + strings.TrimPrefix(app.URL, "http") + "/_ws?token=" + url.QueryEscape(tokens["access-hs256"])
			conn, _, err := websocket.Dial(ctx, endpoint, nil)
			if err != nil {
				t.Fatal(err)
			}
			defer conn.CloseNow()
			welcome := socketRead(t, conn)
			if welcome["type"] != "system_notification" {
				t.Fatal(welcome)
			}
			for {
				message := socketRead(t, conn)
				data, ok := message["data"].(map[string]interface{})
				if message["type"] != "system_notification" || !ok || data["code"] != "realtime_status" || data["user_id"] != float64(42) || data["local_presence"] != true {
					t.Fatal(message)
				}
				if data["remote_events"] == state {
					break
				}
			}
			lastSeen := "must-not-leak"
			_ = hub.PublishPresence(ctx, userPresence{UserID: 9, OnlineStatus: "hidden", LastSeenAt: &lastSeen})
			message := socketRead(t, conn)
			data := message["data"].(map[string]interface{})
			if message["type"] != "presence_update" || data["last_seen_at"] != nil || data["user_id"] != float64(9) {
				t.Fatal(message)
			}
			sessions.revoked.Store(true)
			_ = hub.PublishPresence(ctx, userPresence{UserID: 9, OnlineStatus: "online"})
			if _, _, err = conn.Read(ctx); err == nil {
				t.Fatal("revoked session received local event")
			}
		})
	}
}
