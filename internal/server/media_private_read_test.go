package server

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

type privateMediaFixture struct {
	*memorySessions
	key, scope    string
	err           error
	viewer, media int64
}

func (s *privateMediaFixture) ReadPrivateMedia(_ context.Context, viewer, media int64) (string, string, error) {
	s.viewer, s.media = viewer, media
	return s.key, s.scope, s.err
}

func TestPrivateMediaReadLocal(t *testing.T) {
	root := t.TempDir()
	for _, key := range []string{"private/chat/a.html", "private/post/a.html", "posts/a.html"} {
		filename := filepath.Join(root, filepath.FromSlash(key))
		if err := os.MkdirAll(filepath.Dir(filename), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filename, []byte("012345"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		name, method, path, key, scope, byteRange string
		err                                       error
		status                                    int
		body, contentRange                        string
		lookup                                    bool
		anonymous                                 bool
	}{
		{name: "get", method: "GET", key: "private/chat/a.html", scope: "chat", status: 200, body: "012345", lookup: true},
		{name: "range", method: "GET", key: "private/post/a.html", scope: "post", byteRange: "bytes=1-3", status: 206, body: "123", contentRange: "bytes 1-3/6", lookup: true},
		{name: "head", method: "HEAD", key: "private/chat/a.html", scope: "chat", byteRange: "bytes=99-", status: 200, lookup: true},
		{name: "unsatisfiable", method: "GET", key: "private/chat/a.html", scope: "chat", byteRange: "bytes=99-", status: 416, contentRange: "bytes */6", lookup: true},
		{name: "multiple ranges", method: "GET", key: "private/chat/a.html", scope: "chat", byteRange: "bytes=0-1,3-4", status: 416, contentRange: "bytes */6", lookup: true},
		{name: "no access or missing row", method: "GET", err: sql.ErrNoRows, status: 404, lookup: true},
		{name: "scope mismatch", method: "GET", key: "private/chat/a.html", scope: "post", status: 404, lookup: true},
		{name: "case mismatch", method: "GET", key: "private/Chat/a.html", scope: "chat", status: 404, lookup: true},
		{name: "public key", method: "GET", key: "posts/a.html", scope: "chat", status: 404, lookup: true},
		{name: "unsafe key", method: "GET", key: "private/chat/../post/a.html", scope: "chat", status: 404, lookup: true},
		{name: "missing object", method: "GET", key: "private/chat/missing.html", scope: "chat", status: 404, lookup: true},
		{name: "schema unavailable", method: "GET", err: errors.New("ORA-00904: ACCESS_SCOPE: private diagnostic"), status: 503, lookup: true},
		{name: "generic DB error", method: "GET", err: errors.New("private diagnostic"), status: 500, lookup: true},
		{name: "invalid id", method: "GET", path: "/api/v2/media/9007199254740992/content", status: 400},
		{name: "no session", method: "GET", status: 401, anonymous: true},
		{name: "options", method: "OPTIONS", status: 204, anonymous: true},
		{name: "unsupported method", method: "PATCH", status: 405, anonymous: true},
		{name: "public route isolation", method: "GET", path: "/storage/private/chat/a.html", status: 404, anonymous: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := &privateMediaFixture{memorySessions: store(), key: tc.key, scope: tc.scope, err: tc.err}
			handler := NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{LocalStorage: LocalStorageConfig{Root: root}})
			path := tc.path
			if path == "" {
				path = "/api/v2/media/20/content"
			}
			r := httptest.NewRequest(tc.method, path, nil)
			if !tc.anonymous {
				r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			}
			if tc.byteRange != "" {
				r.Header.Set("Range", tc.byteRange)
			}
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, r)
			if w.Code != tc.status || w.Header().Get("Content-Range") != tc.contentRange ||
				(tc.lookup && (s.viewer != 42 || s.media != 20)) || (!tc.lookup && s.media != 0) {
				t.Fatalf("status %d, headers %v, viewer %d, media %d, body %q", w.Code, w.Header(), s.viewer, s.media, w.Body.String())
			}
			if strings.HasPrefix(path, "/api/") && w.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatal(w.Header())
			}
			if tc.status == http.StatusOK || tc.status == http.StatusPartialContent {
				if w.Header().Get("Content-Type") != "application/octet-stream" ||
					w.Header().Get("Content-Disposition") != "attachment" ||
					w.Header().Get("X-Content-Type-Options") != "nosniff" ||
					w.Header().Get("Accept-Ranges") != "bytes" || w.Body.String() != tc.body {
					t.Fatal(w.Header(), w.Body.String())
				}
			} else if strings.Contains(w.Body.String(), "private diagnostic") || w.Header().Get("Content-Disposition") != "" {
				t.Fatal(w.Header(), w.Body.String())
			}
			if strings.HasPrefix(path, "/api/") && tc.status >= 400 {
				assertPrivateMediaError(t, w)
			}
		})
	}
}

func assertPrivateMediaError(t *testing.T, w *httptest.ResponseRecorder) {
	t.Helper()
	var envelope struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &envelope); err != nil ||
		w.Header().Get("Content-Type") != "application/json; charset=utf-8" ||
		envelope.Code != w.Code*100+1 || envelope.Message == "" {
		t.Fatal(w.Code, w.Header(), w.Body.String())
	}
	switch w.Code {
	case 404:
		if envelope.Message != "媒体不存在" {
			t.Fatal(envelope)
		}
	case 416:
		if envelope.Message != "请求范围无效" {
			t.Fatal(envelope)
		}
	case 503:
		if envelope.Message != "媒体存储暂不可用" {
			t.Fatal(envelope)
		}
	}
}

func TestPrivateMediaReadCORS(t *testing.T) {
	handler := NewHandler(nil, nil, CorsPolicy{Origins: []string{"https://example.test"}})
	r := httptest.NewRequest(http.MethodOptions, "/api/v2/media/20/content", nil)
	r.Header.Set("Origin", "https://example.test")
	r.Header.Set("Access-Control-Request-Method", "HEAD")
	r.Header.Set("Access-Control-Request-Headers", "authorization, range")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != 204 || w.Header().Get("Access-Control-Allow-Methods") != "GET,HEAD,OPTIONS" ||
		w.Header().Get("Access-Control-Allow-Headers") != "authorization,range" ||
		w.Header().Get("Allow") != "GET, HEAD, OPTIONS" {
		t.Fatal(w.Code, w.Header(), w.Body.String())
	}
	exposed := w.Header().Get("Access-Control-Expose-Headers")
	for _, header := range []string{"Content-Range", "Accept-Ranges", "Content-Disposition"} {
		if !strings.Contains(exposed, header) {
			t.Fatal(exposed)
		}
	}
}

func TestPrivateMediaReadS3(t *testing.T) {
	var calls atomic.Int64
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Path != "/neko-media/private/post/42/file.html" ||
			!strings.HasPrefix(r.Header.Get("Authorization"), "AWS4-HMAC-SHA256 Credential=fixture-key/") {
			t.Error("unexpected S3 request")
			w.WriteHeader(400)
			return
		}
		w.Header().Set("Content-Type", "text/html")
		w.Header().Set("Content-Disposition", "inline")
		w.Header().Set("Cache-Control", "public, max-age=60")
		if r.Method == http.MethodHead {
			if r.Header.Get("Range") != "" {
				t.Error("unexpected HEAD range")
			}
			w.Header().Set("Content-Length", "6")
			return
		}
		if r.Header.Get("Range") == "bytes=99-" {
			w.Header().Set("Content-Range", "bytes */6")
			w.WriteHeader(416)
			return
		}
		if r.Header.Get("Range") == "bytes=3-4" {
			w.WriteHeader(500)
			return
		}
		if r.Method != http.MethodGet || r.Header.Get("Range") != "bytes=1-3" {
			t.Error("unexpected GET range")
			w.WriteHeader(400)
			return
		}
		w.Header().Set("Content-Range", "bytes 1-3/6")
		w.WriteHeader(206)
		_, _ = io.WriteString(w, "123")
	}))
	defer remote.Close()
	env := map[string]string{
		"STORAGE_TYPE": "s3", "STORAGE_S3_ENDPOINT": remote.URL, "STORAGE_S3_BUCKET": "neko-media",
		"STORAGE_S3_REGION": "us-east-1", "STORAGE_S3_ACCESS_KEY": "fixture-key", "STORAGE_S3_SECRET_KEY": "fixture-secret",
	}
	config := localStorageConfig(func(key string) (string, bool) { value, ok := env[key]; return value, ok })
	codec, tokens := fixture(t)
	s := &privateMediaFixture{memorySessions: store(), key: "private/post/42/file.html", scope: "post"}
	handler := NewHandlerWithConfig(codec, s, CorsPolicy{}, RefreshConfig{LocalStorage: config})
	for _, tc := range []struct {
		method, path, byteRange, body, contentRange string
		signed                                      bool
		status                                      int
		calls                                       int64
	}{
		{"GET", "/storage/private/post/42/file.html", "", "", "", true, 404, 0},
		{"GET", "/api/v2/media/20/content", "", "", "", false, 401, 0},
		{"GET", "/api/v2/media/20/content", "bytes=1-2,4-5", "", "", false, 401, 0},
		{"GET", "/api/v2/media/20/content", "bytes=1-2,4-5", "", "bytes */6", true, 416, 1},
		{"GET", "/api/v2/media/20/content", "bytes=1-3", "123", "bytes 1-3/6", true, 206, 2},
		{"HEAD", "/api/v2/media/20/content", "bytes=99-", "", "", true, 200, 3},
		{"GET", "/api/v2/media/20/content", "bytes=99-", "", "bytes */6", true, 416, 4},
		{"GET", "/api/v2/media/20/content", "bytes=3-4", "", "", true, 503, 5},
	} {
		r := httptest.NewRequest(tc.method, tc.path, nil)
		if tc.signed {
			r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		}
		r.Header.Set("Range", tc.byteRange)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != tc.status || calls.Load() != tc.calls || w.Header().Get("Content-Range") != tc.contentRange {
			t.Fatal(tc.method, tc.path, w.Code, calls.Load(), w.Body.String())
		}
		if strings.HasPrefix(tc.path, "/api/") && tc.status >= 400 {
			assertPrivateMediaError(t, w)
		}
		if tc.status == 200 || tc.status == 206 {
			if w.Header().Get("Content-Type") != "application/octet-stream" ||
				w.Header().Get("Content-Disposition") != "attachment" ||
				w.Header().Get("Cache-Control") != "private, no-store" ||
				w.Body.String() != tc.body {
				t.Fatal(w.Header(), w.Body.String())
			}
		}
	}
}

type privateMediaQueryFixture struct {
	*testConn
	calls []listQueryCall
	mode  string
}

func (s *privateMediaQueryFixture) Connect(context.Context) (driver.Conn, error) { return s, nil }
func (*privateMediaQueryFixture) Driver() driver.Driver                          { return testDriver{} }
func (s *privateMediaQueryFixture) QueryContext(_ context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	s.calls = append(s.calls, listQueryCall{q, args})
	switch q {
	case directExtrasContract.SQL["private_media_read"]:
		switch s.mode {
		case "unauthorized":
			return emptyRows{s.state}, nil
		case "legacy", "present-but-unreadable", "different-schema":
			return nil, errors.New("ORA-00942: relation unavailable")
		case "missing-column":
			return nil, errors.New("ORA-00904: invalid identifier")
		}
	case schemaOwnerSQL:
		schema := "fixture"
		if s.mode == "different-schema" {
			schema = "other"
		}
		return &schemaFixtureRows{columns: []string{"USER_NAME", "SCHEMA_NAME"}, values: [][]driver.Value{{"fixture", schema}}}, nil
	case directExtrasContract.SQL["attachment_table_present"]:
		if s.mode == "legacy" {
			return emptyRows{s.state}, nil
		}
		return &alertRows{values: []driver.Value{int64(1)}}, nil
	case privateMediaReadQuery:
		if s.mode != "legacy" {
			return nil, errors.New("unexpected old authorization fallback")
		}
	default:
		return nil, errors.New("unexpected private media query")
	}
	return &alertRows{values: []driver.Value{"private/chat/42/file.txt", "chat"}}, nil
}

func TestPrivateMediaReadRepository(t *testing.T) {
	dbFixture := &privateMediaQueryFixture{testConn: &testConn{state: &driverState{}}}
	db := sql.OpenDB(dbFixture)
	defer db.Close()
	repo := OracleSessions{db}
	key, scope, err := repo.ReadPrivateMedia(context.Background(), 42, 20)
	if err != nil || key != "private/chat/42/file.txt" || scope != "chat" {
		t.Fatal(key, scope, err)
	}
	if len(dbFixture.calls) != 1 || dbFixture.calls[0].sql != directExtrasContract.SQL["private_media_read"] {
		t.Fatal("expected the shared authorization query")
	}
	args := dbFixture.calls[0].args
	if len(args) != 2 || args[0].Name != "viewer_id" || args[0].Value != int64(42) ||
		args[1].Name != "media_id" || args[1].Value != int64(20) {
		t.Fatal(args)
	}
}

func TestPrivateMediaLegacyReadRequiresProvenMissingTable(t *testing.T) {
	for _, tc := range []struct {
		mode    string
		calls   int
		success bool
	}{
		{"legacy", 4, true}, {"unauthorized", 1, false}, {"missing-column", 1, false}, {"present-but-unreadable", 3, false}, {"different-schema", 2, false},
	} {
		t.Run(tc.mode, func(t *testing.T) {
			fixture := &privateMediaQueryFixture{testConn: &testConn{state: &driverState{}}, mode: tc.mode}
			db := sql.OpenDB(fixture)
			defer db.Close()
			key, scope, err := (OracleSessions{db}).ReadPrivateMedia(context.Background(), 42, 20)
			if len(fixture.calls) != tc.calls || (err == nil) != tc.success || (tc.success && (key != "private/chat/42/file.txt" || scope != "chat")) || (!tc.success && key != "") {
				t.Fatal(len(fixture.calls), key, scope, err)
			}
			if tc.success && fixture.calls[3].sql != privateMediaReadQuery {
				t.Fatal("confirmed legacy tenant did not use legacy ACL")
			}
		})
	}
}
