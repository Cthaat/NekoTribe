package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

type registrationSQLState struct {
	queries []string
	args    [][]driver.NamedValue
	exec    *driverState
	claims  int
	mode    string
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
		if c.s.mode == "duplicate" {
			return &alertRows{values: []driver.Value{int64(1)}}, nil
		}
		return &alertRows{values: []driver.Value{int64(0)}}, nil
	case strings.Contains(q, "seq_user_id.NEXTVAL"):
		return &alertRows{values: []driver.Value{int64(123)}}, nil
	}
	return nil, errSessionStore
}
func (c *registrationSQLConn) ExecContext(ctx context.Context, q string, args []driver.NamedValue) (driver.Result, error) {
	if q == claimRegistrationOTPSQL {
		c.s.claims++
		if c.s.mode == "expired" {
			return driver.RowsAffected(0), nil
		}
	}
	if q == insertRegistrationSQL {
		switch c.s.mode {
		case "insert-error":
			return nil, errSessionStore
		case "duplicate":
			return nil, emailUniqueError{}
		}
	}
	return c.testConn.ExecContext(ctx, q, args)
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
	if err = repo.InsertRegistration(ctx, record, "otp_fixture"); err != nil || state.claims != 1 || state.exec.commits != 1 || strings.Contains(state.exec.sql, "fake';--") || !strings.Contains(state.exec.sql, "TO_DATE(:birth_date, 'YYYY-MM-DD')") {
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

func TestRegistrationRollsBackUnusableClaimAndFailedInsert(t *testing.T) {
	for _, tc := range []struct {
		mode string
		want error
	}{
		{"expired", errRegistrationOTPMissing},
		{"insert-error", errSessionStore},
		{"duplicate", errRegistrationConflict},
	} {
		state := &registrationSQLState{exec: &driverState{}, mode: tc.mode}
		db := sql.OpenDB(registrationSQLConnector{state})
		err := (OracleSessions{DB: db}).InsertRegistration(context.Background(), RegistrationRecord{Email: "a@example.test"}, "otp_fixture")
		db.Close()
		if !errors.Is(err, tc.want) || state.claims != 1 || state.exec.rollbacks != 1 || state.exec.commits != 0 {
			t.Fatalf("%s: err=%v claims=%d transaction=%+v", tc.mode, err, state.claims, state.exec)
		}
	}
}
