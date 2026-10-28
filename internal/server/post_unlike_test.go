package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
)

type unlikeFixture struct {
	*memorySessions
	viewer, post int64
	calls        int
}

func (s *unlikeFixture) RemovePostLike(_ context.Context, viewer, post int64) (float64, bool, error) {
	s.viewer, s.post, s.calls = viewer, post, s.calls+1
	return 3, post == 1, nil
}
func TestUnlikeRouteAuthenticatesAndReturnsCount(t *testing.T) {
	codec, tokens := fixture(t)
	s := &unlikeFixture{memorySessions: store()}
	h := NewHandler(codec, s, CorsPolicy{})
	for _, tc := range []struct {
		path, token string
		status      int
	}{
		{"/api/v2/posts/1/likes", "", 401},
		{"/api/v2/posts/01/likes", tokens["access-hs256"], 400},
		{"/api/v2/posts/2/likes", tokens["access-hs256"], 404},
		{"/api/v2/posts/1/likes?user_id=99", tokens["access-hs256"], 200},
		{"/api/v2/posts/1/likes", tokens["access-hs256"], 200},
	} {
		r := httptest.NewRequest("DELETE", tc.path, nil)
		if tc.token != "" {
			r.Header.Set("Authorization", "Bearer "+tc.token)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != tc.status {
			t.Fatalf("%s: %d %s", tc.path, w.Code, w.Body.String())
		}
		if tc.status == 200 {
			var out struct {
				Data struct {
					PostID int64   `json:"post_id"`
					Liked  bool    `json:"is_liked"`
					Count  float64 `json:"likes_count"`
				} `json:"data"`
			}
			if json.Unmarshal(w.Body.Bytes(), &out) != nil || out.Data.PostID != 1 || out.Data.Liked || out.Data.Count != 3 || s.viewer != 42 {
				t.Fatal(w.Body.String())
			}
		}
	}
	if s.calls != 3 {
		t.Fatal("unexpected store calls", s.calls)
	}
}

type unlikeState struct {
	driverState
	visibility   []bool
	queries      int
	affected     int64
	countMissing bool
	write        string
	args         []driver.NamedValue
}
type unlikeConnector struct{ state *unlikeState }
type unlikeConn struct {
	*testConn
	state *unlikeState
}

func (c unlikeConnector) Connect(context.Context) (driver.Conn, error) {
	return &unlikeConn{&testConn{&c.state.driverState}, c.state}, nil
}
func (c unlikeConnector) Driver() driver.Driver { return testDriver{} }
func (c *unlikeConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	if strings.Contains(q, "n_post_stats") {
		if c.state.countMissing {
			return emptyRows{&c.state.driverState}, nil
		}
		return &alertRows{values: []driver.Value{int64(3)}}, nil
	}
	index := c.state.queries
	c.state.queries++
	if index >= len(c.state.visibility) || !c.state.visibility[index] {
		return emptyRows{&c.state.driverState}, nil
	}
	return &alertRows{values: []driver.Value{int64(1)}}, nil
}
func (c *unlikeConn) ExecContext(_ context.Context, q string, args []driver.NamedValue) (driver.Result, error) {
	c.state.write = q
	c.state.args = args
	return driver.RowsAffected(c.state.affected), nil
}
func TestUnlikeRepositoryVisibilityAndCounts(t *testing.T) {
	for _, tc := range []struct {
		name             string
		visibility       []bool
		affected         int64
		missing, visible bool
		count            float64
	}{
		{"deleted", []bool{true}, 1, false, true, 3},
		{"already absent", []bool{true, true}, 0, false, true, 3},
		{"no stats", []bool{true, true}, 0, true, true, 0},
		{"visibility lost", []bool{true, false}, 0, false, false, 0},
		{"hidden", []bool{false}, 0, false, false, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := &unlikeState{visibility: tc.visibility, affected: tc.affected, countMissing: tc.missing}
			db := sql.OpenDB(unlikeConnector{s})
			defer db.Close()
			count, visible, err := (OracleSessions{db}).RemovePostLike(context.Background(), 42, 1)
			if err != nil || visible != tc.visible || count != tc.count {
				t.Fatalf("%v %v %v", count, visible, err)
			}
			if s.write != "" && (!strings.Contains(s.write, "fn_can_view_post(:user_id,:post_id)=1") || len(s.args) != 2 || s.args[0].Value != int64(1) || s.args[1].Value != int64(42)) {
				t.Fatal("bad write", s.write, s.args)
			}
		})
	}
}
