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
