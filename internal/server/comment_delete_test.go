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

type commentDeleteFixture struct {
	*memorySessions
	result     commentDeleteResult
	fail       bool
	viewer, id int64
}

func (s *commentDeleteFixture) DeletePostComment(_ context.Context, viewer, id int64) (commentDeleteResult, error) {
	s.viewer, s.id = viewer, id
	if s.fail {
		return commentMissing, errors.New("private database error")
	}
	return s.result, nil
}
func TestCommentDeleteRoute(t *testing.T) {
	codec, tokens := fixture(t)
	s := &commentDeleteFixture{memorySessions: store(), result: commentDeleted}
	handler := NewHandler(codec, s, CorsPolicy{})
	request := func(path, token string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("DELETE", path, nil)
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	if w := request("/api/v2/comments/1", ""); w.Code != 401 {
		t.Fatal(w.Code)
	}
	if w := request("/api/v2/comments/01", tokens["access-hs256"]); w.Code != 400 {
		t.Fatal(w.Code)
	}
	for _, tc := range []struct {
		result commentDeleteResult
		status int
	}{{commentMissing, 404}, {commentNotOwner, 422}, {commentDeleted, 200}} {
		s.result = tc.result
		w := request("/api/v2/comments/1", tokens["access-hs256"])
		if w.Code != tc.status || w.Header().Get("Cache-Control") != "private, no-store" || s.viewer != 42 || s.id != 1 {
			t.Fatalf("%d %s", w.Code, w.Body.String())
		}
		if tc.status == 200 && !strings.Contains(w.Body.String(), `"message":"comment deleted"`) {
			t.Fatal(w.Body.String())
		}
	}
	s.fail = true
	w := request("/api/v2/comments/1", tokens["access-hs256"])
	if w.Code != 500 || strings.Contains(w.Body.String(), "private database error") {
		t.Fatal(w.Body.String())
	}
}

type deleteCommentState struct {
	driverState
	missing, nonOwner, race bool
	queries, writes         []listQueryCall
}
type deleteCommentConnector struct{ s *deleteCommentState }
type deleteCommentConn struct {
	*testConn
	s *deleteCommentState
}

func (c deleteCommentConnector) Connect(context.Context) (driver.Conn, error) {
	return &deleteCommentConn{&testConn{&c.s.driverState}, c.s}, nil
}
func (c deleteCommentConnector) Driver() driver.Driver { return testDriver{} }
func (c *deleteCommentConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.s.queries = append(c.s.queries, listQueryCall{q, append([]driver.NamedValue(nil), args...)})
	if c.s.missing {
		return emptyRows{&c.s.driverState}, nil
	}
	id := int64(42)
	if c.s.nonOwner {
		id = 7
	}
	return &alertRows{values: []driver.Value{id}}, nil
}
func (c *deleteCommentConn) ExecContext(_ context.Context, q string, args []driver.NamedValue) (driver.Result, error) {
	c.s.writes = append(c.s.writes, listQueryCall{q, append([]driver.NamedValue(nil), args...)})
	if c.s.race {
		return driver.RowsAffected(0), nil
	}
	return driver.RowsAffected(1), nil
}
func TestCommentDeleteRepositoryScopesBothReadAndWrite(t *testing.T) {
	for _, tc := range []struct {
		name   string
		s      deleteCommentState
		want   commentDeleteResult
		writes int
	}{{"missing", deleteCommentState{missing: true}, commentMissing, 0}, {"other", deleteCommentState{nonOwner: true}, commentNotOwner, 0}, {"race", deleteCommentState{race: true}, commentMissing, 1}, {"success", deleteCommentState{}, commentDeleted, 1}} {
		t.Run(tc.name, func(t *testing.T) {
			db := sql.OpenDB(deleteCommentConnector{&tc.s})
			defer db.Close()
			result, err := (OracleSessions{db}).DeletePostComment(context.Background(), 42, 20)
			if err != nil || result != tc.want || len(tc.s.writes) != tc.writes {
				t.Fatalf("%v %v %v", result, err, tc.s.writes)
			}
			q := tc.s.queries[0]
			for _, part := range []string{"c.is_deleted=0", "p.is_deleted=0", "fn_can_view_post(:viewer_id,c.post_id)=1"} {
				if !strings.Contains(q.sql, part) {
					t.Fatal(q.sql)
				}
			}
			if tc.writes > 0 {
				q := tc.s.writes[0]
				for _, part := range []string{"c.user_id=:user_id", "c.is_deleted=0", "p.is_deleted=0", "fn_can_view_post(:user_id,c.post_id)=1"} {
					if !strings.Contains(q.sql, part) {
						t.Fatal(q.sql)
					}
				}
				binds := map[string]any{}
				for _, a := range q.args {
					binds[a.Name] = a.Value
				}
				if binds["user_id"] != int64(42) || binds["comment_id"] != int64(20) {
					t.Fatal(binds)
				}
			}
		})
	}
}
