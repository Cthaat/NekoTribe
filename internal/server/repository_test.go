package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
	"io"
	"strings"
	"testing"
)

type driverState struct {
	sql                        string
	args                       []driver.NamedValue
	commits, rollbacks, closed int
	fail                       string
}
type testConnector struct{ state *driverState }
type testDriver struct{}
type testConn struct{ state *driverState }
type testTx struct{ state *driverState }
type emptyRows struct{ state *driverState }

func (c testConnector) Connect(context.Context) (driver.Conn, error) {
	if c.state.fail == "connect" {
		return nil, errors.New("private detail")
	}
	return &testConn{c.state}, nil
}
func (c testConnector) Driver() driver.Driver           { return testDriver{} }
func (testDriver) Open(string) (driver.Conn, error)     { return nil, errors.New("unused") }
func (c *testConn) Prepare(string) (driver.Stmt, error) { return nil, errors.New("unused") }
func (c *testConn) Close() error {
	c.state.closed++
	if c.state.fail == "close" {
		return errors.New("private driver close detail")
	}
	return nil
}
func (c *testConn) Begin() (driver.Tx, error) { return &testTx{c.state}, nil }
func (c *testConn) ExecContext(_ context.Context, q string, args []driver.NamedValue) (driver.Result, error) {
	c.state.sql = q
	c.state.args = args
	if c.state.fail == "execute" {
		return nil, errors.New("private detail")
	}
	return driver.RowsAffected(1), nil
}
func (c *testConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.state.sql = q
	c.state.args = args
	if c.state.fail == "query" {
		return nil, errors.New("private detail")
	}
	return emptyRows{c.state}, nil
}
func (tx *testTx) Commit() error {
	tx.state.commits++
	if tx.state.fail == "commit" {
		return errors.New("private detail")
	}
	return nil
}
func (tx *testTx) Rollback() error  { tx.state.rollbacks++; return nil }
func (emptyRows) Columns() []string { return []string{"USER_ID"} }
func (r emptyRows) Close() error {
	if r.state.fail == "rows-close" {
		return errors.New("private detail")
	}
	return nil
}
func (emptyRows) Next([]driver.Value) error { return io.EOF }
func TestOracleRepositoryBindsAndCommits(t *testing.T) {
	ctx := context.Background()
	state := &driverState{}
	db := sql.OpenDB(testConnector{state})
	defer db.Close()
	repo := OracleSessions{db}
	for _, tc := range []struct {
		op        string
		run       func() (int64, error)
		fragments []string
		args      map[string]interface{}
	}{
		{"touch", func() (int64, error) {
			return repo.Touch(ctx, auth.Claims{UserID: 42, SessionID: "opaque';--", JTI: "jti"})
		}, []string{"last_accessed_at = CURRENT_TIMESTAMP", "access_jti = :access_jti", "access_token_expires_at > CURRENT_TIMESTAMP", "revoked_at IS NULL"}, map[string]interface{}{"user_id": int64(42), "session_id": "opaque';--", "access_jti": "jti"}},
		{"revoke", func() (int64, error) { return repo.Revoke(ctx, 42, "opaque';--") }, []string{"revoked_at = CURRENT_TIMESTAMP", "session_id = :session_id", "revoked_at IS NULL"}, map[string]interface{}{"user_id": int64(42), "session_id": "opaque';--"}},
		{"others", func() (int64, error) { return repo.RevokeOthers(ctx, 42, "current") }, []string{"session_id <> :session_id", "revoked_at IS NULL"}, map[string]interface{}{"user_id": int64(42), "session_id": "current"}},
	} {
		t.Run(tc.op, func(t *testing.T) {
			before := state.commits
			n, e := tc.run()
			if e != nil || n != 1 {
				t.Fatal(n, e)
			}
			if state.commits != before+1 {
				t.Fatal("missing independent commit")
			}
			for _, f := range tc.fragments {
				if !strings.Contains(state.sql, f) {
					t.Fatalf("SQL missing %s: %s", f, state.sql)
				}
			}
			if strings.Contains(state.sql, "opaque") {
				t.Fatal("SQL interpolation")
			}
			for _, v := range state.args {
				if tc.args[v.Name] != v.Value {
					t.Fatalf("binding %v", v)
				}
				delete(tc.args, v.Name)
			}
			if len(tc.args) != 0 {
				t.Fatalf("missing binds %v", tc.args)
			}
		})
	}
	if e := repo.Preflight(ctx); e != nil {
		t.Fatal(e)
	}
	if !strings.Contains(state.sql, "WHERE 1 = 0") || !strings.Contains(state.sql, "access_token_expires_at") {
		t.Fatal(state.sql)
	}
	if state.commits != 3 {
		t.Fatal("preflight mutation")
	}
}
func TestOracleRepositoryErrors(t *testing.T) {
	for _, fault := range []string{"connect", "execute", "commit"} {
		t.Run(fault, func(t *testing.T) {
			s := &driverState{fail: fault}
			db := sql.OpenDB(testConnector{s})
			defer db.Close()
			_, e := (OracleSessions{db}).Touch(context.Background(), auth.Claims{})
			if e == nil || strings.Contains(e.Error(), "private") {
				t.Fatal("unsafe or absent error", e)
			}
		})
	}
	for _, fault := range []string{"query", "rows-close"} {
		s := &driverState{fail: fault}
		db := sql.OpenDB(testConnector{s})
		if e := (OracleSessions{db}).Preflight(context.Background()); e == nil {
			t.Fatal("preflight accepted", fault)
		}
		db.Close()
	}
}
func TestDatabaseShutdownClosesDriverAndRedactsFailure(t *testing.T) {
	for _, fault := range []string{"", "close"} {
		s := &driverState{fail: fault}
		db := sql.OpenDB(testConnector{s})
		if e := (OracleSessions{db}).Preflight(context.Background()); e != nil {
			t.Fatal(e)
		}
		e := CloseOracle(db)
		if s.closed != 1 {
			t.Fatal("driver connection was not closed")
		}
		if fault == "close" && (e == nil || strings.Contains(e.Error(), "private")) {
			t.Fatal("missing or unsafe close error", e)
		}
		if fault == "" && e != nil {
			t.Fatal(e)
		}
	}
}
