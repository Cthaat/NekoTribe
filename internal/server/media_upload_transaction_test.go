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

type mediaUploadDBState struct {
	driverState
	mode  string
	calls []listQueryCall
}
type mediaUploadConnector struct{ s *mediaUploadDBState }
type mediaUploadConn struct {
	*testConn
	s *mediaUploadDBState
}
type mediaUploadTx struct{ s *mediaUploadDBState }

func (c mediaUploadConnector) Connect(context.Context) (driver.Conn, error) {
	if c.s.mode == "connect" {
		return nil, errors.New("private")
	}
	return &mediaUploadConn{&testConn{&c.s.driverState}, c.s}, nil
}
func (mediaUploadConnector) Driver() driver.Driver { return testDriver{} }
func (c *mediaUploadConn) Begin() (driver.Tx, error) {
	if c.s.mode == "begin" {
		return nil, errors.New("private")
	}
	return &mediaUploadTx{c.s}, nil
}
func (tx *mediaUploadTx) Commit() error {
	tx.s.commits++
	if tx.s.mode == "commit" {
		return errors.New("private commit")
	}
	return nil
}
func (tx *mediaUploadTx) Rollback() error {
	tx.s.rollbacks++
	if tx.s.mode == "rollback" {
		return errors.New("private rollback")
	}
	return nil
}
func (c *mediaUploadConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.s.calls = append(c.s.calls, listQueryCall{q, append([]driver.NamedValue(nil), args...)})
	if strings.Contains(q, "seq_media_id") {
		if c.s.mode == "sequence" {
			return nil, errors.New("private sequence")
		}
		return &alertRows{values: []driver.Value{int64(99)}}, nil
	}
	if strings.Contains(q, "FROM n_media_assets") {
		if c.s.mode == "read" {
			return nil, errors.New("private read")
		}
		if c.s.mode == "missing" {
			return emptyRows{&c.s.driverState}, nil
		}
		return &alertRows{values: []driver.Value{int64(99), "file", "a.txt", "/storage/posts/a.txt", int64(3), "text/plain", nil, nil, nil, nil, "alt", nil, "ready", time.Date(2026, 10, 29, 0, 0, 0, 0, time.UTC)}}, nil
	}
	return nil, errors.New("unexpected query")
}
func (c *mediaUploadConn) ExecContext(_ context.Context, q string, args []driver.NamedValue) (driver.Result, error) {
	c.s.calls = append(c.s.calls, listQueryCall{q, append([]driver.NamedValue(nil), args...)})
	if c.s.mode == "insert" || c.s.mode == "rollback" {
		return nil, errors.New("private insert")
	}
	if c.s.mode == "zero" {
		return driver.RowsAffected(0), nil
	}
	return driver.RowsAffected(1), nil
}

func TestMediaUploadTransactionCompensationBoundaries(t *testing.T) {
	input := mediaUploadInput{UserID: 42, Key: "posts/a.txt", PublicURL: "/storage/posts/a.txt", FileName: "a.txt", MediaType: "file", MIMEType: "text/plain", Size: 3, AltText: "alt"}
	for _, tc := range []struct {
		mode               string
		ok, cleanup        bool
		commits, rollbacks int
	}{
		{"success", true, false, 1, 0}, {"connect", false, true, 0, 0}, {"sequence", false, true, 0, 0}, {"schema", false, true, 0, 0}, {"begin", false, true, 0, 0}, {"insert", false, true, 0, 1}, {"zero", false, true, 0, 1}, {"read", false, true, 0, 1}, {"missing", false, true, 0, 1}, {"rollback", false, false, 0, 1}, {"commit", false, false, 1, 0},
	} {
		t.Run(tc.mode, func(t *testing.T) {
			state := &mediaUploadDBState{mode: tc.mode}
			db := sql.OpenDB(mediaUploadConnector{state})
			defer db.Close()
			verify := func(_ context.Context, _ *sql.Conn) error {
				if tc.mode == "schema" {
					return errMediaSchema
				}
				return nil
			}
			result, err := (OracleSessions{db}).createMediaAtomic(context.Background(), input, StorageURLPolicy{}, verify)
			if (err == nil) != tc.ok || result.CleanupSafe != tc.cleanup || state.commits != tc.commits || state.rollbacks != tc.rollbacks {
				t.Fatalf("result=%+v err=%v commits=%d rollbacks=%d", result, err, state.commits, state.rollbacks)
			}
			if err != nil && strings.Contains(err.Error(), "private") {
				t.Fatal("leaked driver error")
			}
			if tc.ok && (result.Media.MediaID != 99 || result.Media.PublicURL != "/storage/posts/a.txt" || result.Media.AltText == nil || *result.Media.AltText != "alt") {
				t.Fatal(result.Media)
			}
			for _, call := range state.calls {
				if strings.HasPrefix(call.sql, "INSERT INTO n_media_assets") {
					binds := map[string]any{}
					for _, arg := range call.args {
						binds[arg.Name] = arg.Value
					}
					if binds["owner_user_id"] != int64(42) || binds["storage_key"] != "posts/a.txt" {
						t.Fatal(binds)
					}
				}
			}
		})
	}
}

func TestMediaUploadMappingFailureRollsBackBeforeCommit(t *testing.T) {
	state := &mediaUploadDBState{}
	db := sql.OpenDB(mediaUploadConnector{state})
	defer db.Close()
	input := mediaUploadInput{UserID: 42, Key: "posts/a.txt", PublicURL: "/storage/posts/a.txt", FileName: "a.txt", MediaType: "file", MIMEType: "text/plain", Size: 3}
	result, err := (OracleSessions{db}).createMediaAtomic(context.Background(), input, StorageURLPolicy{invalidPublicBase: true}, func(context.Context, *sql.Conn) error { return nil })
	if err == nil || !result.CleanupSafe || state.commits != 0 || state.rollbacks != 1 {
		t.Fatal(result, err, state.commits, state.rollbacks)
	}
}
