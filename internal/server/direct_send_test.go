package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type directSendFixture struct {
	*memorySessions
	saved bool
	err   error
}

func (f *directSendFixture) SendDirectMessage(_ context.Context, sender, conversation int64, content string, _ StorageURLPolicy) (directSendResult, error) {
	if sender != 42 || conversation != 7 || content != "hello" {
		return directSendResult{}, errors.New("incorrect input")
	}
	if f.err != nil {
		return directSendResult{}, f.err
	}
	f.saved = true
	return directSendResult{
		target: 9, message: DirectMessage{ID: 11, ConversationID: 7, Content: content},
		read: directReadAdvance{9, 11},
	}, nil
}

func (*directSendFixture) NotificationByID(context.Context, int64, int64) (NotificationItem, bool, error) {
	return NotificationItem{}, false, errors.New("unexpected notification lookup")
}

type directPublisherFunc func(context.Context, int64, int64, DirectMessage) error

func (p directPublisherFunc) PublishDirect(ctx context.Context, sender, recipient int64, message DirectMessage) error {
	return p(ctx, sender, recipient, message)
}

func TestDirectSendPublishesOnlyAfterStorageSucceeds(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		err    error
		status int
	}{{errDirectStrangers, 403}, {errDirectBlocked, 403}, {errDirectRecipientMissing, 404}, {errSessionStore, 500}, {nil, 200}} {
		f := &directSendFixture{memorySessions: store(), err: tc.err}
		published, read := false, false
		publisher := directReadTestPublisher{
			directPublisherFunc: func(_ context.Context, sender, recipient int64, message DirectMessage) error {
				if !f.saved || sender != 42 || recipient != 9 || message.ID != 11 {
					t.Fatal("publish did not use committed result")
				}
				published = true
				return errNotificationEvent
			},
			read: func(reader, peer, conversation, message int64) {
				if !f.saved || reader != 42 || peer != 9 || conversation != 7 || message != 11 {
					t.Fatal("read publication did not use the committed sender cursor")
				}
				read = true
			},
		}
		app := NewHandlerWithConfig(codec, f, CorsPolicy{}, RefreshConfig{DirectEvents: publisher})
		r := httptest.NewRequest("POST", "/api/v2/chat/direct-conversations/7/messages", strings.NewReader(`{"content":" hello "}`))
		r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		w := httptest.NewRecorder()
		app.ServeHTTP(w, r)
		if w.Code != tc.status || published != (tc.err == nil) || read != (tc.err == nil) {
			t.Fatalf("status=%d published=%t read=%t body=%s", w.Code, published, read, w.Body)
		}
	}
}

func TestDirectSendLocalDeliveryIsScopedToParticipants(t *testing.T) {
	hub, err := NewLocalPresenceEvents(nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer hub.Close()
	ctx := context.Background()
	subscribe := func(user int64) <-chan []byte {
		q, _, err := hub.Subscribe(ctx, user)
		if err != nil {
			t.Fatal(err)
		}
		readRemoteStatus(t, q, "unavailable")
		return q
	}
	sender, recipient, outsider := subscribe(42), subscribe(9), subscribe(7)
	_ = hub.PublishDirect(ctx, 42, 9, DirectMessage{ID: 11, ConversationID: 7, Content: "hello"})
	for _, q := range []<-chan []byte{sender, recipient} {
		readLocalKind(t, q, "direct_message")
	}
	select {
	case <-outsider:
		t.Fatal("private message reached another user's connection")
	case <-time.After(30 * time.Millisecond):
	}
}

func TestDirectSendSuppressesOnlyMatchingLocalEcho(t *testing.T) {
	source := &localTestSource{}
	redis := &eventFake{}
	hub, err := NewLocalPresenceEvents(source, &UserEventPublisher{client: redis, clock: time.Now, serverID: "fixture"})
	if err != nil {
		t.Fatal(err)
	}
	defer hub.Close()
	ctx := context.Background()
	events, _, err := hub.Subscribe(ctx, 42)
	if err != nil {
		t.Fatal(err)
	}
	readRemoteStatus(t, events, "connected")
	if err := hub.PublishDirect(ctx, 42, 9, DirectMessage{ID: 11, ConversationID: 7, Content: "hello"}); err != nil {
		t.Fatal(err)
	}
	readLocalKind(t, events, "direct_message")
	if redis.calls != 2 || redis.channel != "ws:user:9" {
		t.Fatal("expected two participant publications")
	}
	source.send(42, redis.payload)
	source.send(42, []byte(`{"type":"direct_message","data":{"conversation_id":7,"direct_message":{"conversation_id":7,"message_id":12},"server_id":"fixture"},"timestamp":1}`))
	event := readLocalKind(t, events, "direct_message")
	message := event["data"].(map[string]any)["direct_message"].(map[string]any)
	if message["message_id"] != float64(12) {
		t.Fatal("matching echo was delivered or unmatched message was lost")
	}
}

type directSendConnector struct {
	state          driverState
	failAt, writes int
	accountMuted   bool
}

type directSendConn struct {
	*testConn
	fixture *directSendConnector
}

func (*directSendConnector) Driver() driver.Driver { return testDriver{} }
func (c *directSendConnector) Connect(context.Context) (driver.Conn, error) {
	return &directSendConn{&testConn{&c.state}, c}, nil
}

func (c *directSendConn) QueryContext(_ context.Context, query string, _ []driver.NamedValue) (driver.Rows, error) {
	var values []driver.Value
	switch query {
	case publishPolicy.SQL["lock"]:
		values = []driver.Value{int64(42)}
	case publishPolicy.SQL["allowed"]:
		allowed := int64(1)
		if c.fixture.accountMuted {
			allowed = 0
		}
		values = []driver.Value{allowed}
	case directSendAccessSQL:
		values = []driver.Value{int64(9)}
	case directRecipientSQL:
		values = []driver.Value{int64(0), "mutual_follow", int64(0)}
	case `SELECT seq_direct_message_id.NEXTVAL FROM dual`:
		values = []driver.Value{int64(11)}
	case directMessageByIDSQL:
		at := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
		values = []driver.Value{int64(11), int64(7), int64(42), "hello", int64(0), at, at, nil, nil,
			"author", nil, nil, nil, nil, nil, int64(0), int64(0), int64(0), int64(0), int64(0), "self"}
	case notificationDeliverySQL:
		values = []driver.Value{int64(1), int64(1)}
	case `SELECT seq_notification_id.NEXTVAL FROM dual`:
		values = []driver.Value{int64(12)}
	default:
		return nil, errors.New("unexpected query")
	}
	return &alertRows{values: values}, nil
}

func (c *directSendConn) ExecContext(_ context.Context, _ string, _ []driver.NamedValue) (driver.Result, error) {
	c.fixture.writes++
	if c.fixture.writes == c.fixture.failAt {
		return nil, errors.New("synthetic write failure")
	}
	return driver.RowsAffected(1), nil
}

func TestDirectSendTransactionRollsBackEachFailedWrite(t *testing.T) {
	for failure := -1; failure <= 4; failure++ {
		f := &directSendConnector{failAt: failure, accountMuted: failure < 0}
		db := sql.OpenDB(f)
		result, err := (OracleSessions{DB: db}).SendDirectMessage(context.Background(), 42, 7, "hello", StorageURLPolicy{})
		db.Close()
		if failure < 0 {
			if !errors.Is(err, errPublishForbidden) || f.writes != 0 || f.state.commits != 0 || f.state.rollbacks != 1 {
				t.Fatalf("muted send wrote or failed to roll back: err=%v writes=%d state=%+v", err, f.writes, f.state)
			}
		} else if failure == 0 {
			if err != nil || f.writes != 4 || f.state.commits != 1 || result.notice == nil || result.notice.ID != 12 ||
				result.message.ID != 11 || result.read != (directReadAdvance{9, 11}) {
				t.Fatalf("transaction did not return committed result: %+v %v", result, err)
			}
		} else if err == nil || f.state.commits != 0 || f.state.rollbacks != 1 || result.message.ID != 0 || result.read.message != 0 {
			t.Fatalf("write %d failure escaped rollback", failure)
		}
	}
}
