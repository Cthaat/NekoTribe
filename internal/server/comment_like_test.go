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

type commentLikeFixture struct {
	*memorySessions
	count             float64
	inserted, visible bool
	failure           bool
	viewer, id        int64
	liked             bool
	notices           int
}

func (s *commentLikeFixture) SetCommentLike(_ context.Context, viewer, id int64, liked bool) (float64, bool, bool, error) {
	s.viewer, s.id, s.liked = viewer, id, liked
	if s.failure {
		return 0, false, false, errors.New("private failure")
	}
	return s.count, s.inserted, s.visible, nil
}
func (s *commentLikeFixture) PrepareCommentLikeNotification(_ context.Context, _, _ int64) (int64, *notificationStored, error) {
	s.notices++
	return 0, nil, nil
}
func (s *commentLikeFixture) NotificationByID(_ context.Context, _, _ int64) (NotificationItem, bool, error) {
	return NotificationItem{}, false, nil
}
func TestCommentLikeRoute(t *testing.T) {
	codec, tokens := fixture(t)
	s := &commentLikeFixture{memorySessions: store(), count: 3, visible: true, inserted: true}
	h := NewHandler(codec, s, CorsPolicy{})
	req := func(method, path, token string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, nil)
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	if w := req("POST", "/api/v2/comments/1/likes", ""); w.Code != 401 {
		t.Fatal(w.Code)
	}
	if w := req("POST", "/api/v2/comments/01/likes", tokens["access-hs256"]); w.Code != 400 {
		t.Fatal(w.Code)
	}
	s.visible = false
	if w := req("POST", "/api/v2/comments/1/likes", tokens["access-hs256"]); w.Code != 404 {
		t.Fatal(w.Code)
	}
	s.visible = true
	for _, method := range []string{"POST", "POST", "DELETE"} {
		if method == "POST" && s.notices > 0 {
			s.inserted = false
		}
		w := req(method, "/api/v2/comments/1/likes", tokens["access-hs256"])
		if w.Code != 200 || w.Header().Get("Cache-Control") != "private, no-store" || s.viewer != 42 || s.id != 1 || s.liked != (method == "POST") {
			t.Fatal(w.Code, w.Body.String())
		}
		if !strings.Contains(w.Body.String(), `"likes_count":3`) {
			t.Fatal(w.Body.String())
		}
	}
	if s.notices != 1 {
		t.Fatal(s.notices)
	}
	s.failure = true
	if w := req("DELETE", "/api/v2/comments/1/likes", tokens["access-hs256"]); w.Code != 500 || strings.Contains(w.Body.String(), "private failure") {
		t.Fatal(w.Code, w.Body.String())
	}
}

type likeCommentState struct {
	driverState
	hidden, race, missingCount bool
	affected                   int64
	checks                     int
	calls                      []listQueryCall
}
type likeCommentConnector struct{ s *likeCommentState }
type likeCommentConn struct {
	*testConn
	s *likeCommentState
}

func (c likeCommentConnector) Connect(context.Context) (driver.Conn, error) {
	return &likeCommentConn{&testConn{&c.s.driverState}, c.s}, nil
}
func (c likeCommentConnector) Driver() driver.Driver { return testDriver{} }
func (c *likeCommentConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.s.calls = append(c.s.calls, listQueryCall{q, append([]driver.NamedValue(nil), args...)})
	c.s.checks++
	if c.s.hidden || (c.s.race && c.s.checks > 1) || c.s.missingCount && strings.Contains(q, "likes_count") {
		return emptyRows{&c.s.driverState}, nil
	}
	if strings.Contains(q, "likes_count") {
		return &alertRows{values: []driver.Value{int64(3)}}, nil
	}
	return &alertRows{values: []driver.Value{int64(20)}}, nil
}
func (c *likeCommentConn) ExecContext(_ context.Context, q string, args []driver.NamedValue) (driver.Result, error) {
	c.s.calls = append(c.s.calls, listQueryCall{q, append([]driver.NamedValue(nil), args...)})
	return driver.RowsAffected(c.s.affected), nil
}
func TestCommentLikeRepository(t *testing.T) {
	for _, tc := range []struct {
		name                    string
		s                       likeCommentState
		like, visible, inserted bool
		count                   float64
		writes                  int
	}{{"hidden", likeCommentState{hidden: true}, true, false, false, 0, 0}, {"race", likeCommentState{race: true}, true, false, false, 0, 1}, {"count hidden", likeCommentState{affected: 1, missingCount: true}, true, false, false, 0, 1}, {"new", likeCommentState{affected: 1}, true, true, true, 3, 1}, {"duplicate", likeCommentState{}, true, true, false, 3, 1}, {"unlike", likeCommentState{affected: 1}, false, true, false, 3, 1}, {"unlike missing", likeCommentState{}, false, true, false, 3, 1}} {
		t.Run(tc.name, func(t *testing.T) {
			db := sql.OpenDB(likeCommentConnector{&tc.s})
			defer db.Close()
			count, inserted, visible, err := (OracleSessions{db}).SetCommentLike(context.Background(), 42, 20, tc.like)
			if err != nil || count != tc.count || inserted != tc.inserted || visible != tc.visible {
				t.Fatal(count, inserted, visible, err)
			}
			writes := 0
			for _, call := range tc.s.calls {
				assertCommentLikeScope(t, call.sql)
				if strings.HasPrefix(call.sql, "INSERT") || strings.HasPrefix(call.sql, "DELETE") {
					writes++
				}
				m := map[string]any{}
				for _, a := range call.args {
					m[a.Name] = a.Value
				}
				if m["viewer_id"] != int64(42) || m["comment_id"] != int64(20) {
					t.Fatal(m)
				}
			}
			if writes != tc.writes {
				t.Fatal(writes)
			}
		})
	}
}

func assertCommentLikeScope(t *testing.T, query string) {
	t.Helper()
	for _, part := range []string{
		"c.is_deleted=0", "p.is_deleted=0", "fn_can_view_post(:viewer_id,c.post_id)=1",
		"post_author.is_active=1", "comment_author.is_active=1",
		"b.user_id=:viewer_id AND b.target_user_id=c.user_id",
		"b.target_user_id=:viewer_id AND b.user_id=c.user_id",
	} {
		if !strings.Contains(query, part) {
			t.Fatalf("missing %q in %s", part, query)
		}
	}
}
