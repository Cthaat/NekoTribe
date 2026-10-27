package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"fmt"
	"strings"
	"testing"
	"time"
)

type registrationSQLState struct {
	queries []string
	args    [][]driver.NamedValue
	exec    *driverState
}
type registrationSQLConnector struct{ s *registrationSQLState }
type registrationSQLConn struct {
	*testConn
	s *registrationSQLState
}

func (c registrationSQLConnector) Connect(context.Context) (driver.Conn, error) {
	return &registrationSQLConn{testConn: &testConn{state: c.s.exec}, s: c.s}, nil
}
func (c registrationSQLConnector) Driver() driver.Driver { return testDriver{} }
func (c *registrationSQLConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.s.queries = append(c.s.queries, q)
	c.s.args = append(c.s.args, args)
	switch {
	case strings.Contains(q, "n_auth_otp_events"):
		return &alertRows{values: []driver.Value{time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)}}, nil
	case strings.Contains(q, "COUNT(*)"):
		return &alertRows{values: []driver.Value{int64(0)}}, nil
	case strings.Contains(q, "seq_user_id.NEXTVAL"):
		return &alertRows{values: []driver.Value{int64(123)}}, nil
	}
	return nil, errSessionStore
}
func TestRegistrationRepositoryUsesBoundQueriesAndCommit(t *testing.T) {
	state := &registrationSQLState{exec: &driverState{}}
	db := sql.OpenDB(registrationSQLConnector{state})
	defer db.Close()
	repo := OracleSessions{db}
	ctx := context.Background()
	valid, err := repo.VerifiedRegistrationOTP(ctx, "fake';--", "otp_fixture")
	if err != nil || !valid || !strings.Contains(state.queries[0], "expires_at > CURRENT_TIMESTAMP") || !strings.Contains(state.queries[0], "verified_at IS NOT NULL") || strings.Contains(state.queries[0], "fake';--") {
		t.Fatal("OTP query invalid", err)
	}
	if len(state.args[0]) != 2 || state.args[0][0].Value != "fake';--" || state.args[0][1].Value != "otp_fixture" {
		t.Fatal("OTP bind invalid")
	}
	exists, err := repo.RegistrationExists(ctx, "fake';--", "username")
	if err != nil || exists || len(state.args[1]) != 2 || state.args[1][0].Value != "fake';--" || state.args[1][1].Value != "username" {
		t.Fatal("duplicate query invalid", err)
	}
	id, err := repo.NextRegistrationID(ctx)
	if err != nil || id != 123 {
		t.Fatal("sequence invalid", err)
	}
	record := RegistrationRecord{UserID: id, Email: "fake';--", Username: "username", PasswordHash: "synthetic-hash", DisplayName: "Test", Bio: "  retained  "}
	if strings.Contains(fmt.Sprintf("%v %#v", record, record), "synthetic-hash") {
		t.Fatal("record leaked")
	}
	if err = repo.InsertRegistration(ctx, record); err != nil || state.exec.commits != 1 || strings.Contains(state.exec.sql, "fake';--") || !strings.Contains(state.exec.sql, "TO_DATE(:birth_date, 'YYYY-MM-DD')") {
		t.Fatal("insert invalid", err)
	}
	want := map[string]interface{}{"user_id": int64(123), "email": "fake';--", "username": "username", "password_hash": "synthetic-hash", "display_name": "Test", "bio": "  retained  ", "location": nil, "phone": nil, "birth_date": nil}
	for _, arg := range state.exec.args {
		if want[arg.Name] != arg.Value {
			t.Fatal("incorrect bind", arg.Name)
		}
		delete(want, arg.Name)
	}
	if len(want) != 0 {
		t.Fatal("missing binds", len(want))
	}
}
