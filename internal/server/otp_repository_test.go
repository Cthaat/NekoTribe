package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"strings"
	"testing"
	"time"
)

type otpSQLState struct {
	queries []string
	args    [][]driver.NamedValue
	exec    *driverState
}
type otpSQLConnector struct{ s *otpSQLState }
type otpSQLConn struct {
	*testConn
	s *otpSQLState
}

func (c otpSQLConnector) Connect(context.Context) (driver.Conn, error) {
	return &otpSQLConn{testConn: &testConn{state: c.s.exec}, s: c.s}, nil
}
func (c otpSQLConnector) Driver() driver.Driver { return testDriver{} }
func (c *otpSQLConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.s.queries = append(c.s.queries, q)
	c.s.args = append(c.s.args, args)
	if strings.Contains(q, "verification_code_hash") {
		return &alertRows{values: []driver.Value{"$2b$04$synthetic"}}, nil
	}
	return &alertRows{values: []driver.Value{time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)}}, nil
}
func TestOTPRepositoryUsesBoundQueriesAndCommittedUpdate(t *testing.T) {
	state := &otpSQLState{exec: &driverState{}}
	db := sql.OpenDB(otpSQLConnector{state})
	defer db.Close()
	repo := OracleSessions{db}
	hash, found, err := repo.FindOTP(context.Background(), "fake';--", "register", "otp_fixture")
	if err != nil || !found || hash == "" {
		t.Fatal(found, err)
	}
	if len(state.queries) != 1 || !strings.Contains(state.queries[0], "expires_at > CURRENT_TIMESTAMP") || strings.Contains(state.queries[0], "fake';--") {
		t.Fatal("unsafe lookup SQL")
	}
	want := map[string]interface{}{"account": "fake';--", "otp_type": "register", "verification_id": "otp_fixture"}
	for _, arg := range state.args[0] {
		if want[arg.Name] != arg.Value {
			t.Fatal("wrong binding", arg)
		}
		delete(want, arg.Name)
	}
	if len(want) != 0 {
		t.Fatal("missing bindings", want)
	}
	if err = repo.MarkOTPVerified(context.Background(), "otp_fixture"); err != nil || state.exec.commits != 1 || !strings.Contains(state.exec.sql, "WHERE verification_id = :verification_id") {
		t.Fatal("uncommitted update", err)
	}
	if len(state.exec.args) != 1 || state.exec.args[0].Name != "verification_id" || state.exec.args[0].Value != "otp_fixture" {
		t.Fatal("bad update bind")
	}
	at, err := repo.OTPVerifiedAt(context.Background(), "otp_fixture")
	if err != nil || at == nil || at.UTC().Format(time.RFC3339) != "2026-01-02T03:04:05Z" || len(state.args[1]) != 1 || state.args[1][0].Value != "otp_fixture" {
		t.Fatal("bad readback", err)
	}
}
