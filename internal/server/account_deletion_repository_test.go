package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"testing"
)

type deletionTxState struct {
	driverState
	queries []string
	args    [][]driver.NamedValue
	failAt  int
	changed int64
}
type deletionConnector struct{ state *deletionTxState }
type deletionConn struct {
	*testConn
	state *deletionTxState
}

func (c deletionConnector) Connect(context.Context) (driver.Conn, error) {
	return &deletionConn{testConn: &testConn{state: &c.state.driverState}, state: c.state}, nil
}
func (deletionConnector) Driver() driver.Driver { return testDriver{} }
func (c *deletionConn) ExecContext(_ context.Context, q string, args []driver.NamedValue) (driver.Result, error) {
	c.state.queries = append(c.state.queries, q)
	c.state.args = append(c.state.args, args)
	if len(c.state.queries) == c.state.failAt {
		return nil, errors.New("deletion-private-fixture")
	}
	if q == deleteUserSQL {
		return driver.RowsAffected(c.state.changed), nil
	}
	return driver.RowsAffected(2), nil
}
func TestAccountDeletionRepositoryTransaction(t *testing.T) {
	for fail := 0; fail <= 4; fail++ {
		for _, changed := range []int64{0, 1, 2} {
			state := &deletionTxState{failAt: fail, changed: changed}
			db := sql.OpenDB(deletionConnector{state})
			ok, err := (OracleSessions{DB: db}).DeleteAccountAtomic(context.Background(), 42, "old-hash", "new-hash")
			if fail == 0 && changed == 1 {
				if err != nil || !ok || state.commits != 1 || state.rollbacks != 0 {
					t.Fatalf("successful transaction: %v", err)
				}
			} else {
				if ok || state.rollbacks != 1 || state.commits != 0 {
					t.Fatalf("rollback missing fail=%d changed=%d", fail, changed)
				}
				if fail > 0 || changed > 1 {
					if err == nil {
						t.Fatal("missing error")
					}
				}
			}
			if len(state.queries) == 4 {
				args := map[string]interface{}{}
				for _, a := range state.args[3] {
					args[a.Name] = a.Value
				}
				if args["old_hash"] != "old-hash" || args["password_hash"] != "new-hash" || args["email"] != "deleted_42@deleted.local" || args["username"] != "deleted_42" {
					t.Fatal("incorrect bound values")
				}
			}
			db.Close()
		}
	}
}
