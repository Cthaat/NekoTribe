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
	"time"
)

type directHistoryFixture struct {
	*memorySessions
	user, conversation int64
	page               SessionPage
	failure            error
}

func (f *directHistoryFixture) ListDirectMessages(_ context.Context, user, conversation int64, page SessionPage) ([]DirectMessage, int64, error) {
	f.user, f.conversation, f.page = user, conversation, page
	return nil, 5, f.failure
}

func TestDirectHistoryHTTP(t *testing.T) {
	codec, tokens := fixture(t)
	repository := &directHistoryFixture{memorySessions: store()}
	handler := NewHandler(codec, repository, CorsPolicy{})
	for _, tc := range []struct {
		id    string
		token string
		store error
		want  int
	}{
		{"7", "", nil, 401},
		{"9007199254740992", tokens["access-hs256"], nil, 400},
		{"7", tokens["access-hs256"], errDirectConversationForbidden, 403},
		{"7", tokens["access-hs256"], errors.New("private fixture"), 500},
		{"7", tokens["access-hs256"], nil, 200},
	} {
		repository.failure = tc.store
		r := httptest.NewRequest("GET", "/api/v2/chat/direct-conversations/"+tc.id+"/messages?page=2&page_size=2&user_id=9", nil)
		if tc.token != "" {
			r.Header.Set("Authorization", "Bearer "+tc.token)
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != tc.want || w.Header().Get("Cache-Control") != "private, no-store" || strings.Contains(w.Body.String(), "private fixture") {
			t.Fatalf("status=%d body=%s", w.Code, w.Body)
		}
		if tc.want == 200 {
			var envelope struct {
				Data []DirectMessage
				Meta struct {
					HasNext bool `json:"has_next"`
				}
			}
			if err := json.Unmarshal(w.Body.Bytes(), &envelope); err != nil || envelope.Data == nil || !envelope.Meta.HasNext {
				t.Fatal(w.Body.String())
			}
			if repository.user != 42 || repository.conversation != 7 || repository.page.Start != 3 || repository.page.End != 4 {
				t.Fatal("incorrect repository scope or pagination")
			}
		}
	}
}

type directHistoryConnector struct {
	state            driverState
	denied, failMark bool
	marked           int64
	reads            int
}

type directHistoryConn struct {
	*testConn
	fixture *directHistoryConnector
}

func (c *directHistoryConnector) Driver() driver.Driver { return testDriver{} }
func (c *directHistoryConnector) Connect(context.Context) (driver.Conn, error) {
	return &directHistoryConn{&testConn{&c.state}, c}, nil
}

func (c *directHistoryConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	c.fixture.reads++
	switch {
	case query == directHistoryAccessSQL:
		if args[0].Value != int64(7) || args[1].Value != int64(42) {
			return nil, errors.New("wrong participant binds")
		}
		if c.fixture.denied {
			return emptyRows{&c.fixture.state}, nil
		}
		return &alertRows{values: []driver.Value{int64(7)}}, nil
	case strings.HasPrefix(query, "SELECT COUNT"):
		return &alertRows{values: []driver.Value{int64(5)}}, nil
	case query == directHistoryPageSQL:
		at := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
		return &alertRows{values: []driver.Value{
			int64(11), int64(7), int64(42), "message", int64(0), at, at, nil, nil,
			"author", nil, nil, nil, nil, nil, int64(0), int64(0), int64(0), int64(0), int64(0), "self",
		}}, nil
	default:
		return nil, errors.New("unexpected query")
	}
}

func (c *directHistoryConn) ExecContext(_ context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	if c.fixture.failMark || query != markDirectReadSQL {
		return nil, errors.New("mark read failed")
	}
	if !strings.Contains(query, "GREATEST(NVL(r.last_read_message_id,0),src.message_id)") {
		return nil, errors.New("read marker must keep the higher cursor")
	}
	c.fixture.marked = args[2].Value.(int64)
	return driver.RowsAffected(1), nil
}

func TestDirectHistoryRepository(t *testing.T) {
	for _, tc := range []struct {
		page             string
		denied, failMark bool
	}{
		{"1", false, false},
		{"2", false, false},
		{"1", true, false},
		{"1", false, true},
	} {
		f := &directHistoryConnector{denied: tc.denied, failMark: tc.failMark}
		db := sql.OpenDB(f)
		messages, total, err := (OracleSessions{DB: db}).ListDirectMessages(context.Background(), 42, 7, sessionPagination(parseSessionQuery("page="+tc.page)))
		db.Close()
		switch {
		case tc.denied:
			if !errors.Is(err, errDirectConversationForbidden) || f.reads != 1 || f.state.rollbacks != 1 {
				t.Fatal("nonparticipant reached message history")
			}
		case tc.failMark:
			if err == nil || f.state.rollbacks != 1 || f.state.commits != 0 {
				t.Fatal("failed read marker did not roll back")
			}
		default:
			if err != nil || len(messages) != 1 || total != 5 || !messages[0].CanDelete ||
				messages[0].Author.UserID != 42 || !messages[0].Author.Relationship.IsSelf || f.state.commits != 1 {
				t.Fatal(messages, total, err)
			}
			if (tc.page == "1" && f.marked != 11) || (tc.page == "2" && f.marked != 0) {
				t.Fatal("incorrect first-page read marker", f.marked)
			}
		}
	}
}
