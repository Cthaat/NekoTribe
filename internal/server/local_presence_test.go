package server

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"
)

type localTestSource struct {
	mu     sync.Mutex
	fail   bool
	gate   <-chan struct{}
	queues map[int64]chan []byte
}

func (s *localTestSource) Subscribe(ctx context.Context, user int64) (<-chan []byte, func(), error) {
	if s.gate != nil {
		select {
		case <-s.gate:
		case <-ctx.Done():
			return nil, nil, ctx.Err()
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.fail {
		return nil, nil, errors.New("isolated remote unavailable")
	}
	q := make(chan []byte, 32)
	if s.queues == nil {
		s.queues = map[int64]chan []byte{}
	}
	s.queues[user] = q
	var once sync.Once
	return q, func() {
		once.Do(func() {
			s.mu.Lock()
			if s.queues[user] == q {
				delete(s.queues, user)
			}
			s.mu.Unlock()
		})
	}, nil
}
func (s *localTestSource) send(user int64, body []byte) {
	s.mu.Lock()
	q := s.queues[user]
	s.mu.Unlock()
	q <- body
}
func (s *localTestSource) disconnect(user int64) {
	s.mu.Lock()
	q := s.queues[user]
	delete(s.queues, user)
	s.mu.Unlock()
	close(q)
}
func readLocalKind(t *testing.T, q <-chan []byte, kind string) map[string]interface{} {
	t.Helper()
	timer := time.NewTimer(2 * time.Second)
	defer timer.Stop()
	for {
		select {
		case raw, ok := <-q:
			if !ok {
				t.Fatal("subscription closed")
			}
			var value map[string]interface{}
			if json.Unmarshal(raw, &value) != nil {
				t.Fatal("invalid event")
			}
			if value["type"] == kind {
				return value
			}
		case <-timer.C:
			t.Fatal("event not delivered")
			return nil
		}
	}
}
func readRemoteStatus(t *testing.T, q <-chan []byte, want string) {
	t.Helper()
	for i := 0; i < 4; i++ {
		value := readLocalKind(t, q, "system_notification")
		data := value["data"].(map[string]interface{})
		if data["code"] != "realtime_status" {
			t.Fatal(data)
		}
		if data["remote_events"] == want {
			if data["local_presence"] != true {
				t.Fatal(data)
			}
			return
		}
	}
	t.Fatal("status not reached", want)
}
func newLocalTestHub(t *testing.T, source NotificationEventSource, remote *UserEventPublisher) *LocalPresenceEvents {
	t.Helper()
	hub, err := NewLocalPresenceEvents(source, remote)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.Close() })
	return hub
}
func TestLocalPresenceWithoutRedis(t *testing.T) {
	hub := newLocalTestHub(t, &localTestSource{fail: true}, nil)
	q, stop, err := hub.Subscribe(context.Background(), 42)
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	readRemoteStatus(t, q, "unavailable")
	_ = hub.PublishPresence(context.Background(), userPresence{UserID: 9, OnlineStatus: "hidden"})
	frame := readLocalKind(t, q, "presence_update")
	if frame["data"].(map[string]interface{})["last_seen_at"] != nil {
		t.Fatal(frame)
	}
}
func TestLocalPresenceWhileRemoteConnecting(t *testing.T) {
	hub := newLocalTestHub(t, &localTestSource{gate: make(chan struct{})}, nil)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	q, stop, err := hub.Subscribe(ctx, 42)
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	readRemoteStatus(t, q, "connecting")
	_ = hub.PublishPresence(context.Background(), userPresence{UserID: 42, OnlineStatus: "online"})
	readLocalKind(t, q, "presence_update")
}
func TestLocalPresenceFiltersOnlyOwnPresenceEcho(t *testing.T) {
	source := &localTestSource{}
	fake := &eventFake{}
	remote := &UserEventPublisher{client: fake, serverID: "test-instance", clock: func() time.Time { return time.UnixMilli(1234) }}
	hub := newLocalTestHub(t, source, remote)
	q, stop, err := hub.Subscribe(context.Background(), 42)
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	readRemoteStatus(t, q, "connected")
	if hub.PublishPresence(context.Background(), userPresence{UserID: 42, OnlineStatus: "hidden"}) != nil {
		t.Fatal("remote publish failed")
	}
	readLocalKind(t, q, "presence_update")
	source.send(42, append([]byte(nil), fake.payload...))
	source.send(42, []byte(strings.ReplaceAll(string(fake.payload), `test-instance`, `peer-instance`)))
	peer := readLocalKind(t, q, "presence_update")
	if peer["data"].(map[string]interface{})["server_id"] != "peer-instance" {
		t.Fatal("own Redis echo duplicated", peer)
	}
	source.send(42, []byte(`{"type":"notification_created","data":{"server_id":"test-instance"},"timestamp":1}`))
	readLocalKind(t, q, "notification_created")
}
func TestLocalPresenceRemoteCloseAndRecovery(t *testing.T) {
	source := &localTestSource{}
	hub := newLocalTestHub(t, source, nil)
	q, stop, err := hub.Subscribe(context.Background(), 42)
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	readRemoteStatus(t, q, "connected")
	source.disconnect(42)
	readRemoteStatus(t, q, "unavailable")
	_ = hub.PublishPresence(context.Background(), userPresence{UserID: 42, OnlineStatus: "hidden"})
	readLocalKind(t, q, "presence_update")
	readRemoteStatus(t, q, "connected")
}

func TestLocalPresencePublishFailureStillDeliversLocally(t *testing.T) {
	fake := &eventFake{fail: true}
	remote := &UserEventPublisher{client: fake, serverID: "test-instance", clock: func() time.Time { return time.UnixMilli(1234) }}
	hub := newLocalTestHub(t, nil, remote)
	q, stop, err := hub.Subscribe(context.Background(), 42)
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	readRemoteStatus(t, q, "unavailable")
	if hub.PublishPresence(context.Background(), userPresence{UserID: 9, OnlineStatus: "hidden"}) == nil {
		t.Fatal("remote failure must remain observable to caller")
	}
	readLocalKind(t, q, "presence_update")
	if fake.calls != 1 {
		t.Fatal("publication replayed", fake.calls)
	}
}

func TestLocalPresencePrivateIsolationAndBrokerStatusRejected(t *testing.T) {
	source := &localTestSource{}
	hub := newLocalTestHub(t, source, nil)
	q42, stop42, err := hub.Subscribe(context.Background(), 42)
	if err != nil {
		t.Fatal(err)
	}
	defer stop42()
	q9, stop9, err := hub.Subscribe(context.Background(), 9)
	if err != nil {
		t.Fatal(err)
	}
	defer stop9()
	readRemoteStatus(t, q42, "connected")
	readRemoteStatus(t, q9, "connected")
	source.send(42, hub.status(42, "unavailable"))
	source.send(42, []byte(`{"type":"notification_created","data":{"private":"only-42"},"timestamp":1}`))
	select {
	case raw := <-q42:
		var value struct {
			Type string
			Data map[string]interface{}
		}
		if json.Unmarshal(raw, &value) != nil || value.Type != "notification_created" || value.Data["private"] != "only-42" {
			t.Fatal("broker status was forwarded", string(raw))
		}
	case <-time.After(2 * time.Second):
		t.Fatal("private event missing")
	}
	// A following valid presence frame bounds both negative assertions without sleeps.
	source.send(9, []byte(`{"type":"presence_update","data":{"user_id":42,"online_status":"hidden","last_seen_at":null,"server_id":"peer"},"timestamp":1}`))
	select {
	case raw := <-q9:
		var next struct{ Type string }
		if json.Unmarshal(raw, &next) != nil || next.Type != "presence_update" {
			t.Fatal("private event crossed users", string(raw))
		}
	case <-time.After(2 * time.Second):
		t.Fatal("peer sentinel missing")
	}
	select {
	case raw := <-q42:
		t.Fatal("unexpected broker status", string(raw))
	default:
	}
}

func TestLocalPresenceStopCloseAndBackpressure(t *testing.T) {
	hub := newLocalTestHub(t, nil, nil)
	q, stop, err := hub.Subscribe(context.Background(), 42)
	if err != nil {
		t.Fatal(err)
	}
	stop()
	stop()
	for range q {
	}
	q, stop, err = hub.Subscribe(context.Background(), 42)
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	for i := 0; i < 128; i++ {
		_ = hub.PublishPresence(context.Background(), userPresence{UserID: 42, OnlineStatus: "online"})
	}
	deadline := time.After(2 * time.Second)
	drained := false
	for !drained {
		select {
		case _, ok := <-q:
			drained = !ok
		case <-deadline:
			t.Fatal("slow subscriber remained open")
		}
	}
	if err := hub.Close(); err != nil {
		t.Fatal(err)
	}
	if _, _, err := hub.Subscribe(context.Background(), 42); err == nil {
		t.Fatal("closed hub subscribed")
	}
}
