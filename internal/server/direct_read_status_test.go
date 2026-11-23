package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
)

type directReadTestRepository struct {
	*memorySessions
	oracle OracleSessions
}

func (s directReadTestRepository) DirectReadStatus(ctx context.Context, actor, conversation int64) (directReadStatus, error) {
	return s.oracle.DirectReadStatus(ctx, actor, conversation)
}

func (s directReadTestRepository) AdvanceDirectRead(ctx context.Context, actor, conversation, message int64) (directReadStatus, directReadAdvance, error) {
	return s.oracle.AdvanceDirectRead(ctx, actor, conversation, message)
}

type directReadTestPublisher struct {
	directPublisherFunc
	read func(int64, int64, int64, int64)
}

func (p directReadTestPublisher) PublishDirectRead(_ context.Context, reader, peer, conversation, message int64) error {
	p.read(reader, peer, conversation, message)
	return nil
}

type directReadTestDatabase struct {
	cursor, pending int64
	commits         int
	failCommit      bool
}

func (*directReadTestDatabase) Driver() driver.Driver { return testDriver{} }

func (db *directReadTestDatabase) Connect(context.Context) (driver.Conn, error) {
	return &directReadTestConnection{&testConn{&driverState{}}, db}, nil
}

type directReadTestConnection struct {
	*testConn
	db *directReadTestDatabase
}

func (c *directReadTestConnection) Begin() (driver.Tx, error) {
	c.db.pending = c.db.cursor
	return c, nil
}

func (c *directReadTestConnection) Commit() error {
	if c.db.failCommit {
		c.db.pending = c.db.cursor
		return errors.New("synthetic failed commit")
	}
	c.db.cursor = c.db.pending
	c.db.commits++
	return nil
}

func (c *directReadTestConnection) Rollback() error {
	c.db.pending = c.db.cursor
	return nil
}

func (c *directReadTestConnection) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	bind := func(name string) driver.Value { return directFixtureBind(args, name) }
	if bind("conversation_id") != int64(7) {
		return emptyRows{c.testConn.state}, nil
	}
	switch query {
	case directSendAccessSQL:
		if bind("user_id") == int64(42) {
			return &alertRows{values: []driver.Value{int64(9)}}, nil
		}
	case directExtrasContract.SQL["query_message"]:
		if id := bind("message_id"); id == int64(10) || id == int64(11) || id == int64(12) {
			return &alertRows{values: []driver.Value{id}}, nil
		}
	case chatRealtimeDetails.SQL["read_status"]:
		if bind("user_id") == int64(42) {
			var cursor driver.Value
			unread := int64(3)
			if c.db.pending != 0 {
				cursor = c.db.pending
				unread = 12 - c.db.pending
			}
			return &alertRows{values: []driver.Value{int64(7), cursor, nil, unread}}, nil
		}
	default:
		return nil, errors.New("unexpected read status query")
	}
	return emptyRows{c.testConn.state}, nil
}

func (c *directReadTestConnection) ExecContext(_ context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	if query != markDirectReadSQL || directFixtureBind(args, "conversation_id") != int64(7) ||
		directFixtureBind(args, "user_id") != int64(42) {
		return nil, errors.New("unscoped cursor write")
	}
	cursor, ok := directFixtureBind(args, "last_read_message_id").(int64)
	if !ok {
		return nil, errors.New("missing cursor bind")
	}
	if cursor <= c.db.pending {
		return driver.RowsAffected(0), nil
	}
	c.db.pending = cursor
	return driver.RowsAffected(1), nil
}

func TestDirectReadStatusHTTPAndCommitOnlyAdvances(t *testing.T) {
	codec, tokens := fixture(t)
	fixture := &directReadTestDatabase{}
	db := sql.OpenDB(fixture)
	defer db.Close()
	published := 0
	publisher := directReadTestPublisher{read: func(reader, peer, conversation, message int64) {
		if reader != 42 || peer != 9 || conversation != 7 || message != fixture.cursor || fixture.commits == 0 {
			t.Error("read event was not scoped to the committed cursor")
		}
		published++
	}}
	repo := directReadTestRepository{memorySessions: store(), oracle: OracleSessions{DB: db}}
	app := NewHandlerWithConfig(codec, repo, CorsPolicy{}, RefreshConfig{DirectEvents: publisher})
	for _, tc := range []struct {
		method, id, body string
		code, published  int
		cursor, unread   int64
		failCommit       bool
	}{
		{"GET", "7", "", 200, 0, 0, 3, false},
		{"GET", "8", "", 403, 0, 0, 0, false},
		{"PUT", "8", `{"last_read_message_id":11}`, 403, 0, 0, 0, false},
		{"PUT", "7", `{"last_read_message_id":"11"}`, 400, 0, 0, 0, false},
		{"PUT", "7", `{"last_read_message_id":99}`, 400, 0, 0, 0, false},
		{"PUT", "7", `{"last_read_message_id":11}`, 200, 1, 11, 1, false},
		{"PUT", "7", `{"last_read_message_id":11}`, 200, 1, 11, 1, false},
		{"PUT", "7", `{"last_read_message_id":10}`, 200, 1, 11, 1, false},
		{"PUT", "7", `{"last_read_message_id":12}`, 500, 1, 11, 0, true},
		{"GET", "7", "", 200, 1, 11, 1, false},
	} {
		fixture.failCommit = tc.failCommit
		req := httptest.NewRequest(tc.method, "/api/v2/chat/direct-conversations/"+tc.id+"/read-status", strings.NewReader(tc.body))
		req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		w := httptest.NewRecorder()
		app.ServeHTTP(w, req)
		if w.Code != tc.code || w.Header().Get("Cache-Control") != "private, no-store" ||
			published != tc.published || fixture.cursor != tc.cursor {
			t.Fatalf("%s %s %s: response=%d %s published=%d cursor=%d", tc.method, tc.id, tc.body, w.Code, w.Body, published, fixture.cursor)
		}
		if tc.code == 200 {
			var response struct{ Data directReadStatus }
			if json.Unmarshal(w.Body.Bytes(), &response) != nil || response.Data.ConversationID != 7 ||
				response.Data.ParticipantLastReadMessageID != nil || response.Data.UnreadCount != tc.unread ||
				(tc.cursor == 0 && response.Data.LastReadMessageID != nil) ||
				(tc.cursor != 0 && (response.Data.LastReadMessageID == nil || *response.Data.LastReadMessageID != tc.cursor)) {
				t.Fatal(w.Body.String())
			}
		}
	}
}
