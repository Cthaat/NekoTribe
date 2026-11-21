package server

import (
	"bytes"
	"encoding/json"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRetiredStorageRoute(t *testing.T) {
	handler := NewHandlerWithConfig(nil, nil, CorsPolicy{}, RefreshConfig{
		LocalStorage: LocalStorageConfig{Unsupported: true},
	})
	for _, prefix := range []string{"/upload", "/uploads"} {
		for _, method := range []string{http.MethodGet, http.MethodHead} {
			path := prefix + "/images/cat%20photo.png"
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, httptest.NewRequest(method, path+"?ignored=1", nil))
			if w.Code != http.StatusGone || w.Header().Get("Cache-Control") != "no-store" {
				t.Fatal(method, path, w.Code, w.Header())
			}
			if method == http.MethodHead {
				if w.Body.Len() != 0 {
					t.Fatal("HEAD has a body", w.Body.String())
				}
				continue
			}
			var retired struct {
				Code    int
				Message string
				Data    map[string]string
			}
			if err := json.Unmarshal(w.Body.Bytes(), &retired); err != nil {
				t.Fatal(err)
			}
			if retired.Code != 410 || retired.Data["requested_path"] != path ||
				retired.Data["storage_base"] != "/storage" ||
				retired.Message != "Legacy "+prefix+" path removed. Public files are served from /storage." {
				t.Fatal(retired)
			}
		}
	}
}

func TestLocalStorageHTTP(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "images"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "images", "cat.png"), []byte("0123456789"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "images", "empty.txt"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "Private"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "Private", "file.txt"), []byte("reserved"), 0600); err != nil {
		t.Fatal(err)
	}
	const origin = "https://frontend.example"
	handler := NewHandlerWithConfig(nil, nil, CorsPolicy{Origins: []string{origin}}, RefreshConfig{LocalStorage: LocalStorageConfig{Root: root}})
	for _, tc := range []struct {
		method string
		status int
	}{{http.MethodHead, 204}, {http.MethodPost, 403}} {
		req := httptest.NewRequest(http.MethodOptions, "/storage/images/cat.png", nil)
		req.Header.Set("Origin", origin)
		req.Header.Set("Access-Control-Request-Method", tc.method)
		req.Header.Set("Access-Control-Request-Headers", "Range")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		if w.Code != tc.status {
			t.Fatalf("%s preflight: status %d, headers %v", tc.method, w.Code, w.Header())
		}
		if tc.status == 204 && (w.Header().Get("Access-Control-Allow-Origin") != origin ||
			w.Header().Get("Access-Control-Allow-Methods") != "GET,HEAD,OPTIONS" ||
			w.Header().Get("Access-Control-Allow-Headers") != "range") {
			t.Fatalf("HEAD preflight headers: %v", w.Header())
		}
	}
	for _, tc := range []struct {
		path, rangeHeader  string
		status             int
		body, contentRange string
	}{
		{"/storage/images/cat.png", "", 200, "0123456789", ""},
		{"/storage/images/cat.png", "bytes=2-4", 206, "234", "bytes 2-4/10"},
		{"/storage/images/cat.png", "bytes=20-", 416, "", "bytes */10"},
		{"/storage/images/empty.txt", "bytes=0-", 416, "", "bytes */0"},
		{"/storage/images/cat.png", "bytes=-3", 206, "789", "bytes 7-9/10"},
		{"/storage/temp/private", "", 404, "", ""},
		{"/storage/Private/file.txt", "bytes=0-1", 404, "", ""},
		{"/storage/Private%5cfile.txt", "", 404, "", ""},
		{"/storage/%2e%2e/secret", "", 400, "", ""},
		{"/storage/images", "", 404, "", ""},
	} {
		t.Run(tc.path+tc.rangeHeader, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, tc.path, nil)
			req.Header.Set("Origin", origin)
			if tc.rangeHeader != "" {
				req.Header.Set("Range", tc.rangeHeader)
			}
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, req)
			if w.Code != tc.status || w.Header().Get("Content-Range") != tc.contentRange {
				t.Fatalf("status %d range %q", w.Code, w.Header().Get("Content-Range"))
			}
			if (tc.status == 206 || tc.status == 416) && (w.Header().Get("Access-Control-Allow-Origin") != origin ||
				!strings.Contains(w.Header().Get("Access-Control-Expose-Headers"), "Content-Range,Accept-Ranges")) {
				t.Fatalf("range CORS headers: %v", w.Header())
			}
			if tc.body != "" && w.Body.String() != tc.body {
				t.Fatalf("body %q", w.Body.String())
			}
			if tc.status == 200 && w.Header().Get("X-Content-Type-Options") != "nosniff" {
				t.Fatal("missing nosniff")
			}
		})
	}
	head := httptest.NewRecorder()
	handler.ServeHTTP(head, httptest.NewRequest(http.MethodHead, "/storage/Private/file.txt", nil))
	if head.Code != 404 || head.Header().Get("ETag") != "" {
		t.Fatalf("reserved HEAD: status %d, headers %v", head.Code, head.Header())
	}
	head = httptest.NewRecorder()
	headRequest := httptest.NewRequest(http.MethodHead, "/storage/images/cat.png", nil)
	headRequest.Header.Set("Range", "bytes=999-")
	handler.ServeHTTP(head, headRequest)
	if head.Code != 200 || head.Header().Get("Content-Length") != "10" ||
		head.Header().Get("Content-Type") != "image/png" || head.Header().Get("Content-Range") != "" ||
		head.Header().Get("Accept-Ranges") != "bytes" || head.Body.Len() != 0 {
		t.Fatalf("HEAD: status %d, headers %v, body length %d", head.Code, head.Header(), head.Body.Len())
	}
	if err := os.Symlink(filepath.Join(root, "images"), filepath.Join(root, "link")); err == nil {
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, httptest.NewRequest("GET", "/storage/link/cat.png", nil))
		if w.Code != 404 {
			t.Fatalf("symlink returned %d", w.Code)
		}
	} else {
		t.Logf("symlink test unavailable: %v", err)
	}
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, httptest.NewRequest("GET", "/storage/default-avatar.png", nil))
	if w.Code != 200 || w.Header().Get("Content-Type") != "image/png" || w.Body.Len() == 0 {
		t.Fatal("default avatar fallback failed")
	}
	if _, err := png.Decode(bytes.NewReader(w.Body.Bytes())); err != nil {
		t.Fatalf("default avatar must be a decodable PNG: %v", err)
	}
	head = httptest.NewRecorder()
	handler.ServeHTTP(head, httptest.NewRequest(http.MethodHead, "/storage/default-avatar.png", nil))
	if head.Code != 200 || head.Header().Get("Content-Length") != w.Header().Get("Content-Length") || head.Body.Len() != 0 {
		t.Fatal("default avatar HEAD metadata mismatch")
	}
}

func TestPublicReadWithInvalidS3Configuration(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "posts"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "posts", "existing.txt"), []byte("must stay local"), 0600); err != nil {
		t.Fatal(err)
	}
	config := localStorageConfig(func(key string) (string, bool) {
		switch key {
		case "STORAGE_TYPE":
			return "s3", true
		case "STORAGE_PATH":
			return root, true
		default:
			return "", false
		}
	})
	handler := NewHandlerWithConfig(nil, nil, CorsPolicy{}, RefreshConfig{LocalStorage: config})
	for _, method := range []string{http.MethodGet, http.MethodHead} {
		for path, status := range map[string]int{
			"/storage/posts/existing.txt":  503,
			"/storage/avatars/current.png": 503,
			"/storage/posts/CON.txt":       400,
			"/storage/Private/hidden.txt":  404,
			"/storage/temp/hidden.txt":     404,
			"/storage/images/cat.png":      404,
			"/storage/default-avatar.png":  200,
		} {
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, httptest.NewRequest(method, path, nil))
			if w.Code != status || strings.Contains(w.Body.String(), "must stay local") {
				t.Fatalf("%s %s: status %d, body %q", method, path, w.Code, w.Body.String())
			}
		}
	}
}

func TestLocalStorageConfiguration(t *testing.T) {
	env := map[string]string{"STORAGE_PATH": " first ", "STORAGE_ROOT_DIR": "second", "STORAGE_TYPE": "s3"}
	c := localStorageConfig(func(k string) (string, bool) { v, ok := env[k]; return v, ok })
	if c.Root != "first" || !c.Unsupported {
		t.Fatal(c)
	}
	w := httptest.NewRecorder()
	serveLocalStorage(w, httptest.NewRequest("GET", "/storage/posts/a", nil), c)
	if w.Code != http.StatusServiceUnavailable || strings.Contains(w.Body.String(), "first") {
		t.Fatal(w.Code, w.Body.String())
	}
}
