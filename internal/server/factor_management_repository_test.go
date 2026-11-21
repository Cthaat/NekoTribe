package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"strings"
	"testing"
)

type factorTxState struct {
	driverState
	queries        []string
	args           [][]driver.NamedValue
	failAt, zeroAt int
}
type factorTxConnector struct{ state *factorTxState }
type factorTxConn struct {
	*testConn
	state *factorTxState
}

func (c factorTxConnector) Connect(context.Context) (driver.Conn, error) {
	return &factorTxConn{testConn: &testConn{state: &c.state.driverState}, state: c.state}, nil
}
func (factorTxConnector) Driver() driver.Driver { return testDriver{} }
func (c *factorTxConn) ExecContext(_ context.Context, q string, args []driver.NamedValue) (driver.Result, error) {
	c.state.queries = append(c.state.queries, q)
	c.state.args = append(c.state.args, args)
	n := len(c.state.queries)
	if n == c.state.failAt {
		return nil, errors.New("private-factor-db")
	}
	if n == c.state.zeroAt {
		return driver.RowsAffected(0), nil
	}
	return driver.RowsAffected(1), nil
}
func TestFactorManagementTransactions(t *testing.T) {
	for _, action := range []string{"setup", "confirm", "disable"} {
		last := 4
		if action == "confirm" {
			last = 13
		}
		if action == "disable" {
			last = 5
		}
		for fail := 0; fail <= last; fail++ {
			s := &factorTxState{failAt: fail}
			db := sql.OpenDB(factorTxConnector{s})
			m := FactorMutation{Action: action, Expected: FactorSecret{Encrypted: "old", IV: "iv", Tag: "tag"}, New: FactorSecret{Encrypted: "new", IV: "iv", Tag: "tag"}, RecoveryHashes: make([]string, 10)}
			if action == "disable" {
				m.RecoveryID = 1
			}
			out, err := (OracleSessions{DB: db}).ApplyFactorMutation(context.Background(), 42, m)
			if fail == 0 {
				if err != nil || out != factorApplied || s.commits != 1 || s.rollbacks != 0 {
					t.Fatalf("%s success failed", action)
				}
			} else {
				if err == nil || s.rollbacks != 1 || s.commits != 0 {
					t.Fatalf("%s fault%d not rolled back", action, fail)
				}
			}
			if action != "setup" && !strings.Contains(s.queries[0], "secret_encrypted = :old_encrypted") {
				t.Fatal("missing ciphertext CAS")
			}
			for _, args := range s.args {
				for _, arg := range args {
					if arg.Name == "user_id" && arg.Value != int64(42) {
						t.Fatal("owner bind mismatch")
					}
				}
			}
			db.Close()
		}
		for _, zero := range []int{1, 2} {
			if zero == 2 && action != "disable" {
				continue
			}
			s := &factorTxState{zeroAt: zero}
			db := sql.OpenDB(factorTxConnector{s})
			m := FactorMutation{Action: action, Expected: FactorSecret{}, New: FactorSecret{}, RecoveryHashes: make([]string, 10), RecoveryID: 1}
			out, err := (OracleSessions{DB: db}).ApplyFactorMutation(context.Background(), 42, m)
			want := factorChanged
			if zero == 2 {
				want = factorRecoveryUsed
			}
			if err != nil || out != want || s.rollbacks != 1 || s.commits != 0 {
				t.Fatal("guard conflict not rolled back")
			}
			db.Close()
		}
	}
}

func TestFactorRecoveryConsumptionHasNoZeroIDSentinel(t *testing.T) {
	state := &factorTxState{zeroAt: 2}
	db := sql.OpenDB(factorTxConnector{state})
	defer db.Close()
	outcome, err := (OracleSessions{DB: db}).ApplyFactorMutation(context.Background(), 42, FactorMutation{Action: "disable", RecoveryID: 0, UsesRecoveryCode: true})
	if err != nil || outcome != factorRecoveryUsed || state.rollbacks != 1 || state.commits != 0 {
		t.Fatal("matched recovery proof must be conditionally consumed even for ID zero")
	}
	if len(state.args) != 2 || len(state.args[1]) != 2 ||
		state.args[1][0].Name != "recovery_code_id" || state.args[1][0].Value != int64(0) ||
		state.args[1][1].Name != "user_id" || state.args[1][1].Value != int64(42) {
		t.Fatal("missing account scope on recovery consumption")
	}
}
