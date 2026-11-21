package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"strings"
	"testing"
	"time"
)

type loginQueryConnector struct{ state *driverState }
type loginQueryConn struct {
	*testConn
	state *driverState
}

type incompleteSchemaConnector struct{ state *driverState }
type incompleteSchemaConn struct{ *testConn }

type banExpiryLoginConnector struct {
	state                                    driverState
	expired, failExpiry, locked, expiryWrite bool
	busy                                     bool
	reads, writes                            int
}

type banExpiryLoginConn struct {
	*testConn
	fixture *banExpiryLoginConnector
}

func (*banExpiryLoginConnector) Driver() driver.Driver { return testDriver{} }

func (f *banExpiryLoginConnector) Connect(context.Context) (driver.Conn, error) {
	return &banExpiryLoginConn{&testConn{&f.state}, f}, nil
}

func (c *banExpiryLoginConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	f := c.fixture
	switch query {
	case loginLookupSQL:
		f.reads++
		status, active := "suspended", int64(0)
		if f.expiryWrite && f.state.commits > 0 {
			status, active = "active", 1
		}
		return &alertRows{values: []driver.Value{int64(42), "tester", "fixture-hash", status, active}}, nil
	case banExpirySQL["candidates"]:
		return &alertRows{values: []driver.Value{int64(42)}}, nil
	case banExpirySQL["lock"], banExpirySQL["lock"] + " SKIP LOCKED":
		f.locked = len(args) == 1 && args[0].Name == "user_id" && args[0].Value == int64(42)
		return &alertRows{values: []driver.Value{int64(42)}, done: f.busy}, nil
	default:
		return nil, errSessionStore
	}
}

func (c *banExpiryLoginConn) ExecContext(_ context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	f := c.fixture
	if !f.locked || len(args) != 1 || args[0].Name != "user_id" || args[0].Value != int64(42) {
		return nil, errSessionStore
	}
	f.writes++
	switch query {
	case banExpirySQL["restore"]:
		if f.expired {
			return driver.RowsAffected(1), nil
		}
		return driver.RowsAffected(0), nil
	case banExpirySQL["expire"]:
		if f.failExpiry {
			return driver.RowsAffected(0), nil
		}
		f.expiryWrite = true
		return driver.RowsAffected(1), nil
	default:
		return nil, errSessionStore
	}
}

func TestLoginRestoresOnlyExpiredBansAndRollsBackIncompleteChanges(t *testing.T) {
	for _, tc := range []struct {
		name                          string
		expired, failExpiry           bool
		reads, writes, commits, rolls int
	}{
		{"still suspended", false, false, 2, 1, 1, 0},
		{"restored", true, false, 2, 2, 1, 0},
		{"incomplete expiry", true, true, 1, 2, 0, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := &banExpiryLoginConnector{expired: tc.expired, failExpiry: tc.failExpiry}
			db := sql.OpenDB(f)
			defer db.Close()
			account, found, err := (OracleSessions{db}).LookupLogin(context.Background(), "tester")
			if (err != nil) != tc.failExpiry || found == tc.failExpiry ||
				account.Active != (tc.expired && !tc.failExpiry) || !f.locked ||
				f.reads != tc.reads || f.writes != tc.writes || f.state.commits != tc.commits || f.state.rollbacks != tc.rolls {
				t.Fatalf("account=%+v err=%v fixture=%+v", account, err, f)
			}
		})
	}
}

func TestBanExpirySweepSkipsContendedAccountsAndRetriesThem(t *testing.T) {
	f := &banExpiryLoginConnector{expired: true, busy: true}
	db := sql.OpenDB(f)
	defer db.Close()
	repo := OracleSessions{db}
	ctx := context.Background()
	if err := repo.sweepExpiredBans(ctx); err != nil || !f.locked || f.writes != 0 {
		t.Fatalf("contended account was processed: err=%v fixture=%+v", err, f)
	}
	f.busy = false
	if err := repo.sweepExpiredBans(ctx); err != nil || !f.expiryWrite || f.writes != 2 || f.state.commits != 2 {
		t.Fatalf("available account was not processed: err=%v fixture=%+v", err, f)
	}
}

func (c incompleteSchemaConnector) Connect(context.Context) (driver.Conn, error) {
	return &incompleteSchemaConn{&testConn{c.state}}, nil
}
func (c incompleteSchemaConnector) Driver() driver.Driver { return testDriver{} }
func (c *incompleteSchemaConn) QueryContext(_ context.Context, q string, _ []driver.NamedValue) (driver.Rows, error) {
	if strings.Contains(q, "n_auth_two_factor_challenges") {
		return nil, errSessionStore
	}
	return emptyRows{c.state}, nil
}

func (c loginQueryConnector) Connect(context.Context) (driver.Conn, error) {
	return &loginQueryConn{testConn: &testConn{state: c.state}, state: c.state}, nil
}
func (c loginQueryConnector) Driver() driver.Driver { return testDriver{} }
func (c *loginQueryConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.state.sql = q
	c.state.args = args
	when := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	switch {
	case strings.Contains(q, "FROM n_users WHERE email"):
		return &alertRows{values: []driver.Value{int64(42), "tester", "public-hash", "active", int64(1)}}, nil
	case strings.Contains(q, "FROM v_user_profile_self"):
		return &alertRows{values: []driver.Value{int64(42), "fake@example.test", "tester", nil, "Test", nil, "Here", nil, nil, "2000-01-01", when, int64(1), int64(1), "active", int64(2), int64(3), int64(4), int64(5), when, when, when, "self"}}, nil
	}
	return nil, errSessionStore
}
func TestLoginOracleQueriesBindIdentityAndMapSelfProfile(t *testing.T) {
	state := &driverState{}
	db := sql.OpenDB(loginQueryConnector{state})
	defer db.Close()
	repo := OracleSessions{db}
	account, found, err := repo.LookupLogin(context.Background(), "tester';--")
	if err != nil || !found || account.UserID != 42 || !account.Active || len(state.args) != 1 || state.args[0].Value != "tester';--" || strings.Contains(state.sql, "';--") {
		t.Fatal("unsafe account query")
	}
	profile, found, err := repo.SelfProfile(context.Background(), 42)
	if err != nil || !found || profile.AvatarURL != "/storage/default-avatar.png" || profile.Email != "fake@example.test" || profile.FollowersCount != 2 || !profile.Relationship.IsSelf || profile.CreatedAt != "2026-01-01T00:00:00.000Z" || profile.BirthDate == nil || *profile.BirthDate != "2000-01-01" {
		t.Fatal("self profile mapping failed", err)
	}
	if len(state.args) != 2 || state.args[0].Name != "viewer_id" || state.args[1].Name != "user_id" {
		t.Fatal("missing profile identity binds")
	}
}
func TestTwoFactorReadinessRejectsMissingChallengeTable(t *testing.T) {
	db := sql.OpenDB(incompleteSchemaConnector{&driverState{}})
	defer db.Close()
	if err := (OracleSessions{db}).CheckTwoFactorSchema(context.Background()); err == nil {
		t.Fatal("missing challenge table accepted")
	}
}
