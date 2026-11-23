package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"net/url"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"github.com/coder/websocket"
	"github.com/redis/go-redis/v9"
)

const (
	webRTCTestCall      = "f8e1f188-63d9-4bd0-8c5a-5d768479f944"
	webRTCTestOtherCall = "884c9fa8-6a98-4b7d-b2ae-d60a3767cd32"
	webRTCTestCaller    = "678bb174-5e41-455b-97cb-9ddbc60c6fcd"
	webRTCTestCallee    = "47124f3e-c59b-4769-adb6-0a03edd817ba"
)

type webRTCTestStep struct {
	action, actor, status string
}

type webRTCTestRedis struct {
	mu       sync.Mutex
	next     []webRTCTestStep
	current  map[string]any
	invalid  bool
	channels []string
}

func (store *webRTCTestRedis) Eval(_ context.Context, script string, keys []string, args ...any) *redis.Cmd {
	store.mu.Lock()
	defer store.mu.Unlock()
	if len(args) != 11 || len(store.next) == 0 || script != webRTCStateScript {
		store.invalid = true
		return redis.NewCmdResult(nil, errors.New("unexpected redis call"))
	}
	step := store.next[0]
	store.next = store.next[1:]
	peer := "42"
	if step.actor == "42" {
		peer = "9"
	}
	callID := webRTCTestCall
	if step.status == "busy" {
		callID = webRTCTestOtherCall
	}
	if args[0] != step.action || args[1] != callID || args[2] != "12" || args[3] != step.actor || args[4] != peer ||
		args[9] != int64(30000) || args[10] != int64(14400000) || !strings.HasPrefix(args[6].(string), "ws_") ||
		!slices.Equal(keys, []string{"nt:{webrtc}:call:" + callID, "nt:{webrtc}:user:" + step.actor, "nt:{webrtc}:user:" + peer}) {
		store.invalid = true
		return redis.NewCmdResult(nil, errors.New("unexpected redis command bindings"))
	}
	if step.status == "busy" || step.status == "forbidden" {
		if step.status == "forbidden" && (args[5] != store.current["callee_client_id"] || args[6] == store.current["callee_connection"]) {
			store.invalid = true
		}
		return redis.NewCmdResult([]any{step.status, ""}, nil)
	}
	switch step.action {
	case "invite":
		store.current = map[string]any{
			"call_id": args[1], "conversation_id": args[2], "caller_id": args[3], "callee_id": args[4],
			"caller_client_id": args[5], "caller_connection": args[6], "mode": args[7], "stage": "ringing",
			"deadline": args[8].(int64) + args[9].(int64),
		}
	case "accept":
		store.current["callee_client_id"], store.current["callee_connection"] = args[5], args[6]
		store.current["stage"], store.current["deadline"] = "await_offer", args[8].(int64)+args[10].(int64)
	case "offer":
		store.current["stage"] = "await_answer"
	case "answer":
		store.current["stage"] = "connected"
	}
	encoded, _ := json.Marshal(store.current)
	if step.action == "disconnect" || step.action == "expire" {
		store.current = nil
	}
	return redis.NewCmdResult([]any{step.status, string(encoded)}, nil)
}

func (store *webRTCTestRedis) Get(_ context.Context, key string) *redis.StringCmd {
	store.mu.Lock()
	defer store.mu.Unlock()
	if store.current == nil || key != "nt:{webrtc}:call:"+webRTCTestCall {
		return redis.NewStringResult("", redis.Nil)
	}
	encoded, _ := json.Marshal(store.current)
	return redis.NewStringResult(string(encoded), nil)
}

func (store *webRTCTestRedis) Publish(_ context.Context, channel string, _ any) *redis.IntCmd {
	store.mu.Lock()
	defer store.mu.Unlock()
	store.channels = append(store.channels, channel)
	return redis.NewIntResult(1, nil)
}

func (*webRTCTestRedis) Close() error { return nil }

func makeWebRTCTestingFrame(kind, callID, client, more string) []byte {
	return []byte(`{"type":"` + kind + `","data":{"call_id":"` + callID + `","client_id":"` + client + `","conversation_id":12` + more + `}}`)
}

func TestWebRTCSocketScopesSignalsAndReleasesOnDisconnect(t *testing.T) {
	codec, tokens := fixture(t)
	redisFixture := &webRTCTestRedis{next: []webRTCTestStep{
		{"invite", "42", "ok"}, {"invite", "9", "busy"}, {"accept", "9", "ok"}, {"offer", "42", "ok"},
		{"answer", "9", "forbidden"}, {"answer", "9", "ok"}, {"ice", "42", "ok"}, {"disconnect", "9", "ok"},
	}}
	hub, err := NewLocalPresenceEvents(nil, &UserEventPublisher{client: redisFixture, serverID: "fixture", clock: time.Now})
	if err != nil {
		t.Fatal(err)
	}
	defer hub.Close()
	sessions := &chatSignalsTestSessions{}
	sessions.direct.Store(true)
	app := httptest.NewServer(NewHandlerWithConfig(codec, sessions, CorsPolicy{}, RefreshConfig{NotificationEvents: hub, DirectEvents: hub}))
	defer app.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	peerToken, err := codec.Sign(auth.Claims{UserID: 9, UserName: "peer", SessionID: "peer-session", JTI: "peer-jti", Kind: auth.Access}, 600)
	if err != nil {
		t.Fatal(err)
	}
	dial := func(token string) *websocket.Conn {
		t.Helper()
		endpoint := "ws" + strings.TrimPrefix(app.URL, "http") + "/_ws?token=" + url.QueryEscape(token)
		conn, _, err := websocket.Dial(ctx, endpoint, nil)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { conn.CloseNow() })
		for i := 0; i < 2; i++ {
			if event := socketRead(t, conn); event["type"] != "system_notification" {
				t.Fatal(event["type"])
			}
		}
		return conn
	}
	caller, callee, sibling := dial(tokens["access-hs256"]), dial(peerToken), dial(peerToken)
	defer caller.CloseNow()
	defer callee.CloseNow()
	defer sibling.CloseNow()
	send := func(conn *websocket.Conn, kind, callID, device, more string) {
		t.Helper()
		if err := conn.Write(ctx, websocket.MessageText, makeWebRTCTestingFrame(kind, callID, device, more)); err != nil {
			t.Fatal(err)
		}
	}
	want := func(conn *websocket.Conn, kind string) map[string]any {
		t.Helper()
		event := socketRead(t, conn)
		if event["type"] != kind {
			t.Fatalf("expected %s, received %v", kind, event["type"])
		}
		return event["data"].(map[string]any)
	}
	send(caller, webRTCInvite, webRTCTestCall, webRTCTestCaller, `,"mode":"video","caller_id":9`)
	want(caller, "error")
	send(caller, webRTCInvite, webRTCTestCall, webRTCTestCaller, `,"mode":"video"`)
	for _, conn := range []*websocket.Conn{caller, callee, sibling} {
		if data := want(conn, webRTCInvite); data["caller_id"] != float64(42) || data["callee_id"] != float64(9) {
			t.Fatal("invitation participants did not come from the authorized pair")
		}
	}
	send(sibling, webRTCInvite, webRTCTestOtherCall, webRTCTestCallee, `,"mode":"voice"`)
	want(sibling, webRTCBusy)
	send(callee, webRTCAccept, webRTCTestCall, webRTCTestCallee, "")
	for _, conn := range []*websocket.Conn{caller, callee, sibling} {
		want(conn, webRTCAccept)
	}
	send(caller, webRTCOffer, webRTCTestCall, webRTCTestCaller, `,"sdp":"fixture-offer"`)
	if data := want(callee, webRTCOffer); data["sdp"] != "fixture-offer" || data["caller_connection"] != nil {
		t.Fatal("invalid scoped SDP offer")
	}
	if err := hub.publishUserRealtime(ctx, "notification_created", map[string]any{}, 9); err != nil {
		t.Fatal(err)
	}
	want(sibling, "notification_created")
	want(callee, "notification_created")
	send(sibling, webRTCAnswer, webRTCTestCall, webRTCTestCallee, `,"sdp":"fixture-wrong-connection"`)
	want(sibling, "error")
	send(callee, webRTCAnswer, webRTCTestCall, webRTCTestCallee, `,"sdp":"fixture-answer"`)
	want(caller, webRTCAnswer)

	sessions.direct.Store(false)
	send(caller, webRTCIce, webRTCTestCall, webRTCTestCaller, `,"candidates":[{"candidate":"fixture-ice","sdp_mline_index":0}]`)
	want(caller, "error")
	sessions.direct.Store(true)
	send(caller, webRTCIce, webRTCTestCall, webRTCTestCaller, `,"candidates":[{"candidate":"fixture-ice","sdp_mline_index":0}]`)
	want(callee, webRTCIce)
	callee.CloseNow()
	want(caller, webRTCHangup)
	want(sibling, webRTCHangup)
	redisFixture.mu.Lock()
	defer redisFixture.mu.Unlock()
	if redisFixture.invalid || len(redisFixture.next) != 0 || redisFixture.current != nil {
		t.Fatal("unexpected shared Redis transitions")
	}
}

func TestWebRTCRingTimeoutAndUnavailableStayScoped(t *testing.T) {
	fixture := &webRTCTestRedis{next: []webRTCTestStep{{"invite", "42", "ok"}, {"expire", "42", "timeout"}}}
	hub, err := NewLocalPresenceEvents(nil, &UserEventPublisher{client: fixture, serverID: "fixture", clock: time.Now})
	if err != nil {
		t.Fatal(err)
	}
	defer hub.Close()
	sessions := &chatSignalsTestSessions{}
	sessions.direct.Store(true)
	now := time.Now()
	config := RefreshConfig{DirectEvents: hub, clock: func() time.Time { return now }}
	ctx := context.Background()
	invitation := makeWebRTCTestingFrame(webRTCInvite, webRTCTestCall, webRTCTestCaller, `,"mode":"voice"`)
	socket := newWebRTCSocket(42, "ws_fixture", sessions, config)
	defer socket.disconnect(ctx)
	if kind, _ := socket.request(ctx, webRTCInvite, invitation); kind != "" || socket.ringDeadline() == nil {
		t.Fatal("successful invitation did not schedule a ringing deadline")
	}
	now = now.Add(30 * time.Second)
	socket.expire(ctx)
	fixture.mu.Lock()
	if fixture.invalid || len(fixture.next) != 0 || fixture.current != nil ||
		!slices.Equal(fixture.channels, []string{"ws:user:42", "ws:user:9", "ws:user:42", "ws:user:9"}) {
		t.Error("timeout did not release and notify only the participants")
	}
	fixture.mu.Unlock()
	unavailable := newWebRTCSocket(42, "ws_fixture", sessions, RefreshConfig{clock: time.Now})
	if kind, data := unavailable.request(ctx, webRTCInvite, invitation); kind != webRTCUnavailable || data["callee_id"] != int64(9) {
		t.Fatal("authorized invitation did not receive a local unavailable response")
	}
}
