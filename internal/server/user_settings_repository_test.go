package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"strings"
	"testing"
	"time"
)

type settingsDBState struct {
	driverState
	mode  string
	calls []listQueryCall
}
type settingsConnector struct{ state *settingsDBState }
type settingsConn struct {
	*testConn
	state *settingsDBState
}
type settingsTx struct{ state *settingsDBState }

func (c settingsConnector) Connect(context.Context) (driver.Conn, error) {
	return &settingsConn{&testConn{&c.state.driverState}, c.state}, nil
}
func (settingsConnector) Driver() driver.Driver   { return testDriver{} }
func (c *settingsConn) Begin() (driver.Tx, error) { return &settingsTx{c.state}, nil }
func (tx *settingsTx) Commit() error {
	tx.state.commits++
	if tx.state.mode == "commit" {
		return errors.New("secret")
	}
	return nil
}
func (tx *settingsTx) Rollback() error { tx.state.rollbacks++; return nil }
func (c *settingsConn) ExecContext(_ context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	c.state.calls = append(c.state.calls, listQueryCall{query, append([]driver.NamedValue(nil), args...)})
	if c.state.mode == "merge" || (c.state.mode == "update" && strings.HasPrefix(query, "UPDATE")) {
		return nil, errors.New("secret")
	}
	return driver.RowsAffected(1), nil
}
func (c *settingsConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	c.state.calls = append(c.state.calls, listQueryCall{query, append([]driver.NamedValue(nil), args...)})
	if c.state.mode == "read" {
		return nil, errors.New("secret")
	}
	return &alertRows{values: []driver.Value{int64(42), int64(0), int64(1), "public", int64(1), int64(0), int64(1), int64(1), int64(0), nil, nil, int64(0), int64(3), time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)}}, nil
}

func TestSettingsTransaction(t *testing.T) {
	for _, mode := range []string{"ok", "schema", "merge", "update", "read", "commit"} {
		t.Run(mode, func(t *testing.T) {
			state := &settingsDBState{mode: mode}
			db := sql.OpenDB(settingsConnector{state})
			defer db.Close()
			verify := func(context.Context, *sql.Conn) error {
				if mode == "schema" {
					return errSettingsSchema
				}
				return nil
			}
			patch := settingsPatch{Fields: map[string]interface{}{"show_online_status": 0}}
			result, err := (OracleSessions{db}).applyUserSettings(context.Background(), 42, &patch, verify)
			if mode == "ok" {
				if err != nil || result.UserID != 42 || !result.LoginAlerts || !result.AISentimentReturnProbabilities || result.AISentimentTopK != 3 || state.commits != 1 || state.rollbacks != 0 {
					t.Fatal(result, err, state)
				}
				for _, call := range state.calls {
					if len(call.args) == 0 || call.args[0].Name != "user_id" || call.args[0].Value != int64(42) {
						t.Fatal(call)
					}
				}
			} else if err == nil || strings.Contains(err.Error(), "secret") || state.commits != boolNumber(mode == "commit") || state.rollbacks != boolNumber(mode != "schema" && mode != "commit") {
				t.Fatal(result, err, state)
			}
		})
	}
}
