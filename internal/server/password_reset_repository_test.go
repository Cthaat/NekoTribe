package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"strings"
	"testing"
)

type resetTransactionState struct {
	driverState
	queries     []string
	binds       [][]driver.NamedValue
	claim, user int64
	failAt      int
}
type resetTransactionConnector struct{ state *resetTransactionState }
type resetTransactionConn struct {
	*testConn
	state *resetTransactionState
}

func (c resetTransactionConnector) Connect(context.Context) (driver.Conn, error) {
	return &resetTransactionConn{testConn: &testConn{state: &c.state.driverState}, state: c.state}, nil
}
func (resetTransactionConnector) Driver() driver.Driver { return testDriver{} }
func (c *resetTransactionConn) ExecContext(_ context.Context, q string, args []driver.NamedValue) (driver.Result, error) {
	c.state.queries = append(c.state.queries, q)
	c.state.binds = append(c.state.binds, args)
	index := len(c.state.queries)
	if c.state.failAt == index {
		return nil, errors.New("synthetic private database error")
	}
	if index == 1 {
		return driver.RowsAffected(c.state.claim), nil
	}
	if index == 2 {
		return driver.RowsAffected(c.state.user), nil
	}
	return driver.RowsAffected(2), nil
}

func TestAtomicResetRepositoryTransactions(t *testing.T) {
	for _, tc := range []struct {
		name                      string
		claim, user               int64
		fail                      int
		outcome                   int
		wantError                 bool
		commits, rollbacks, calls int
	}{
		{"success", 1, 1, 0, resetCommitted, false, 1, 0, 5},
		{"already consumed", 0, 1, 0, resetExpired, false, 0, 1, 1},
		{"missing user", 1, 0, 0, resetUserMissing, false, 0, 1, 2},
		{"duplicate claim", 2, 1, 0, 0, true, 0, 1, 1},
		{"duplicate user", 1, 2, 0, 0, true, 0, 1, 2},
		{"claim failure", 1, 1, 1, 0, true, 0, 1, 1},
		{"password failure", 1, 1, 2, 0, true, 0, 1, 2},
		{"revoke failure", 1, 1, 3, 0, true, 0, 1, 3},
		{"challenge revocation failure", 1, 1, 4, 0, true, 0, 1, 4},
		{"device revocation failure", 1, 1, 5, 0, true, 0, 1, 5},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := &resetTransactionState{claim: tc.claim, user: tc.user, failAt: tc.fail}
			db := sql.OpenDB(resetTransactionConnector{state})
			defer db.Close()
			got, err := (OracleSessions{db}).ResetPasswordAtomic(context.Background(), "fake';--", "otp_fixture", "synthetic-otp-hash", "synthetic-password-hash")
			if (err != nil) != tc.wantError || (!tc.wantError && got != tc.outcome) || state.commits != tc.commits || state.rollbacks != tc.rollbacks || len(state.queries) != tc.calls {
				t.Fatalf("outcome=%d error=%v commits=%d rollbacks=%d calls=%d", got, err, state.commits, state.rollbacks, len(state.queries))
			}
			for _, q := range state.queries {
				if strings.Contains(q, "fake';--") || strings.Contains(q, "synthetic-password-hash") {
					t.Fatal("values interpolated into SQL")
				}
			}
			if !strings.Contains(state.queries[0], "verification_code_hash = '!consumed!'") || !strings.Contains(state.queries[0], "verification_code_hash = :code_hash") {
				t.Fatal("claim must replace and compare OTP hash")
			}
			if len(state.binds) > 0 {
				values := map[string]interface{}{}
				for _, arg := range state.binds[0] {
					values[arg.Name] = arg.Value
				}
				if values["account"] != "fake';--" || values["verification_id"] != "otp_fixture" || values["code_hash"] != "synthetic-otp-hash" {
					t.Fatal("claim binds incorrect")
				}
			}
			if len(state.binds) > 1 {
				values := map[string]interface{}{}
				for _, arg := range state.binds[1] {
					values[arg.Name] = arg.Value
				}
				if values["email"] != "fake';--" || values["password_hash"] != "synthetic-password-hash" {
					t.Fatal("password binds incorrect")
				}
			}
			for index, statement := range []string{revokeResetSessionsSQL, invalidateResetChallengesSQL, revokeResetDevicesSQL} {
				if index+2 >= len(state.queries) {
					break
				}
				args := state.binds[index+2]
				if state.queries[index+2] != statement || len(args) != 1 || args[0].Name != "email" || args[0].Value != "fake';--" {
					t.Fatal("reset revocation scope or binding incorrect")
				}
			}
		})
	}
}

func TestAtomicResetCommitFailureDoesNotReportSuccess(t *testing.T) {
	state := &resetTransactionState{claim: 1, user: 1}
	state.driverState.fail = "commit"
	db := sql.OpenDB(resetTransactionConnector{state})
	defer db.Close()
	_, err := (OracleSessions{db}).ResetPasswordAtomic(context.Background(), "fake@example.test", "otp_fixture", "otp-hash", "new-hash")
	if err == nil || state.commits != 1 || len(state.queries) != 5 {
		t.Fatal("commit failure was reported as success")
	}
}
