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

type chatGroupFixture struct{ *memorySessions }

func (*chatGroupFixture) ListChatGroups(_ context.Context, viewer int64, page SessionPage) ([]chatGroup, int64, error) {
	if viewer != 42 || page.Start != 3 || page.End != 4 {
		return nil, 0, errSessionStore
	}
	return []chatGroup{{ID: 7, ChannelCount: 0, Membership: chatGroupMembership{IsMember: true, Role: "member", Status: "muted"}}}, 5, nil
}

func TestChatGroupListRoute(t *testing.T) {
	codec, tokens := fixture(t)
	app := NewHandler(codec, &chatGroupFixture{store()}, CorsPolicy{})
	for _, authenticated := range []bool{false, true} {
		request := httptest.NewRequest("GET", "/api/v2/chat/groups?page=2&page_size=2&user_id=9", nil)
		if authenticated {
			request.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		}
		recorder := httptest.NewRecorder()
		app.ServeHTTP(recorder, request)
		if recorder.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatal("missing private cache policy")
		}
		if authenticated {
			if recorder.Code != 200 || !strings.Contains(recorder.Body.String(), `"has_next":true`) ||
				!strings.Contains(recorder.Body.String(), `"channel_count":0`) {
				t.Fatal(recorder.Code, recorder.Body)
			}
		} else if recorder.Code != 401 {
			t.Fatal(recorder.Code, recorder.Body)
		}
	}
}

type chatGroupConnector struct{ state driverState }
type chatGroupConn struct{ *testConn }

func (*chatGroupConnector) Driver() driver.Driver { return testDriver{} }
func (c *chatGroupConnector) Connect(context.Context) (driver.Conn, error) {
	return &chatGroupConn{&testConn{&c.state}}, nil
}
func (*chatGroupConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	if len(args) == 0 || args[0].Value != int64(42) {
		return nil, errors.New("wrong viewer")
	}
	switch query {
	case chatGroupListSQL:
		if len(args) != 3 || strings.Count(query, "c.is_private=0 OR r.role") != 2 {
			return nil, errors.New("incorrect page or visibility policy")
		}
		switch {
		case args[1].Value == float64(3) && args[2].Value == float64(4):
			return &alertRows{values: []driver.Value{int64(7), "群", nil, int64(10), "member", "muted", nil, int64(0), int64(0), int64(0), int64(5)}}, nil
		case args[1].Value == float64(7) && args[2].Value == float64(8):
			return &alertRows{values: []driver.Value{nil, nil, nil, nil, nil, nil, nil, int64(0), int64(0), int64(0), int64(5)}}, nil
		default:
			return nil, errors.New("incorrect page")
		}
	default:
		return nil, errors.New("unexpected query")
	}
}

func TestChatGroupListRepository(t *testing.T) {
	db := sql.OpenDB(&chatGroupConnector{})
	defer db.Close()
	got, total, err := (OracleSessions{DB: db}).ListChatGroups(context.Background(), 42, SessionPage{Page: 2, PageSize: 2, Start: 3, End: 4})
	if err != nil || total != 5 || len(got) != 1 || got[0].Membership.Status != "muted" || !got[0].Membership.IsMember || got[0].Membership.CanManage || got[0].AvatarURL != nil {
		t.Fatal(got, total, err)
	}
	got, total, err = (OracleSessions{DB: db}).ListChatGroups(context.Background(), 42, SessionPage{Page: 4, PageSize: 2, Start: 7, End: 8})
	if err != nil || total != 5 || len(got) != 0 {
		t.Fatal(got, total, err)
	}
}
