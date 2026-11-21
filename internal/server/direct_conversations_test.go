package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
)

type directPairConnector struct {
	state    driverState
	reads    int
	inserted bool
}
type directPairConn struct {
	*testConn
	fixture *directPairConnector
}

func (*directPairConnector) Driver() driver.Driver { return testDriver{} }
func (c *directPairConnector) Connect(context.Context) (driver.Conn, error) {
	return &directPairConn{&testConn{&c.state}, c}, nil
}
func (c *directPairConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	switch query {
	case directRecipientSQL:
		return &alertRows{values: []driver.Value{int64(1), "none", int64(0)}}, nil
	case directConversationPairSQL:
		if args[0].Value != int64(9) || args[1].Value != int64(42) {
			return nil, errors.New("pair must be sorted")
		}
		c.fixture.reads++
		if !c.fixture.inserted {
			return emptyRows{&c.fixture.state}, nil
		}
		return &alertRows{values: []driver.Value{int64(7), int64(0)}}, nil
	case `SELECT seq_direct_conversation_id.NEXTVAL FROM dual`:
		return &alertRows{values: []driver.Value{int64(8)}}, nil
	case directConversationProjection + directConversationFrom + " AND c.conversation_id=:conversation_id":
		if args[0].Value != int64(42) || args[1].Value != int64(7) {
			return nil, errors.New("expected winning conversation")
		}
		return &alertRows{values: []driver.Value{int64(7), nil, nil, int64(9), "peer", nil, nil, nil, nil, nil,
			nil, nil, nil, nil, nil, "none", nil, nil, nil, nil, int64(0)}}, nil
	default:
		return nil, errors.New("unexpected query")
	}
}
func (c *directPairConn) ExecContext(context.Context, string, []driver.NamedValue) (driver.Result, error) {
	c.fixture.inserted = true
	return nil, emailUniqueError{}
}

func TestDirectConversationCreateReusesConcurrentWinner(t *testing.T) {
	fixture := &directPairConnector{}
	db := sql.OpenDB(fixture)
	defer db.Close()
	got, err := (OracleSessions{DB: db}).CreateDirectConversation(context.Background(), 42, 9, StorageURLPolicy{})
	if err != nil || got.ID != 7 || got.Participant.UserID != 9 || got.LastMessage != nil || fixture.reads != 2 || fixture.state.commits != 1 {
		t.Fatalf("did not reuse winner: %+v %v", got, err)
	}
}

type directConversationFixture struct {
	*memorySessions
	calls int
}

func (f *directConversationFixture) ListDirectConversations(_ context.Context, viewer, conversation int64, page SessionPage) ([]directConversation, int64, error) {
	if viewer != 42 {
		return nil, 0, errSessionStore
	}
	if conversation == 7 && page.Start == 1 {
		return []directConversation{{ID: 7, Participant: PublicUser{UserID: 9}}}, 1, nil
	}
	if conversation != 0 {
		return nil, 0, nil
	}
	if page.Start != 3 {
		return nil, 0, errSessionStore
	}
	return []directConversation{{ID: 7, Participant: PublicUser{UserID: 9}, UnreadCount: 2}}, 6, nil
}

func (f *directConversationFixture) CreateDirectConversation(_ context.Context, viewer, target int64, _ StorageURLPolicy) (directConversation, error) {
	f.calls++
	if viewer != 42 {
		return directConversation{}, errSessionStore
	}
	switch target {
	case 9:
		return directConversation{ID: 7, Participant: PublicUser{UserID: 9}}, nil
	case 8:
		return directConversation{}, errDeletedDirectPair
	default:
		return directConversation{}, errDirectBlocked
	}
}

func TestDirectConversationsNativeRoutes(t *testing.T) {
	codec, tokens := fixture(t)
	store := &directConversationFixture{memorySessions: store()}
	handler := NewHandler(codec, store, CorsPolicy{})
	for _, tc := range []struct {
		method, query, body string
		auth                bool
		status              int
		expected            string
	}{
		{"GET", "", "", false, 401, "40101"},
		{"GET", "?page=2&page_size=2&user_id=99", "", true, 200, `"unread_count":2`},
		{"GET", "?conversation_id=%37&page_size=1", "", true, 200, `"conversation_id":7`},
		{"GET", "?conversation_id=99", "", true, 200, `"data":[]`},
		{"GET", "?conversation_id=07", "", true, 400, "conversation_id 参数错误"},
		{"GET", "?conversation_id=7&conversation_id=7", "", true, 400, "conversation_id 参数错误"},
		{"GET", "?conversation_id=9007199254740992", "", true, 400, "conversation_id 参数错误"},
		{"POST", "", `{"target_user_id":42}`, true, 400, "40001"},
		{"POST", "", `{"target_user_id":9007199254740992}`, true, 400, "40001"},
		{"POST", "", `{"target_user_id":9}`, true, 200, `"conversation_id":7`},
		{"POST", "", `{"target_user_id":9}`, true, 200, `"conversation_id":7`},
		{"POST", "", `{"target_user_id":8}`, true, 409, "40901"},
		{"POST", "", `{"target_user_id":7}`, true, 403, "40301"},
	} {
		r := httptest.NewRequest(tc.method, "/api/v2/chat/direct-conversations"+tc.query, strings.NewReader(tc.body))
		if tc.auth {
			r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != tc.status || !strings.Contains(w.Body.String(), tc.expected) || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatalf("%s %s returned %d %s", tc.method, tc.body, w.Code, w.Body)
		}
	}
	if store.calls != 4 {
		t.Fatalf("unexpected create calls: %d", store.calls)
	}
}
