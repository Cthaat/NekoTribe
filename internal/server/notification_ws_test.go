package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
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
	source.send(42, `{"type":"presence_update","data":{"user_id":9,"online_status":"hidden","last_seen_at":null,"server_id":"peer"},"timestamp":1700000000123}`)
	source.send(9, `{"type":"presence_update","data":{"user_id":9,"online_status":"hidden","last_seen_at":null,"server_id":"peer"},"timestamp":1700000000123}`)
	if msg := socketRead(t, a); msg["type"] != "presence_update" {
		t.Fatal(msg)
	}
	if msg := socketRead(t, b); msg["type"] != "presence_update" {
		t.Fatal(msg)
	}
	sessions.revoked.Store(true)
	if err = a.Write(ctx, websocket.MessageText, []byte("{")); err != nil {
		t.Fatal(err)
	}
	staleCtx, stopStale := context.WithTimeout(context.Background(), 3*time.Second)
	defer stopStale()
	if _, _, err = a.Read(staleCtx); err == nil {
		t.Fatal("revoked session received a response to a malformed frame")
	} else if staleCtx.Err() != nil {
		t.Fatal("revoked session was not closed", err)
	}
	source.send(9, `{"type":"notification_created","data":{},"timestamp":1700000000123}`)
	readCtx, stop := context.WithTimeout(context.Background(), 3*time.Second)
	defer stop()
	_, _, err = b.Read(readCtx)
	if err == nil {
		t.Fatal("revoked session received event")
	}
}

func TestSocketEventAdmissionContract(t *testing.T) {
	data, err := os.ReadFile("../../contracts/scenarios/notification-websocket.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			ID, Channel, Raw string
			ChannelID        int64 `json:"channel_id"`
			Valid            bool
		} `json:"brokerCases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil || len(fixture.Cases) == 0 {
		t.Fatalf("missing broker vectors: %v", err)
	}
	for _, entry := range fixture.Cases {
		accepted := socketEventMatchesChannel(entry.Channel, "ws:user:42", []byte(entry.Raw))
		if entry.ChannelID != 0 {
			accepted = validChatSocketEvent(entry.ChannelID, []byte(entry.Raw))
		}
		if accepted != entry.Valid {
			t.Errorf("%s: accepted %t, want %t", entry.ID, accepted, entry.Valid)
		}
	}
}

func TestSocketEventChannelIsolationAndPrivacy(t *testing.T) {
	const user = "ws:user:42"
	valid := []byte(`{"type":"presence_update","data":{"user_id":9,"online_status":"hidden","last_seen_at":null,"server_id":"peer"},"timestamp":1}`)
	leak := []byte(`{"type":"presence_update","data":{"user_id":9,"online_status":"hidden","last_seen_at":"secret","server_id":"peer"},"timestamp":1}`)
	notification := []byte(`{"type":"notification_created","data":{},"timestamp":1}`)
	if !socketEventMatchesChannel("ws:presence", user, valid) || socketEventMatchesChannel(user, user, valid) || socketEventMatchesChannel("ws:presence", user, leak) || socketEventMatchesChannel("ws:presence", user, notification) || !socketEventMatchesChannel(user, user, notification) {
		t.Fatal("invalid channel or privacy handling")
	}
}

type chatSocketTestSessions struct {
	socketSessions
	allowed atomic.Bool
}

func (s *chatSocketTestSessions) CanReadChatChannel(_ context.Context, user, channel int64) (bool, error) {
	return user == 42 && channel == 7 && s.allowed.Load(), nil
}

func (s *chatSocketTestSessions) CanDeliverDirectMessage(_ context.Context, user, conversation, message int64, deleted bool) (bool, error) {
	return user == 42 && conversation == 12 && ((!deleted && message == 9) || (deleted && message == 10)), nil
}

type chatSocketTestSource struct {
	events chan []byte
	joined chan int64
	left   chan struct{}
}

func (s chatSocketTestSource) SubscribeChatChannel(_ context.Context, id int64) (<-chan []byte, func(), error) {
	s.joined <- id
	return s.events, func() { close(s.left) }, nil
}

func TestGoRealtimeChatRoomAndPrivateDirectDelivery(t *testing.T) {
	codec, tokens := fixture(t)
	sessions := &chatSocketTestSessions{}
	source := &fakeSocketSource{queues: map[int64]chan []byte{}}
	chat := chatSocketTestSource{make(chan []byte, 4), make(chan int64, 1), make(chan struct{})}
	app := httptest.NewServer(NewHandlerWithConfig(codec, sessions, CorsPolicy{}, RefreshConfig{NotificationEvents: source, ChatChannelEvents: chat}))
	defer app.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	endpoint := "ws" + strings.TrimPrefix(app.URL, "http") + "/_ws?token=" + url.QueryEscape(tokens["access-hs256"])
	conn, _, err := websocket.Dial(ctx, endpoint, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	_ = socketRead(t, conn)
	const join = `{"type":"chat_join_channel","data":{"channelId":7}}`
	send := func(raw string) {
		t.Helper()
		if err := conn.Write(ctx, websocket.MessageText, []byte(raw)); err != nil {
			t.Fatal(err)
		}
	}
	send(join)
	if event := socketRead(t, conn); event["type"] != "error" {
		t.Fatal(event)
	}
	sessions.allowed.Store(true)
	send(join)
	if event := socketRead(t, conn); event["type"] != "system_notification" {
		t.Fatal(event)
	}
	select {
	case id := <-chat.joined:
		if id != 7 {
			t.Fatal(id)
		}
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	if event := socketRead(t, conn); event["type"] != "system_notification" ||
		event["data"].(map[string]interface{})["code"] != "chat_channel_ready" {
		t.Fatal(event)
	}
	chat.events <- []byte(`{"type":"chat_message","data":{"channel_id":8},"timestamp":1}`)
	chat.events <- []byte(`{"type":"chat_message","room":"chat:channel:7","data":{"channel_id":7},"timestamp":1}`)
	if event := socketRead(t, conn); event["room"] != "chat:channel:7" {
		t.Fatal(event)
	}
	const dm = `{"type":"direct_message","data":{"conversation_id":12,"direct_message":{"message_id":9,"conversation_id":12}},"timestamp":1}`
	if socketEventMatchesChannel("ws:user:9", "ws:user:42", []byte(dm)) ||
		socketEventMatchesChannel("ws:presence", "ws:user:42", []byte(dm)) {
		t.Fatal("private event matched unrelated channel")
	}
	source.send(42, strings.Replace(dm, `"message_id":9`, `"message_id":8`, 1))
	source.send(42, dm)
	if event := socketRead(t, conn); event["type"] != "direct_message" ||
		event["data"].(map[string]interface{})["direct_message"].(map[string]interface{})["message_id"] != float64(9) {
		t.Fatal(event)
	}
	source.send(42, `{"type":"direct_message_deleted","data":{"conversation_id":12,"message_id":9},"timestamp":1}`)
	source.send(42, `{"type":"direct_message_deleted","data":{"conversation_id":12,"message_id":10},"timestamp":1}`)
	if event := socketRead(t, conn); event["type"] != "direct_message_deleted" ||
		event["data"].(map[string]interface{})["message_id"] != float64(10) {
		t.Fatal(event)
	}
	source.send(42, `{"type":"direct_message_updated","data":{"conversation_id":12,"message_id":10},"timestamp":1}`)
	source.send(42, `{"type":"direct_message_updated","data":{"conversation_id":12,"message_id":9,"reactions":[]},"timestamp":1}`)
	source.send(42, `{"type":"direct_message_updated","data":{"conversation_id":12,"message_id":9},"timestamp":1}`)
	if event := socketRead(t, conn); event["type"] != "direct_message_updated" || event["data"].(map[string]any)["message_id"] != float64(9) {
		t.Fatal(event)
	}
	sessions.allowed.Store(false)
	chat.events <- []byte(`{"type":"chat_message","data":{"channel_id":7},"timestamp":1}`)
	select {
	case <-chat.left:
	case <-ctx.Done():
		t.Fatal("room was not released after permission loss")
	}
	send(`{"type":"ping"}`)
	if event := socketRead(t, conn); event["type"] != "pong" {
		t.Fatal(event)
	}
}
func TestNotificationWebSocketRejectsUnauthorizedOriginAndUnavailableSource(t *testing.T) {
	codec, tokens := fixture(t)
	sessions := &socketSessions{}
	source := &fakeSocketSource{queues: map[int64]chan []byte{}}
	app := httptest.NewServer(NewHandlerWithConfig(codec, sessions, CorsPolicy{}, RefreshConfig{
		NotificationEvents: source,
		Storage:            StorageURLPolicy{BaseURL: "https://neko.example:8443/"},
	}))
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
		{"", "https://neko.example:8443", "", 401}, // Origin passes; credentials are still required.
		{"", "https://neko.example", "", 403},
		{"", "https://neko.example:8443/path", "", 403},
		{"", "https" + strings.TrimPrefix(app.URL, "http"), "", 403},
		{"?token=" + url.QueryEscape(tokens["access-hs256"]), "http://untrusted.example", "", 403},
	} {
		header := http.Header{}
		header.Set("X-Forwarded-Proto", "https")
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
	env := map[string]string{"REDIS_URL": "redis://:url-secret@redis.internal:6380/3", "REDIS_HOST": "override.internal", "REDIS_PORT": "6381", "REDIS_DB": "4", "REDIS_PASSWORD": "new@secret:%2F/%25"}
	lookup := func(k string) (string, bool) { v, ok := env[k]; return v, ok }
	o, err := redisSourceOptions(lookup)
	if err != nil || o.Addr != "override.internal:6381" || o.DB != 4 || o.Password != "new@secret:%2F/%25" {
		t.Fatal("incorrect redis configuration")
	}
	env["REDIS_PORT"] = "invalid-secret"
	_, err = redisSourceOptions(lookup)
	if err == nil || strings.Contains(err.Error(), "secret") {
		t.Fatal("unsafe configuration error")
	}
	env["NUXT_REDIS_URL"] = "rediss://redis.origin.test:6380/3"
	env["NUXT_REDIS_PORT"] = ""
	env["NUXT_REDIS_DB"] = ""
	o, err = redisSourceOptions(lookup)
	if err != nil || o.TLSConfig == nil || o.TLSConfig.ServerName != "override.internal" ||
		o.Addr != "override.internal:6380" || o.DB != 3 {
		t.Fatal("secure Redis target did not follow the actual connection address")
	}
}
