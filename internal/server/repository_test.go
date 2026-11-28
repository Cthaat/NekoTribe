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
	"time"
)

type driverState struct {
	sql                        string
	args                       []driver.NamedValue
	commits, rollbacks, closed int
	fail                       string
	queryRows                  map[string]driver.Value
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
	if c.state.fail == "trusted-device-unavailable" && q == claimTrustedDeviceSQL {
		return driver.RowsAffected(0), nil
	}
	if c.state.fail == "factor-session-write" && q == insertLoginSessionSQL {
		return nil, errors.New("private session driver error")
	}
	return driver.RowsAffected(1), nil
}
func (c *testConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.state.sql = q
	c.state.args = args
	if c.state.fail == "query" {
		return nil, errors.New("private detail")
	}
	if q == loginHistorySQL {
		return &alertRows{values: []driver.Value{int64(0), nil}}, nil
	}
	if value, found := c.state.queryRows[q]; found {
		return &loginGuardRow{value: value}, nil
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
		}, []string{"last_accessed_at = CURRENT_TIMESTAMP", "access_jti = :access_jti", "access_token_expires_at > CURRENT_TIMESTAMP", "revoked_at IS NULL", "u.user_id = n_auth_sessions.user_id", "u.is_active = 1 AND u.status = 'active'"}, map[string]interface{}{"user_id": int64(42), "session_id": "opaque';--", "access_jti": "jti"}},
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

func TestPasswordResetRepositoryBindsAndCommits(t *testing.T) {
	state := &driverState{}
	db := sql.OpenDB(testConnector{state})
	defer db.Close()
	count, err := (OracleSessions{db}).ResetPasswordAtomic(context.Background(), "fake';--", "otp_fixture", "otp-hash", "synthetic-hash")
	if err != nil || count != resetCommitted || state.commits != 1 || strings.Contains(state.sql, "fake';--") || state.sql != revokeResetDevicesSQL {
		t.Fatal("reset operation failed", err)
	}
	want := map[string]interface{}{"email": "fake';--"}
	for _, arg := range state.args {
		if want[arg.Name] != arg.Value {
			t.Fatal("incorrect bind", arg.Name)
		}
		delete(want, arg.Name)
	}
	if len(want) != 0 {
		t.Fatal("missing binds")
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

func TestOracleRotationUsesAtomicCompareAndSwap(t *testing.T) {
	state := &driverState{}
	db := sql.OpenDB(testConnector{state})
	defer db.Close()
	a := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	r := Rotation{UserID: 42, SessionID: "fixture-session", OldHash: "old-hash", NewHash: "new-hash", AccessJTI: "new-jti", AccessExpiresAt: a, RefreshExpiresAt: a.Add(time.Hour)}
	n, err := (OracleSessions{db}).Rotate(context.Background(), r)
	if err != nil || n != 1 || state.commits != 1 {
		t.Fatal(n, err, state.commits)
	}
	for _, fragment := range []string{"UPDATE n_auth_sessions", "refresh_token_hash = :old_refresh_token_hash", "user_id = :user_id", "session_id = :session_id", "revoked_at IS NULL", "refresh_token_expires_at > CURRENT_TIMESTAMP", "access_jti = :access_jti", "last_refresh_at = CURRENT_TIMESTAMP", "u.user_id = n_auth_sessions.user_id", "u.is_active = 1 AND u.status = 'active'"} {
		if !strings.Contains(state.sql, fragment) {
			t.Fatalf("missing SQL condition %s", fragment)
		}
	}
	expected := map[string]interface{}{"access_jti": r.AccessJTI, "refresh_token_hash": r.NewHash, "access_token_expires_at": "2026-01-02T03:04:05.000+00:00", "refresh_token_expires_at": "2026-01-02T04:04:05.000+00:00", "session_id": r.SessionID, "user_id": r.UserID, "old_refresh_token_hash": r.OldHash}
	for _, value := range state.args {
		if expected[value.Name] != value.Value {
			t.Fatalf("incorrect bind %s", value.Name)
		}
		delete(expected, value.Name)
	}
	if len(expected) != 0 {
		t.Fatal("missing binds", expected)
	}
}

func TestOracleRotationFailuresDoNotReportSuccess(t *testing.T) {
	for _, fault := range []string{"connect", "execute", "commit"} {
		t.Run(fault, func(t *testing.T) {
			state := &driverState{fail: fault}
			db := sql.OpenDB(testConnector{state})
			defer db.Close()
			n, err := (OracleSessions{db}).Rotate(context.Background(), Rotation{})
			if err == nil || n != 0 || strings.Contains(err.Error(), "private") {
				t.Fatalf("unsafe result: %d %v", n, err)
			}
		})
	}
}

func TestOracleLogoutUsesCurrentCredentialAndCommits(t *testing.T) {
	for _, tc := range []struct {
		name, condition, key, value string
		call                        func(OracleSessions, auth.Claims) (int64, error)
	}{
		{"refresh", "refresh_token_hash = :refresh_token_hash", "refresh_token_hash", "synthetic-hash", func(repo OracleSessions, c auth.Claims) (int64, error) {
			return repo.RevokeRefresh(context.Background(), c, "synthetic-hash")
		}},
		{"access", "access_jti = :access_jti", "access_jti", "synthetic-jti", func(repo OracleSessions, c auth.Claims) (int64, error) {
			return repo.RevokeAccess(context.Background(), c)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := &driverState{}
			db := sql.OpenDB(testConnector{state})
			defer db.Close()
			claims := auth.Claims{UserID: 42, SessionID: "opaque';--", JTI: "synthetic-jti"}
			n, err := tc.call(OracleSessions{db}, claims)
			if err != nil || n != 1 || state.commits != 1 {
				t.Fatalf("result %d %v commits %d", n, err, state.commits)
			}
			for _, fragment := range []string{"UPDATE n_auth_sessions", "revoked_at = CURRENT_TIMESTAMP", "session_id = :session_id", "user_id = :user_id", "revoked_at IS NULL", tc.condition} {
				if !strings.Contains(state.sql, fragment) {
					t.Fatalf("missing %s", fragment)
				}
			}
			if strings.Contains(state.sql, "expires_at") || strings.Contains(state.sql, claims.SessionID) {
				t.Fatal("expiration or unbound input in logout SQL")
			}
			expected := map[string]interface{}{"session_id": claims.SessionID, "user_id": claims.UserID, tc.key: tc.value}
			for _, value := range state.args {
				if expected[value.Name] != value.Value {
					t.Fatalf("incorrect binding %s", value.Name)
				}
				delete(expected, value.Name)
			}
			if len(expected) != 0 {
				t.Fatalf("missing bindings %v", expected)
			}
		})
	}
}

func TestOracleLogoutFailuresAreSanitized(t *testing.T) {
	for _, fault := range []string{"connect", "execute", "commit"} {
		t.Run(fault, func(t *testing.T) {
			state := &driverState{fail: fault}
			db := sql.OpenDB(testConnector{state})
			defer db.Close()
			for _, run := range []func() (int64, error){
				func() (int64, error) {
					return (OracleSessions{db}).RevokeRefresh(context.Background(), auth.Claims{}, "hash")
				},
				func() (int64, error) { return (OracleSessions{db}).RevokeAccess(context.Background(), auth.Claims{}) },
			} {
				n, err := run()
				if err == nil || n != 0 || strings.Contains(err.Error(), "private") {
					t.Fatalf("unsafe result %d %v", n, err)
				}
			}
		})
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
