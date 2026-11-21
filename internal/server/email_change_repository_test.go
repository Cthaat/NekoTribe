package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"strings"
	"testing"
)

type emailSQLState struct {
	driverState
	queries     []string
	binds       [][]driver.NamedValue
	claim, user int64
	failAt      int
	unique      bool
}
type emailConnector struct{ state *emailSQLState }
type emailConn struct {
	*testConn
	state *emailSQLState
}
type emailTx struct{ state *emailSQLState }
type emailRows struct {
	state *emailSQLState
	read  bool
}
type emailUniqueError struct{}

func (emailUniqueError) Error() string     { return "private unique constraint" }
func (emailUniqueError) ErrorCode() string { return "ORA-00001" }
func (c emailConnector) Connect(context.Context) (driver.Conn, error) {
	if c.state.fail == "connect" {
		return nil, errors.New("private connect")
	}
	return &emailConn{testConn: &testConn{state: &c.state.driverState}, state: c.state}, nil
}
func (emailConnector) Driver() driver.Driver { return testDriver{} }
func (c *emailConn) Begin() (driver.Tx, error) {
	if c.state.fail == "begin" {
		return nil, errors.New("private begin")
	}
	return &emailTx{c.state}, nil
}
func (tx *emailTx) Commit() error {
	tx.state.commits++
	if tx.state.fail == "commit" {
		return errors.New("private commit")
	}
	return nil
}
func (tx *emailTx) Rollback() error {
	tx.state.rollbacks++
	if tx.state.fail == "rollback" {
		return errors.New("private rollback")
	}
	return nil
}
func (c *emailConn) ExecContext(_ context.Context, q string, args []driver.NamedValue) (driver.Result, error) {
	c.state.queries = append(c.state.queries, q)
	c.state.binds = append(c.state.binds, args)
	i := len(c.state.queries)
	if c.state.failAt == i {
		return nil, errors.New("private execute")
	}
	if i == 1 {
		return driver.RowsAffected(c.state.claim), nil
	}
	if c.state.unique {
		return nil, emailUniqueError{}
	}
	return driver.RowsAffected(c.state.user), nil
}
func (c *emailConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.state.queries = append(c.state.queries, q)
	c.state.binds = append(c.state.binds, args)
	if c.state.fail == "read" {
		return nil, errors.New("private read")
	}
	return &emailRows{state: c.state}, nil
}
func (*emailRows) Columns() []string { return []string{"EMAIL", "EMAIL_VERIFIED_AT"} }
func (r *emailRows) Close() error {
	if r.state.fail == "rows-close" {
		return errors.New("private rows close")
	}
	return nil
}
func (r *emailRows) Next(dest []driver.Value) error {
	if r.read || r.state.fail == "read-missing" {
		return io.EOF
	}
	r.read = true
	dest[0] = "fake';--"
	dest[1] = "2026-01-02T03:04:05.000Z"
	return nil
}
func TestEmailChangeOracleTransactions(t *testing.T) {
	for _, c := range []struct {
		name                      string
		claim, user               int64
		fail                      string
		failAt                    int
		unique                    bool
		outcome                   int
		wantError                 bool
		commits, rollbacks, calls int
	}{
		{"success", 1, 1, "", 0, false, emailCommitted, false, 1, 0, 3},
		{"lost claim", 0, 1, "", 0, false, emailExpired, false, 0, 1, 1},
		{"missing user", 1, 0, "", 0, false, emailUserMissing, false, 0, 1, 2},
		{"duplicate OTP", 2, 1, "", 0, false, 0, true, 0, 1, 1},
		{"negative OTP", -1, 1, "", 0, false, 0, true, 0, 1, 1},
		{"duplicate user", 1, 2, "", 0, false, 0, true, 0, 1, 2},
		{"claim error", 1, 1, "", 1, false, 0, true, 0, 1, 1},
		{"update error", 1, 1, "", 2, false, 0, true, 0, 1, 2},
		{"read error", 1, 1, "read", 0, false, 0, true, 0, 1, 3},
		{"missing read", 1, 1, "read-missing", 0, false, 0, true, 0, 1, 3},
		{"rows close error", 1, 1, "rows-close", 0, false, 0, true, 0, 1, 3},
		{"unique race", 1, 1, "", 0, true, emailConflict, false, 0, 1, 2},
		{"rollback error", 0, 1, "rollback", 0, false, 0, true, 0, 1, 1},
		{"commit error", 1, 1, "commit", 0, false, 0, true, 1, 0, 3},
		{"begin error", 1, 1, "begin", 0, false, 0, true, 0, 0, 0},
		{"connect error", 1, 1, "connect", 0, false, 0, true, 0, 0, 0},
	} {
		t.Run(c.name, func(t *testing.T) {
			state := &emailSQLState{claim: c.claim, user: c.user, failAt: c.failAt, unique: c.unique}
			state.fail = c.fail
			db := sql.OpenDB(emailConnector{state})
			defer db.Close()
			data, outcome, err := (OracleSessions{db}).ChangeEmailAtomic(context.Background(), 42, "fake';--", "email_fixture", "private-hash")
			if (err != nil) != c.wantError || (!c.wantError && outcome != c.outcome) || state.commits != c.commits || state.rollbacks != c.rollbacks || len(state.queries) != c.calls {
				t.Fatalf("outcome=%d error=%v commits=%d rollbacks=%d calls=%d", outcome, err, state.commits, state.rollbacks, len(state.queries))
			}
			if !c.wantError && c.outcome == emailCommitted && (data.Email != "fake';--" || data.VerifiedAt != "2026-01-02T03:04:05.000Z") {
				t.Fatal("response mismatch")
			}
			for _, q := range state.queries {
				if strings.Contains(q, "fake';--") || strings.Contains(q, "private-hash") {
					t.Fatal("SQL interpolation")
				}
			}
			if len(state.queries) > 0 && state.queries[0] != claimEmailOTPSQL {
				t.Fatal("incorrect claim SQL")
			}
			for i, binds := range state.binds {
				values := map[string]interface{}{}
				for _, v := range binds {
					values[v.Name] = v.Value
				}
				if i == 0 && (values["account"] != "fake';--" || values["verification_id"] != "email_fixture" || values["code_hash"] != "private-hash") {
					t.Fatal("claim binds")
				}
				if i > 0 && values["user_id"] != int64(42) {
					t.Fatal("actor binds")
				}
			}
		})
	}
}
