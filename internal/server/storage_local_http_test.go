package server

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

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
	handler := NewHandlerWithConfig(nil, nil, CorsPolicy{}, RefreshConfig{LocalStorage: LocalStorageConfig{Root: root}})
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
		{"/storage/%2e%2e/secret", "", 400, "", ""},
		{"/storage/images", "", 404, "", ""},
	} {
		t.Run(tc.path+tc.rangeHeader, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, tc.path, nil)
			if tc.rangeHeader != "" {
				req.Header.Set("Range", tc.rangeHeader)
			}
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, req)
			if w.Code != tc.status || w.Header().Get("Content-Range") != tc.contentRange {
				t.Fatalf("status %d range %q", w.Code, w.Header().Get("Content-Range"))
			}
			if tc.body != "" && w.Body.String() != tc.body {
				t.Fatalf("body %q", w.Body.String())
			}
			if tc.status == 200 && w.Header().Get("X-Content-Type-Options") != "nosniff" {
				t.Fatal("missing nosniff")
			}
		})
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
}

func TestLocalStorageConfiguration(t *testing.T) {
	env := map[string]string{"STORAGE_PATH": " first ", "STORAGE_ROOT_DIR": "second", "STORAGE_TYPE": "s3"}
	c := localStorageConfig(func(k string) (string, bool) { v, ok := env[k]; return v, ok })
	if c.Root != "first" || !c.Unsupported {
		t.Fatal(c)
	}
	w := httptest.NewRecorder()
	serveLocalStorage(w, httptest.NewRequest("GET", "/storage/a", nil), c)
	if w.Code != 501 || strings.Contains(w.Body.String(), "first") {
		t.Fatal(w.Code, w.Body.String())
	}
}
