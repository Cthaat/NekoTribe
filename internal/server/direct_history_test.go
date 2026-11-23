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
	markRead           bool
}

func (f *directHistoryFixture) ListDirectMessages(_ context.Context, user, conversation int64, page SessionPage, markRead bool, _ chatMessageSearch) ([]DirectMessage, int64, directReadAdvance, error) {
	f.user, f.conversation, f.page = user, conversation, page
	f.markRead = markRead
	return nil, 5, directReadAdvance{}, f.failure
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
	for _, tc := range []struct {
		query string
		code  int
		mark  bool
	}{
		{"", 200, true}, {"?mark_read=false", 200, false}, {"?mark_read=true", 200, true},
		{"?mark_read=no", 400, false}, {"?mark_read=false&mark_read=true", 400, false},
	} {
		r := httptest.NewRequest("GET", "/api/v2/chat/direct-conversations/7/messages"+tc.query, nil)
		r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != tc.code || (tc.code == 200 && repository.markRead != tc.mark) {
			t.Fatal(tc.query, w.Code, repository.markRead)
		}
	}
}

type directHistoryConnector struct {
	state            driverState
	denied, failMark bool
	marked           int64
	reads            int
	historyQueries   []listQueryCall
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
	case query == directSendAccessSQL:
		if args[0].Value != int64(42) || args[1].Value != int64(7) {
			return nil, errors.New("wrong participant binds")
		}
		if c.fixture.denied {
			return emptyRows{&c.fixture.state}, nil
		}
		return &alertRows{values: []driver.Value{int64(9)}}, nil
	case strings.HasPrefix(query, directHistoryCountSQL):
		c.fixture.historyQueries = append(c.fixture.historyQueries, listQueryCall{query, args})
		return &alertRows{values: []driver.Value{int64(5)}}, nil
	case strings.HasPrefix(query, directHistoryPageSQL):
		c.fixture.historyQueries = append(c.fixture.historyQueries, listQueryCall{query, args})
		at := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
		return &alertRows{values: []driver.Value{
			int64(11), int64(7), int64(42), "message", int64(0), at, at, nil, nil,
			"author", nil, nil, nil, nil, nil, int64(0), int64(0), int64(0), int64(0), int64(0), "self",
		}}, nil
	case query == directExtrasContract.SQL["list_media"]:
		return nil, errors.New("ORA-00942: relation absent")
	case query == schemaOwnerSQL:
		return &schemaFixtureRows{columns: []string{"USER_NAME", "SCHEMA_NAME"}, values: [][]driver.Value{{"fixture", "fixture"}}}, nil
	case query == directExtrasContract.SQL["any_extras_table_present"]:
		return emptyRows{&c.fixture.state}, nil
	default:
		return nil, errors.New("unexpected query")
	}
}

func (c *directHistoryConn) ExecContext(_ context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	if c.fixture.failMark || query != markDirectReadSQL {
		return nil, errors.New("mark read failed")
	}
	if !strings.Contains(query, "WHERE NVL(r.last_read_message_id,0)<s.last_read_message_id") {
		return nil, errors.New("read marker must keep the higher cursor")
	}
	c.fixture.marked = args[2].Value.(int64)
	return driver.RowsAffected(1), nil
}

func TestDirectHistoryRepository(t *testing.T) {
	for _, tc := range []struct {
		page             string
		mark             bool
		denied, failMark bool
	}{
		{"1", true, false, false},
		{"1", false, false, false},
		{"2", true, false, false},
		{"1", true, true, false},
		{"1", true, false, true},
	} {
		f := &directHistoryConnector{denied: tc.denied, failMark: tc.failMark}
		db := sql.OpenDB(f)
		messages, total, advance, err := (OracleSessions{DB: db}).ListDirectMessages(context.Background(), 42, 7, sessionPagination(parseSessionQuery("page="+tc.page)), tc.mark, chatMessageSearch{})
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
			want := directReadAdvance{}
			if tc.page == "1" && tc.mark {
				want = directReadAdvance{9, 11}
			}
			if f.marked != want.message || advance != want {
				t.Fatal("incorrect first-page read marker", f.marked)
			}
		}
	}
}
