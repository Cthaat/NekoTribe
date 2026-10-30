package server

import (
	"context"
	"fmt"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
)

type NotificationEventSource interface {
	Subscribe(context.Context, int64) (<-chan []byte, func(), error)
}

type RedisNotificationSource struct {
	client *redis.Client
	mu     sync.Mutex
	closed bool
	active map[*redis.PubSub]func()
}

// Resolve deployment settings without printing credentials. Explicit host,
// port, database and password override the URL, as in the Nuxt configuration.
func redisSourceOptions(lookup func(string) (string, bool)) (*redis.Options, error) {
	get := func(keys ...string) string {
		for _, key := range keys {
			if value, ok := lookup(key); ok && value != "" {
				return value
			}
		}
		return ""
	}
	docker := false
	for _, key := range []string{"NEKOTRIBE_DOCKER", "RUNNING_IN_DOCKER", "GO_BACKEND_DOCKER"} {
		switch strings.ToLower(strings.TrimSpace(get(key))) {
		case "true", "1", "yes", "on":
			docker = true
		}
	}
	urlValue := get("NUXT_REDIS_URL", "REDIS_URL")
	host := get("NUXT_REDIS_HOST", "REDIS_HOST")
	port := get("NUXT_REDIS_PORT", "REDIS_PORT")
	if docker {
		if v := get("DOCKER_REDIS_URL"); v != "" {
			urlValue = v
		}
		if v := get("DOCKER_REDIS_HOST"); v != "" {
			host = v
		}
		if v := get("DOCKER_REDIS_PORT"); v != "" {
			port = v
		}
	}
	if urlValue == "" {
		urlValue = "redis://127.0.0.1:6379/0"
	}
	if !strings.Contains(urlValue, "://") {
		urlValue = "redis://" + urlValue
	}
	if !strings.HasPrefix(urlValue, "redis://") && !strings.HasPrefix(urlValue, "rediss://") {
		return nil, errNotificationEvent
	}
	opts, err := redis.ParseURL(urlValue)
	if err != nil {
		return nil, errNotificationEvent
	}
	existingHost, existingPort, err := net.SplitHostPort(opts.Addr)
	if err != nil {
		return nil, errNotificationEvent
	}
	if host != "" {
		existingHost = host
	}
	if port != "" {
		n, e := strconv.Atoi(port)
		if e != nil || n < 1 || n > 65535 {
			return nil, errNotificationEvent
		}
		existingPort = strconv.Itoa(n)
	}
	if existingHost == "" || strings.ContainsAny(existingHost, "/\r\n") {
		return nil, errNotificationEvent
	}
	opts.Addr = net.JoinHostPort(existingHost, existingPort)
	if db := get("NUXT_REDIS_DB", "REDIS_DB"); db != "" {
		n, e := strconv.Atoi(db)
		if e != nil || n < 0 || n > 65535 {
			return nil, errNotificationEvent
		}
		opts.DB = n
	}
	if password := get("NUXT_REDIS_PASSWORD", "REDIS_PASSWORD"); password != "" {
		opts.Password = password
	}
	opts.MaxRetries = -1
	opts.DialTimeout = 1500 * time.Millisecond
	opts.ReadTimeout = 1500 * time.Millisecond
	opts.WriteTimeout = 1500 * time.Millisecond
	return opts, nil
}

func NewRedisNotificationSource(lookup func(string) (string, bool)) (*RedisNotificationSource, error) {
	opts, err := redisSourceOptions(lookup)
	if err != nil {
		return nil, errNotificationEvent
	}
	return &RedisNotificationSource{client: redis.NewClient(opts), active: make(map[*redis.PubSub]func())}, nil
}
func (s *RedisNotificationSource) Close() error {
	if s == nil || s.client == nil {
		return nil
	}
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return nil
	}
	s.closed = true
	stops := make([]func(), 0, len(s.active))
	for _, stop := range s.active {
		stops = append(stops, stop)
	}
	s.mu.Unlock()
	for _, stop := range stops {
		stop()
	}
	if s.client.Close() != nil {
		return errNotificationEvent
	}
	return nil
}

func (s *RedisNotificationSource) Subscribe(ctx context.Context, user int64) (<-chan []byte, func(), error) {
	if s == nil || s.client == nil || user <= 0 || user > 9007199254740991 {
		return nil, nil, errNotificationEvent
	}
	userChannel := fmt.Sprintf("ws:user:%d", user)
	ps := s.client.Subscribe(ctx, userChannel, "ws:presence")
	ackCtx, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	confirmed := make(map[string]bool, 2)
	var early [][]byte
	for len(confirmed) < 2 {
		ack, err := ps.Receive(ackCtx)
		if msg, ok := ack.(*redis.Message); ok && err == nil {
			data := []byte(msg.Payload)
			if len(data) <= 262144 && socketEventMatchesChannel(msg.Channel, userChannel, data) {
				if len(early) == 16 {
					cancel()
					_ = ps.Close()
					return nil, nil, errNotificationEvent
				}
				early = append(early, data)
			}
			continue
		}
		confirmation, ok := ack.(*redis.Subscription)
		if err != nil || !ok || confirmation == nil || confirmation.Kind != "subscribe" || (confirmation.Channel != userChannel && confirmation.Channel != "ws:presence") || confirmed[confirmation.Channel] {
			cancel()
			_ = ps.Close()
			return nil, nil, errNotificationEvent
		}
		confirmed[confirmation.Channel] = true
	}
	cancel()
	out := make(chan []byte, 16)
	for _, body := range early {
		out <- body
	}
	done := make(chan struct{})
	var once sync.Once
	stop := func() {
		once.Do(func() { close(done); _ = ps.Close(); s.mu.Lock(); delete(s.active, ps); s.mu.Unlock() })
	}
	s.mu.Lock()
	if s.closed || len(s.active) >= 1024 {
		s.mu.Unlock()
		stop()
		return nil, nil, errNotificationEvent
	}
	s.active[ps] = stop
	s.mu.Unlock()
	go func() {
		defer close(out)
		defer stop()
		events := ps.Channel(redis.WithChannelSize(32))
		for {
			select {
			case <-ctx.Done():
				return
			case <-done:
				return
			case event, ok := <-events:
				if !ok {
					return
				}
				data := []byte(event.Payload)
				if len(data) > 262144 {
					continue
				}
				if !socketEventMatchesChannel(event.Channel, userChannel, data) {
					continue
				}
				select {
				case out <- data:
				case <-ctx.Done():
					return
				case <-done:
					return
				default:
					return
				}
			}
		}
	}()
	return out, stop, nil
}
