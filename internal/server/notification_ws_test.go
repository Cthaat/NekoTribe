package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"github.com/coder/websocket"
)

type socketSessions struct{ revoked atomic.Bool }

func (s *socketSessions) Touch(_ context.Context, c auth.Claims) (int64, error) {
	if s.revoked.Load() {
		return 0, nil
	}
	if c.UserID == 42 || c.UserID == 9 {
		return 1, nil
	}
	return 0, nil
}
func (s *socketSessions) Revoke(context.Context, int64, string) (int64, error)       { return 0, nil }
func (s *socketSessions) RevokeOthers(context.Context, int64, string) (int64, error) { return 0, nil }

type fakeSocketSource struct {
	mu     sync.Mutex
	queues map[int64]chan []byte
	stops  atomic.Int32
	fail   bool
}

func (s *fakeSocketSource) Subscribe(_ context.Context, user int64) (<-chan []byte, func(), error) {
	if s.fail {
		return nil, nil, errors.New("private redis detail")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	q := make(chan []byte, 8)
	s.queues[user] = q
	var once sync.Once
	return q, func() { once.Do(func() { s.stops.Add(1) }) }, nil
}
func (s *fakeSocketSource) send(user int64, body string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.queues[user] <- []byte(body)
}
func socketRead(t *testing.T, c *websocket.Conn) map[string]interface{} {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_, data, err := c.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]interface{}
	if json.Unmarshal(data, &out) != nil {
		t.Fatal("invalid json")
	}
	return out
}
func TestNotificationWebSocketAuthIsolationHeartbeatAndRevocation(t *testing.T) {
	codec, tokens := fixture(t)
	sessions := &socketSessions{}
	source := &fakeSocketSource{queues: map[int64]chan []byte{}}
	app := httptest.NewServer(NewHandlerWithConfig(codec, sessions, CorsPolicy{}, RefreshConfig{NotificationEvents: source}))
	defer app.Close()
	endpoint := "ws" + strings.TrimPrefix(app.URL, "http") + "/_ws"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	other, err := codec.Sign(auth.Claims{UserID: 9, UserName: "peer", SessionID: "peer-session", JTI: "peer-jti", Kind: auth.Access}, 600)
	if err != nil {
		t.Fatal(err)
	}
	a, _, err := websocket.Dial(ctx, endpoint+"?token="+url.QueryEscape(tokens["access-hs256"]), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer a.CloseNow()
	b, _, err := websocket.Dial(ctx, endpoint+"?token="+url.QueryEscape(other), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer b.CloseNow()
	for _, pair := range []struct {
		c    *websocket.Conn
		user float64
	}{{a, 42}, {b, 9}} {
		msg := socketRead(t, pair.c)
		data, ok := msg["data"].(map[string]interface{})
		if msg["type"] != "system_notification" || !ok || data["user_id"] != pair.user {
			t.Fatal(msg)
		}
	}
	if err = a.Write(ctx, websocket.MessageText, []byte(`{"type":"ping"}`)); err != nil {
		t.Fatal(err)
	}
	if msg := socketRead(t, a); msg["type"] != "pong" {
		t.Fatal(msg)
	}
	source.send(42, `{"type":"unsupported","data":{},"timestamp":1700000000123}`)
	source.send(42, `{"type":"notification_created","data":{"server_id":"other","notification_type":"like"},"timestamp":1700000000123}`)
	if msg := socketRead(t, a); msg["type"] != "notification_created" {
		t.Fatal(msg)
	}
	sessions.revoked.Store(true)
	source.send(9, `{"type":"notification_created","data":{},"timestamp":1700000000123}`)
	readCtx, stop := context.WithTimeout(context.Background(), 3*time.Second)
	defer stop()
	_, _, err = b.Read(readCtx)
	if err == nil {
		t.Fatal("revoked session received event")
	}
}
func TestNotificationWebSocketRejectsUnauthorizedOriginAndUnavailableSource(t *testing.T) {
	codec, tokens := fixture(t)
	sessions := &socketSessions{}
	source := &fakeSocketSource{queues: map[int64]chan []byte{}}
	app := httptest.NewServer(NewHandlerWithConfig(codec, sessions, CorsPolicy{}, RefreshConfig{NotificationEvents: source}))
	defer app.Close()
	endpoint := "ws" + strings.TrimPrefix(app.URL, "http") + "/_ws"
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	for _, tc := range []struct {
		path, origin, bearer string
		status               int
	}{
		{"", "", "", 401},
		{"?token=bad", "", tokens["access-hs256"], 401},
		{"", "", "bad", 401},
		{"?token=" + url.QueryEscape(tokens["access-hs256"]), "http://untrusted.example", "", 403},
	} {
		header := http.Header{}
		if tc.origin != "" {
			header.Set("Origin", tc.origin)
		}
		if tc.bearer != "" {
			header.Set("Authorization", "Bearer "+tc.bearer)
		}
		_, resp, err := websocket.Dial(ctx, endpoint+tc.path, &websocket.DialOptions{HTTPHeader: header})
		if err == nil || resp == nil || resp.StatusCode != tc.status {
			t.Fatalf("status=%v err=%v", resp, err)
		}
	}
	sessions.revoked.Store(true)
	_, resp, err := websocket.Dial(ctx, endpoint+"?token="+url.QueryEscape(tokens["access-hs256"]), nil)
	if err == nil || resp == nil || resp.StatusCode != 401 {
		t.Fatal("revoked session was accepted")
	}
	sessions.revoked.Store(false)
	source.fail = true
	_, resp, err = websocket.Dial(ctx, endpoint+"?token="+url.QueryEscape(tokens["access-hs256"]), nil)
	if err == nil || resp == nil || resp.StatusCode != 503 {
		t.Fatal(resp, err)
	}
}

func TestNotificationWebSocketCookieSameOriginAndMalformedHandshake(t *testing.T) {
	codec, tokens := fixture(t)
	sessions := &socketSessions{}
	source := &fakeSocketSource{queues: map[int64]chan []byte{}}
	app := httptest.NewServer(NewHandlerWithConfig(codec, sessions, CorsPolicy{}, RefreshConfig{NotificationEvents: source}))
	defer app.Close()
	plain, err := http.Get(app.URL + "/_ws?token=" + url.QueryEscape(tokens["access-hs256"]))
	if err != nil {
		t.Fatal(err)
	}
	defer plain.Body.Close()
	if plain.StatusCode != 400 {
		t.Fatal(plain.StatusCode)
	}
	endpoint := "ws" + strings.TrimPrefix(app.URL, "http") + "/_ws"
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	header := http.Header{"Origin": []string{app.URL}, "Cookie": []string{"access_token=" + tokens["access-hs256"]}}
	conn, _, err := websocket.Dial(ctx, endpoint, &websocket.DialOptions{HTTPHeader: header})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	message := socketRead(t, conn)
	if message["type"] != "system_notification" {
		t.Fatal(message)
	}
}

func TestNotificationWebSocketExpiryStopsDelivery(t *testing.T) {
	var now atomic.Int64
	now.Store(1700000000)
	codec, err := auth.NewTokenManager([]byte("synthetic-access-key"), []byte("synthetic-refresh-key"), func() time.Time { return time.Unix(now.Load(), 0) })
	if err != nil {
		t.Fatal(err)
	}
	token, err := codec.Sign(auth.Claims{UserID: 42, UserName: "viewer", SessionID: "session", JTI: "jti", Kind: auth.Access}, 10)
	if err != nil {
		t.Fatal(err)
	}
	source := &fakeSocketSource{queues: map[int64]chan []byte{}}
	app := httptest.NewServer(NewHandlerWithConfig(codec, &socketSessions{}, CorsPolicy{}, RefreshConfig{NotificationEvents: source}))
	defer app.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	endpoint := "ws" + strings.TrimPrefix(app.URL, "http") + "/_ws?token=" + url.QueryEscape(token)
	conn, _, err := websocket.Dial(ctx, endpoint, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	socketRead(t, conn)
	now.Add(11)
	source.send(42, `{"type":"notification_created","data":{},"timestamp":1}`)
	_, _, err = conn.Read(ctx)
	if err == nil {
		t.Fatal("expired token received event")
	}
}
func TestRedisNotificationSourceOptionsAndSecretRedaction(t *testing.T) {
	env := map[string]string{"REDIS_URL": "redis://:url-secret@redis.internal:6380/3", "REDIS_HOST": "override.internal", "REDIS_PORT": "6381", "REDIS_DB": "4", "REDIS_PASSWORD": "override-secret"}
	lookup := func(k string) (string, bool) { v, ok := env[k]; return v, ok }
	o, err := redisSourceOptions(lookup)
	if err != nil || o.Addr != "override.internal:6381" || o.DB != 4 || o.Password != "override-secret" {
		t.Fatal("incorrect redis configuration")
	}
	env["REDIS_PORT"] = "invalid-secret"
	_, err = redisSourceOptions(lookup)
	if err == nil || strings.Contains(err.Error(), "secret") {
		t.Fatal("unsafe configuration error")
	}
}
