package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

var errNotificationEvent = errors.New("notification event unavailable")

type redisEventClient interface {
	Publish(context.Context, string, interface{}) *redis.IntCmd
	Close() error
}

// UserEventPublisher owns its Redis client and must be closed at shutdown.
// Construction is lazy and does not contact Redis.
type UserEventPublisher struct {
	client   redisEventClient
	serverID string
	clock    func() time.Time
}

func NewUserEventPublisher(rawURL string) (*UserEventPublisher, error) {
	if rawURL == "" {
		rawURL = "redis://127.0.0.1:6379/0"
	}
	if !strings.HasPrefix(rawURL, "redis://") && !strings.HasPrefix(rawURL, "rediss://") {
		return nil, errNotificationEvent
	}
	options, err := redis.ParseURL(rawURL)
	if err != nil {
		return nil, errNotificationEvent
	}
	options.MaxRetries = -1
	options.DialTimeout = 1500 * time.Millisecond
	options.ReadTimeout = 1500 * time.Millisecond
	options.WriteTimeout = 1500 * time.Millisecond
	id, err := randomUUID()
	if err != nil {
		return nil, errNotificationEvent
	}
	return &UserEventPublisher{client: redis.NewClient(options), serverID: "go_" + id, clock: time.Now}, nil
}

func (p *UserEventPublisher) Close() error {
	if p == nil || p.client == nil {
		return nil
	}
	if p.client.Close() != nil {
		return errNotificationEvent
	}
	return nil
}

func buildNotificationEvent(user int64, kind string, data map[string]interface{}, serverID string, timestamp int64) (string, []byte, error) {
	if user <= 0 || user > 9007199254740991 || serverID == "" {
		return "", nil, errNotificationEvent
	}
	switch kind {
	case "notification_created", "notification_read_status_updated", "notifications_read_status_updated", "notification_deleted", "notification_restored":
	default:
		return "", nil, errNotificationEvent
	}
	copyData := make(map[string]interface{}, len(data)+1)
	for key, value := range data {
		copyData[key] = value
	}
	copyData["server_id"] = serverID
	payload, err := json.Marshal(struct {
		Type      string                 `json:"type"`
		Data      map[string]interface{} `json:"data"`
		Timestamp int64                  `json:"timestamp"`
	}{kind, copyData, timestamp})
	if err != nil {
		return "", nil, errNotificationEvent
	}
	return fmt.Sprintf("ws:user:%d", user), payload, nil
}

func (p *UserEventPublisher) Publish(ctx context.Context, user int64, kind string, data map[string]interface{}) error {
	if p == nil || p.client == nil || p.clock == nil {
		return errNotificationEvent
	}
	if ctx.Err() != nil {
		return errNotificationEvent
	}
	channel, payload, err := buildNotificationEvent(user, kind, data, p.serverID, p.clock().UnixMilli())
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()
	if err = p.client.Publish(ctx, channel, payload).Err(); err != nil {
		return errNotificationEvent
	}
	return nil
}
