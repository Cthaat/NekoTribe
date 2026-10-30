package server

import (
	"context"
	"encoding/json"
	"testing"
	"time"
)

func TestPresenceEventRedactsHiddenLastSeen(t *testing.T) {
	fake := &eventFake{}
	publisher := UserEventPublisher{client: fake, serverID: "go-test", clock: func() time.Time { return time.UnixMilli(1234) }}
	lastSeen := "2026-01-01T00:00:00.000Z"
	if err := publisher.PublishPresence(context.Background(), userPresence{UserID: 42, OnlineStatus: "hidden", LastSeenAt: &lastSeen}); err != nil {
		t.Fatal(err)
	}
	var payload struct {
		Type string `json:"type"`
		Data struct {
			UserID   int64   `json:"user_id"`
			Status   string  `json:"online_status"`
			LastSeen *string `json:"last_seen_at"`
			ServerID string  `json:"server_id"`
		} `json:"data"`
		Timestamp int64 `json:"timestamp"`
	}
	if json.Unmarshal(fake.payload, &payload) != nil || fake.channel != "ws:presence" || payload.Type != "presence_update" || payload.Data.UserID != 42 || payload.Data.Status != "hidden" || payload.Data.LastSeen != nil || payload.Data.ServerID != "go-test" || payload.Timestamp != 1234 {
		t.Fatal(fake.channel, string(fake.payload))
	}
	fake.fail = true
	if publisher.PublishPresence(context.Background(), userPresence{UserID: 42, OnlineStatus: "online"}) == nil {
		t.Fatal("redis failure ignored")
	}
}
