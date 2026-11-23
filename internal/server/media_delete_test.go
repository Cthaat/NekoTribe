package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type mediaDeleteFixture struct {
	*memorySessions
	result mediaDeleteRecord
	err    error
	user   int64
	id     float64
}

type mediaDeleteDBState struct {
	driverState
	mode          string
	reads, writes []listQueryCall
}
type mediaDeleteConnector struct{ state *mediaDeleteDBState }
type mediaDeleteConn struct {
	*testConn
	state *mediaDeleteDBState
}

func (c mediaDeleteConnector) Connect(context.Context) (driver.Conn, error) {
	return &mediaDeleteConn{&testConn{&c.state.driverState}, c.state}, nil
}
func (c mediaDeleteConnector) Driver() driver.Driver { return testDriver{} }
func (c *mediaDeleteConn) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.state.reads = append(c.state.reads, listQueryCall{q, args})
	if c.state.mode == "query-error" {
		return nil, errors.New("private query")
	}
	if c.state.mode == "missing" {
		return emptyRows{&c.state.driverState}, nil
	}
	if strings.Contains(q, "AS in_use") {
		if c.state.mode == "in-use" {
			return &alertRows{values: []driver.Value{int64(1)}}, nil
		}
		return emptyRows{&c.state.driverState}, nil
	}
	if q == visionContract.SQL["lock_owned_image"] {
		return &alertRows{values: []driver.Value{int64(20)}}, nil
	}
	if q == directExtrasContract.SQL["asset_is_linked"] {
		if c.state.mode == "direct-in-use" {
			return &alertRows{values: []driver.Value{int64(1)}}, nil
		}
		return emptyRows{&c.state.driverState}, nil
	}
	return &alertRows{values: []driver.Value{"owned/a.txt", "/storage/owned/a.txt", nil}}, nil
}
func (c *mediaDeleteConn) ExecContext(_ context.Context, q string, args []driver.NamedValue) (driver.Result, error) {
	c.state.writes = append(c.state.writes, listQueryCall{q, args})
	if c.state.mode == "write-error" {
		return nil, errors.New("private write")
	}
	if c.state.mode == "race" {
		return driver.RowsAffected(0), nil
	}
	if c.state.mode == "multiple" {
		return driver.RowsAffected(2), nil
	}
	return driver.RowsAffected(1), nil
}
func TestMediaDeleteRepositoryCommitAndOwnership(t *testing.T) {
	for _, mode := range []string{"success", "missing", "in-use", "direct-in-use", "race", "multiple", "query-error", "write-error", "commit-error"} {
		t.Run(mode, func(t *testing.T) {
			state := &mediaDeleteDBState{mode: mode}
			if mode == "commit-error" {
				state.fail = "commit"
			}
			db := sql.OpenDB(mediaDeleteConnector{state})
			defer db.Close()
			record, err := (OracleSessions{db}).DeleteMedia(context.Background(), 42, 20)
			inUse := mode == "in-use" || mode == "direct-in-use"
			shouldError := inUse || mode == "multiple" || strings.HasSuffix(mode, "-error")
			if (err != nil) != shouldError || (err != nil && strings.Contains(err.Error(), "private")) {
				t.Fatal(record, err)
			}
			if record.Deleted != (mode == "success") {
				t.Fatal(record)
			}
			if mode == "success" && (record.Key != "owned/a.txt" || state.commits != 1) {
				t.Fatal(record, state.commits)
			}
			if len(state.reads) == 0 || !strings.Contains(state.reads[0].sql, "owner_user_id=:user_id FOR UPDATE") {
				t.Fatal(state.reads)
			}
			if mode != "missing" && mode != "query-error" {
				expectedReads := 3
				if mode == "in-use" {
					expectedReads = 2
				}
				if len(state.reads) != expectedReads || (expectedReads == 3 && state.reads[2].sql != directExtrasContract.SQL["asset_is_linked"]) ||
					!strings.Contains(state.reads[1].sql, "n_post_media") ||
					!strings.Contains(state.reads[1].sql, "n_chat_message_media") ||
					!strings.Contains(state.reads[1].sql, "avatar_media_id") ||
					!strings.Contains(state.reads[1].sql, "g.avatar_url") ||
					!strings.Contains(state.reads[1].sql, "g.cover_url") {
					t.Fatal(state.reads)
				}
			}
			if inUse && (!errors.Is(err, errMediaInUse) || state.commits != 0) {
				t.Fatal(err, state.commits)
			}
			if mode != "missing" && mode != "query-error" && !inUse {
				if len(state.writes) != 1 || !strings.Contains(state.writes[0].sql, "owner_user_id=:user_id") {
					t.Fatal(state.writes)
				}
				binds := map[string]interface{}{}
				for _, arg := range state.writes[0].args {
					binds[arg.Name] = arg.Value
				}
				if binds["user_id"] != int64(42) || binds["media_id"] != float64(20) {
					t.Fatal(binds)
				}
			} else if len(state.writes) != 0 {
				t.Fatal(state.writes)
			}
		})
	}
}

func (s *mediaDeleteFixture) DeleteMedia(_ context.Context, user int64, id float64) (mediaDeleteRecord, error) {
	s.user, s.id = user, id
	return s.result, s.err
}

func TestMediaDeleteRouteBoundaries(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		name       string
		result     mediaDeleteRecord
		err        error
		status     int
		expectFile bool
	}{
		{"success", mediaDeleteRecord{Deleted: true, Key: "owned/file.txt"}, nil, 200, false},
		{"missing", mediaDeleteRecord{}, nil, 404, true},
		{"in-use", mediaDeleteRecord{}, errMediaInUse, 409, true},
		{"uncertain commit", mediaDeleteRecord{}, errors.New("private detail"), 500, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			if err := os.Mkdir(filepath.Join(root, "owned"), 0700); err != nil {
				t.Fatal(err)
			}
			file := filepath.Join(root, "owned", "file.txt")
			if err := os.WriteFile(file, []byte("preserve"), 0600); err != nil {
				t.Fatal(err)
			}
			s := &mediaDeleteFixture{memorySessions: store(), result: tc.result, err: tc.err}
			h := NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{LocalStorage: LocalStorageConfig{Root: root}})
			r := httptest.NewRequest("DELETE", "/api/v2/media/20", nil)
			r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != tc.status || s.user != 42 || s.id != 20 || w.Header().Get("Cache-Control") != "private, no-store" || strings.Contains(w.Body.String(), "private detail") {
				t.Fatal(w.Code, w.Body.String(), s.user, s.id)
			}
			_, err := os.Stat(file)
			if (err == nil) != tc.expectFile {
				t.Fatal("unexpected file state", err)
			}
		})
	}
	for _, tc := range []struct {
		path, token string
		status      int
	}{{"20", "", 401}, {"invalid", "valid", 400}} {
		s := &mediaDeleteFixture{memorySessions: store()}
		h := NewHandler(codec, s, CorsPolicy{})
		r := httptest.NewRequest("DELETE", "/api/v2/media/"+tc.path, nil)
		if tc.token != "" {
			r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != tc.status || s.id != 0 {
			t.Fatal(w.Code, s.id)
		}
	}
}

func TestMediaDeleteStorageReferences(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "owned"), 0700); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(root, "owned", "a.txt")
	if err := os.WriteFile(file, []byte("safe"), 0600); err != nil {
		t.Fatal(err)
	}
	c := LocalStorageConfig{Root: root}
	p := StorageURLPolicy{PublicBase: "/media", BaseURL: "https://example.test"}
	if err := deleteMediaReference(c, p, "", "https://other.test/media/owned/a.txt"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(file); err != nil {
		t.Fatal("external URL removed file", err)
	}
	if err := deleteMediaReference(c, p, "../escape", ""); err == nil {
		t.Fatal("accepted traversal")
	}
	if err := deleteMediaReference(c, p, "TEMP/concurrent-upload", ""); err == nil {
		t.Fatal("accepted temporary upload path")
	}
	if err := deleteMediaReference(c, p, "", "https://example.test/media/owned/a.txt"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(file); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("managed file remains", err)
	}
	if err := deleteMediaReference(LocalStorageConfig{Root: root, Unsupported: true}, p, "owned/missing", ""); err == nil {
		t.Fatal("s3 silently fell back")
	}
}

func TestMediaDeleteAcceptsNuxtNumericIDs(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		raw  string
		want float64
	}{{"2e1", 20}, {"0x14", 20}, {"20.5", 20.5}} {
		s := &mediaDeleteFixture{memorySessions: store()}
		r := httptest.NewRequest("DELETE", "/api/v2/media/"+tc.raw, nil)
		r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		w := httptest.NewRecorder()
		NewHandler(codec, s, CorsPolicy{}).ServeHTTP(w, r)
		if w.Code != 404 || s.id != tc.want {
			t.Fatal(tc.raw, w.Code, s.id)
		}
	}
}

func TestMediaDeleteRejectsLinkedDirectory(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	file := filepath.Join(outside, "a.txt")
	if err := os.WriteFile(file, []byte("safe"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "link")); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	if err := deleteMediaReference(LocalStorageConfig{Root: root}, StorageURLPolicy{}, "link/a.txt", ""); err == nil {
		t.Fatal("link accepted")
	}
	if _, err := os.Stat(file); err != nil {
		t.Fatal("outside file removed", err)
	}
}
