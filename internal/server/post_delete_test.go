package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

type postDeleteFixture struct {
	*memorySessions
	state      string
	viewer, id int64
}

func (s *postDeleteFixture) DeletePost(_ context.Context, viewer, id int64) (postDeleteResult, error) {
	s.viewer, s.id = viewer, id
	switch s.state {
	case "missing", "deleted", "race":
		return postMissing, nil
	case "other":
		return postNotOwner, nil
	case "query-error", "write-error", "close-error":
		return postMissing, errors.New("private detail")
	}
	return postDeleted, nil
}
func TestPostDeleteSharedRoutes(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/post-delete.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors struct {
		Cases []struct {
			ID       string `json:"id"`
			Path     string `json:"path_id"`
			State    string `json:"state"`
			Expected struct {
				Status, Code int
				Message      string
			}
		}
	}
	if err = json.Unmarshal(raw, &vectors); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	for _, tc := range vectors.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			s := &postDeleteFixture{memorySessions: store(), state: tc.State}
			h := NewHandler(codec, s, CorsPolicy{})
			r := httptest.NewRequest("DELETE", "/api/v2/posts/"+tc.Path+"?author_id=7", strings.NewReader("{broken ignored"))
			r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			var out struct {
				Code       int
				Message    string
				Data, Meta interface{}
			}
			if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
				t.Fatal(err)
			}
			if w.Code != tc.Expected.Status || out.Code != tc.Expected.Code || out.Message != tc.Expected.Message || out.Data != nil || out.Meta != nil || w.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatalf("%d %s", w.Code, w.Body.String())
			}
			if w.Code == 400 {
				if s.id != 0 {
					t.Fatal("invalid ID reached repository")
				}
			} else if s.viewer != 42 || s.id != 20 {
				t.Fatal(s.viewer, s.id)
			}
		})
	}
	s := &postDeleteFixture{memorySessions: store()}
	h := NewHandler(codec, s, CorsPolicy{})
	for _, token := range []string{"", "invalid"} {
		r := httptest.NewRequest("DELETE", "/api/v2/posts/01", nil)
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != 401 || s.id != 0 {
			t.Fatal(w.Code, s.id)
		}
	}
}

type postDeleteDBState struct {
	driverState
	mode          string
	reads, writes []listQueryCall
}
type postDeleteConnector struct{ s *postDeleteDBState }
type postDeleteConn struct {
	*testConn
	s *postDeleteDBState
}

func (c postDeleteConnector) Connect(context.Context) (driver.Conn, error) {
	return &postDeleteConn{&testConn{&c.s.driverState}, c.s}, nil
}
func (c postDeleteConnector) Driver() driver.Driver { return testDriver{} }
func (c *postDeleteConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.s.reads = append(c.s.reads, listQueryCall{q, args})
	if c.s.mode == "query-error" {
		return nil, errors.New("private query detail")
	}
	if c.s.mode == "missing" {
		return emptyRows{&c.s.driverState}, nil
	}
	owner := int64(42)
	if c.s.mode == "other" {
		owner = 7
	}
	return &alertRows{values: []driver.Value{owner}}, nil
}
func (c *postDeleteConn) ExecContext(_ context.Context, q string, args []driver.NamedValue) (driver.Result, error) {
	c.s.writes = append(c.s.writes, listQueryCall{q, args})
	if c.s.mode == "write-error" {
		return nil, errors.New("private write detail")
	}
	if c.s.mode == "race" {
		return driver.RowsAffected(0), nil
	}
	return driver.RowsAffected(1), nil
}
func TestPostDeleteRepositoryGuardsAndFailures(t *testing.T) {
	for _, mode := range []string{"missing", "other", "race", "success", "query-error", "write-error", "commit-error"} {
		t.Run(mode, func(t *testing.T) {
			state := &postDeleteDBState{mode: mode}
			if mode == "commit-error" {
				state.fail = "commit"
			}
			db := sql.OpenDB(postDeleteConnector{state})
			defer db.Close()
			actual, err := (OracleSessions{db}).DeletePost(context.Background(), 42, 20)
			if strings.HasSuffix(mode, "-error") {
				if err == nil || strings.Contains(err.Error(), "private") {
					t.Fatal(actual, err)
				}
			} else {
				want := postDeleted
				if mode == "missing" || mode == "race" {
					want = postMissing
				}
				if mode == "other" {
					want = postNotOwner
				}
				if err != nil || actual != want {
					t.Fatal(actual, err)
				}
			}
			if len(state.reads) != 1 {
				t.Fatal(state.reads)
			}
			q := state.reads[0]
			if !strings.Contains(q.sql, "is_deleted=0") || !strings.Contains(q.sql, "author_id") || strings.Contains(q.sql, "fn_can_view_post") {
				t.Fatal(q.sql)
			}
			noWrite := mode == "missing" || mode == "other" || mode == "query-error"
			if noWrite {
				if len(state.writes) != 0 {
					t.Fatal(state.writes)
				}
				return
			}
			if len(state.writes) != 1 {
				t.Fatal(state.writes)
			}
			q = state.writes[0]
			for _, part := range []string{"author_id=:user_id", "is_deleted=0", "post_id=:post_id"} {
				if !strings.Contains(q.sql, part) {
					t.Fatal(q.sql)
				}
			}
			binds := map[string]interface{}{}
			for _, arg := range q.args {
				binds[arg.Name] = arg.Value
			}
			if binds["post_id"] != int64(20) || binds["user_id"] != int64(42) {
				t.Fatal(binds)
			}
			if mode == "success" && state.commits != 1 {
				t.Fatal("missing commit")
			}
		})
	}
}
