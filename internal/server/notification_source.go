package server

import (
	"context"
	"fmt"
	"net"
	"net/url"
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

func (s *RedisNotificationSource) Ping(ctx context.Context) error {
	if s == nil || s.client == nil {
		return errNotificationEvent
	}
	if reply, err := s.client.Ping(ctx).Result(); err != nil || reply != "PONG" {
		return errNotificationEvent
	}
	return nil
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
	urlValue := sharedNativeEnv(lookup, "REDIS_URL")
	host := sharedNativeEnv(lookup, "REDIS_HOST")
	port := sharedNativeEnv(lookup, "REDIS_PORT")
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
	parsed, err := url.Parse(urlValue)
	if err != nil || (parsed.Scheme != "redis" && parsed.Scheme != "rediss") ||
		parsed.Hostname() == "" || parsed.Fragment != "" {
		return nil, errNotificationEvent
	}
	if _, err := configInt(parsed.Port(), 6379, 1, 65535); err != nil {
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
	if unbracketed, ok := strings.CutPrefix(existingHost, "["); ok {
		if ip, ok := strings.CutSuffix(unbracketed, "]"); ok && net.ParseIP(ip) != nil {
			existingHost = ip
		}
	}
	if _, err := configInt(existingPort, 6379, 1, 65535); err != nil ||
		existingHost == "" || strings.ContainsAny(existingHost, "/\r\n") || opts.DB < 0 || opts.DB > 65535 {
		return nil, errNotificationEvent
	}
	opts.Addr = net.JoinHostPort(existingHost, existingPort)
	if opts.TLSConfig != nil {
		opts.TLSConfig.ServerName = existingHost
	}
	if db := sharedNativeEnv(lookup, "REDIS_DB"); db != "" {
		n, e := strconv.Atoi(db)
		if e != nil || n < 0 || n > 65535 {
			return nil, errNotificationEvent
		}
		opts.DB = n
	}
	if password := sharedNativeEnv(lookup, "REDIS_PASSWORD"); password != "" {
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
	return s.subscribe(ctx, []string{userChannel, "ws:presence"}, func(channel string, body []byte) bool {
		return socketEventMatchesChannel(channel, userChannel, body)
	})
}

func (s *RedisNotificationSource) SubscribeChatChannel(ctx context.Context, id int64) (<-chan []byte, func(), error) {
	if s == nil || s.client == nil || id <= 0 || id > maxSocketID {
		return nil, nil, errNotificationEvent
	}
	channel := "ws:" + chatSocketRoom(id)
	return s.subscribe(ctx, []string{channel}, func(received string, body []byte) bool {
		return received == channel && validChatSocketEvent(id, body)
	})
}

func (s *RedisNotificationSource) subscribe(ctx context.Context, channels []string, matches func(string, []byte) bool) (<-chan []byte, func(), error) {
	ps := s.client.Subscribe(ctx, channels...)
	ackCtx, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	confirmed := make(map[string]bool, len(channels))
	for _, channel := range channels {
		confirmed[channel] = false
	}
	var early [][]byte
	for remaining := len(channels); remaining > 0; {
		ack, err := ps.Receive(ackCtx)
		if msg, ok := ack.(*redis.Message); ok && err == nil {
			data := []byte(msg.Payload)
			if len(data) <= 262144 && matches(msg.Channel, data) {
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
		if err != nil || !ok || confirmation == nil || confirmation.Kind != "subscribe" {
			cancel()
			_ = ps.Close()
			return nil, nil, errNotificationEvent
		}
		if received, expected := confirmed[confirmation.Channel]; !expected || received {
			cancel()
			_ = ps.Close()
			return nil, nil, errNotificationEvent
		}
		confirmed[confirmation.Channel] = true
		remaining--
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
	stopOnCancel := context.AfterFunc(ctx, stop)
	heartbeatDone := make(chan struct{})
	go func() {
		defer close(heartbeatDone)
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				pingCtx, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
				err := ps.Ping(pingCtx)
				cancel()
				if err != nil {
					stop()
					return
				}
			}
		}
	}()
	go func() {
		defer close(out)
		defer stopOnCancel()
		defer func() { stop(); <-heartbeatDone }()
		for {
			// Channel() reconnects internally and masks a lost subscription. Surface
			// the first read failure so the hybrid source can report/retry it.
			message, err := ps.ReceiveTimeout(ctx, 65*time.Second)
			if err != nil {
				return
			}
			event, ok := message.(*redis.Message)
			if !ok {
				if _, pong := message.(*redis.Pong); pong {
					continue
				}
				return
			}
			data := []byte(event.Payload)
			if len(data) > 262144 || !matches(event.Channel, data) {
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
	}()
	return out, stop, nil
}
