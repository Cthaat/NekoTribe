package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"strings"
	"testing"
	"time"
)

type listQueryState struct {
	queries []string
	args    [][]driver.NamedValue
	fail    string
	empty   bool
}
type listQueryConnector struct{ state *listQueryState }
type listQueryConn struct {
	*testConn
	state *listQueryState
}

func (c listQueryConnector) Connect(context.Context) (driver.Conn, error) {
	return &listQueryConn{testConn: &testConn{state: &driverState{}}, state: c.state}, nil
}
func (c listQueryConnector) Driver() driver.Driver { return testDriver{} }
func (c *listQueryConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.state.queries = append(c.state.queries, q)
	c.state.args = append(c.state.args, args)
	if c.state.fail != "" {
		return nil, errSessionStore
	}
	if c.state.empty {
		return &alertRows{values: []driver.Value{int64(2), nil, nil, nil, nil, nil}}, nil
	}
	return &alertRows{values: []driver.Value{int64(2), "a", nil, "127.0.0.1", time.Date(2026, 1, 1, 8, 0, 0, 0, time.FixedZone("fixture", 8*3600)), nil}}, nil
}
func TestListSessionsOracleQueries(t *testing.T) {
	state := &listQueryState{}
	db := sql.OpenDB(listQueryConnector{state})
	defer db.Close()
	rows, total, err := (OracleSessions{db}).ListSessions(context.Background(), 42, SessionPage{Start: 1.5, End: 4.5})
	if err != nil || total != 2 || len(rows) != 1 || rows[0].SessionID != "a" || rows[0].DeviceInfo != "" || rows[0].LastAccessedAt != "2026-01-01T00:00:00.000Z" || rows[0].CreatedAt != "" {
		t.Fatal(rows, total, err)
	}
	if len(state.queries) != 1 || !strings.Contains(state.queries[0], "revoked_at IS NULL") ||
		!strings.Contains(state.queries[0], "ROW_NUMBER() OVER (ORDER BY last_accessed_at DESC, session_id ASC)") ||
		!strings.HasSuffix(state.queries[0], "ORDER BY e.rn") || len(state.args[0]) != 3 {
		t.Fatal("unexpected queries or binds", state)
	}
	want := map[string]interface{}{"user_id": int64(42), "start_row": float64(1.5), "end_row": float64(4.5)}
	for _, arg := range state.args[0] {
		if want[arg.Name] != arg.Value {
			t.Fatal("bad bind", arg)
		}
		delete(want, arg.Name)
	}
	if len(want) != 0 {
		t.Fatal("missing binds", want)
	}
	state.empty = true
	rows, total, err = (OracleSessions{db}).ListSessions(context.Background(), 42, SessionPage{Start: 5, End: 6})
	if err != nil || total != 2 || len(rows) != 0 {
		t.Fatal(rows, total, err)
	}
	state.fail = "query"
	_, _, err = (OracleSessions{db}).ListSessions(context.Background(), 42, SessionPage{})
	if err == nil || strings.Contains(err.Error(), "private") {
		t.Fatal("unsafe error", err)
	}
}
