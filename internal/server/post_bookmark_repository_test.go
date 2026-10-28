package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"strings"
	"testing"
)

type bookmarkDBState struct {
	driverState
	visibility []bool
	queries    []listQueryCall
	write      listQueryCall
	affected   int64
}
type bookmarkConnector struct{ state *bookmarkDBState }
type bookmarkConn struct {
	*testConn
	state *bookmarkDBState
}

func (c bookmarkConnector) Connect(context.Context) (driver.Conn, error) {
	return &bookmarkConn{&testConn{&c.state.driverState}, c.state}, nil
}
func (c bookmarkConnector) Driver() driver.Driver { return testDriver{} }
func (c *bookmarkConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	c.state.queries = append(c.state.queries, listQueryCall{query, append([]driver.NamedValue(nil), args...)})
	index := len(c.state.queries) - 1
	if index >= len(c.state.visibility) || !c.state.visibility[index] {
		return emptyRows{&c.state.driverState}, nil
	}
	return &alertRows{values: []driver.Value{int64(7)}}, nil
}
func (c *bookmarkConn) ExecContext(_ context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	c.state.write = listQueryCall{query, append([]driver.NamedValue(nil), args...)}
	return driver.RowsAffected(c.state.affected), nil
}
func TestBookmarkRepositoryChecksVisibilityAndBindsWrites(t *testing.T) {
	for _, tc := range []struct {
		name             string
		visibility       []bool
		affected         int64
		saved, want      bool
		queries, commits int
	}{
		{"insert", []bool{true}, 1, true, true, 1, 1},
		{"delete", []bool{true}, 1, false, true, 1, 1},
		{"already saved", []bool{true, true}, 0, true, true, 2, 1},
		{"visibility lost", []bool{true, false}, 0, true, false, 2, 1},
		{"initially hidden", []bool{false}, 0, true, false, 1, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := &bookmarkDBState{visibility: tc.visibility, affected: tc.affected}
			db := sql.OpenDB(bookmarkConnector{state})
			defer db.Close()
			got, err := (OracleSessions{db}).SetPostBookmark(context.Background(), 42, 7, tc.saved)
			if err != nil || got != tc.want || len(state.queries) != tc.queries || state.commits != tc.commits {
				t.Fatalf("got=%v err=%v queries=%d commits=%d", got, err, len(state.queries), state.commits)
			}
			for _, q := range state.queries {
				if !strings.Contains(q.sql, "p.is_deleted=0") || !strings.Contains(q.sql, "fn_can_view_post(:user_id,p.post_id)=1") || len(q.args) != 2 || q.args[0].Value != int64(7) || q.args[1].Value != int64(42) {
					t.Fatal("incorrect visibility query", q)
				}
			}
			if tc.commits != 0 && (!strings.Contains(state.write.sql, "fn_can_view_post(:user_id,:post_id)=1") || len(state.write.args) != 2 || state.write.args[0].Value != int64(7) || state.write.args[1].Value != int64(42)) {
				t.Fatal("incorrect conditional write", state.write)
			}
		})
	}
}
