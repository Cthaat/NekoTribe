package server

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"image"
	"image/png"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type mediaUploadFixture struct {
	*memorySessions
	mode  string
	input mediaUploadInput
	calls int
}

func oneSecondWAV() []byte {
	wav := make([]byte, 44+16000)
	copy(wav, "RIFF")
	binary.LittleEndian.PutUint32(wav[4:], 16036)
	copy(wav[8:], "WAVEfmt ")
	binary.LittleEndian.PutUint32(wav[16:], 16)
	binary.LittleEndian.PutUint16(wav[20:], 1)
	binary.LittleEndian.PutUint16(wav[22:], 1)
	binary.LittleEndian.PutUint32(wav[24:], 8000)
	binary.LittleEndian.PutUint32(wav[28:], 16000)
	binary.LittleEndian.PutUint16(wav[32:], 2)
	binary.LittleEndian.PutUint16(wav[34:], 16)
	copy(wav[36:], "data")
	binary.LittleEndian.PutUint32(wav[40:], 16000)
	return wav
}

func TestMediaUploadRealWAV(t *testing.T) {
	binaryPath := os.Getenv("NEKO_TEST_FFPROBE")
	if binaryPath == "" {
		t.Skip("requires NEKO_TEST_FFPROBE")
	}
	verifyWAVUpload(t, binaryPath)
}

func TestMediaUploadWAVWithoutFFprobe(t *testing.T) {
	verifyWAVUpload(t, "nekotribe-nonexistent-ffprobe")
}

func verifyWAVUpload(t *testing.T, binaryPath string) {
	t.Helper()
	t.Setenv("FFPROBE_PATH", binaryPath)
	wav := oneSecondWAV()
	codec, tokens := fixture(t)
	store := &mediaUploadFixture{memorySessions: store()}
	body, typ := multipartFixture(t, []partFixture{{"file", "a.wav", string(wav)}})
	req := httptest.NewRequest("POST", "/api/v2/media", body)
	req.Header.Set("Content-Type", typ)
	req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
	w := httptest.NewRecorder()
	NewHandlerWithConfig(codec, store, CorsPolicy{}, RefreshConfig{LocalStorage: LocalStorageConfig{Root: t.TempDir()}}).ServeHTTP(w, req)
	if w.Code != 200 || store.input.MIMEType != "audio/wav" || store.input.Duration == nil || *store.input.Duration != 1 {
		t.Fatal(w.Code, store.input, w.Body.String())
	}
}

type mediaUploadIntegratedFixture struct {
	*memorySessions
	db   *sql.DB
	mode string
}

func (s *mediaUploadIntegratedFixture) CreateMediaAtomic(ctx context.Context, input mediaUploadInput, policy StorageURLPolicy) (mediaUploadResult, error) {
	return (OracleSessions{s.db}).createMediaAtomic(ctx, input, policy, func(context.Context, *sql.Conn) error {
		if s.mode == "schema" {
			return errMediaSchema
		}
		return nil
	})
}

func TestMediaUploadRouteWithTransactionAndFilesystem(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		mode   string
		status int
		object bool
	}{{"success", 200, true}, {"insert", 500, false}, {"rollback", 500, true}, {"commit", 500, true}, {"schema", 503, false}} {
		t.Run(tc.mode, func(t *testing.T) {
			root := t.TempDir()
			state := &mediaUploadDBState{mode: tc.mode}
			db := sql.OpenDB(mediaUploadConnector{state})
			defer db.Close()
			store := &mediaUploadIntegratedFixture{memorySessions: store(), db: db, mode: tc.mode}
			body, typ := multipartFixture(t, []partFixture{{"file", "note.txt", "hello"}})
			req := httptest.NewRequest("POST", "/api/v2/media", body)
			req.Header.Set("Content-Type", typ)
			req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			w := httptest.NewRecorder()
			NewHandlerWithConfig(codec, store, CorsPolicy{}, RefreshConfig{LocalStorage: LocalStorageConfig{Root: root}}).ServeHTTP(w, req)
			if w.Code != tc.status {
				t.Fatal(w.Code, w.Body.String())
			}
			var key string
			for _, call := range state.calls {
				if strings.HasPrefix(call.sql, "INSERT INTO n_media_assets") {
					for _, arg := range call.args {
						if arg.Name == "storage_key" {
							key, _ = arg.Value.(string)
						}
					}
				}
			}
			if key == "" && tc.mode != "schema" {
				t.Fatal("missing insert binding")
			}
			var found int
			_ = filepath.WalkDir(filepath.Join(root, "posts"), func(_ string, d os.DirEntry, err error) error {
				if err == nil && !d.IsDir() {
					found++
				}
				return nil
			})
			if (found == 1) != tc.object {
				t.Fatal("unexpected final object count", found, key)
			}
			entries, err := os.ReadDir(filepath.Join(root, "temp"))
			if err != nil || len(entries) != 0 {
				t.Fatal(entries, err)
			}
		})
	}
}

func TestMediaUploadImageMetadataAndUnavailableStorage(t *testing.T) {
	codec, tokens := fixture(t)
	var picture bytes.Buffer
	if err := png.Encode(&picture, image.NewRGBA(image.Rect(0, 0, 2, 3))); err != nil {
		t.Fatal(err)
	}
	for _, unsupported := range []bool{false, true} {
		root := t.TempDir()
		store := &mediaUploadFixture{memorySessions: store()}
		body, typ := multipartFixture(t, []partFixture{{"file", "wrong.txt", picture.String()}})
		req := httptest.NewRequest("POST", "/api/v2/media", body)
		req.Header.Set("Content-Type", typ)
		req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		w := httptest.NewRecorder()
		NewHandlerWithConfig(codec, store, CorsPolicy{}, RefreshConfig{LocalStorage: LocalStorageConfig{Root: root, Unsupported: unsupported}}).ServeHTTP(w, req)
		if unsupported {
			if w.Code != 501 || store.calls != 0 {
				t.Fatal(w.Code, store.calls)
			}
			continue
		}
		if w.Code != 200 || store.calls != 1 || store.input.MIMEType != "image/png" || store.input.Width == nil || *store.input.Width != 2 || store.input.Height == nil || *store.input.Height != 3 {
			t.Fatal(w.Code, store.input, w.Body.String())
		}
	}
}

func TestMediaUploadWebPDimensions(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		name, content string
		width, height float64
	}{
		{"lossy", "UklGRjAAAABXRUJQVlA4ICQAAABwAQCdASoHAAUAAUAmJYwCdAFAAAD+8sp8CStWbpYcm1zEAAA=", 7, 5},
		{"lossless", "UklGRh4AAABXRUJQVlA4TBEAAAAvCgACEAdQlFKUp2aBiOh/AAA=", 11, 9},
	} {
		t.Run(tc.name, func(t *testing.T) {
			data, err := base64.StdEncoding.DecodeString(tc.content)
			if err != nil {
				t.Fatal(err)
			}
			store := &mediaUploadFixture{memorySessions: store()}
			body, typ := multipartFixture(t, []partFixture{{"file", "image.webp", string(data)}})
			req := httptest.NewRequest("POST", "/api/v2/media", body)
			req.Header.Set("Content-Type", typ)
			req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			w := httptest.NewRecorder()
			NewHandlerWithConfig(codec, store, CorsPolicy{}, RefreshConfig{LocalStorage: LocalStorageConfig{Root: t.TempDir()}}).ServeHTTP(w, req)
			if w.Code != 200 || store.calls != 1 || store.input.MIMEType != "image/webp" || store.input.Width == nil || *store.input.Width != tc.width || store.input.Height == nil || *store.input.Height != tc.height {
				t.Fatal(w.Code, store.input, w.Body.String())
			}
		})
	}
}

func (s *mediaUploadFixture) CreateMediaAtomic(_ context.Context, input mediaUploadInput, _ StorageURLPolicy) (mediaUploadResult, error) {
	s.calls++
	s.input = input
	switch s.mode {
	case "rollback":
		return mediaUploadResult{CleanupSafe: true}, errors.New("private database detail")
	case "unknown":
		return mediaUploadResult{CleanupSafe: false}, errors.New("private commit detail")
	case "schema":
		return mediaUploadResult{CleanupSafe: true}, errMediaSchema
	}
	return mediaUploadResult{Media: PostMedia{MediaID: 99, MediaType: input.MediaType, FileName: input.FileName, PublicURL: input.PublicURL, FileSize: input.Size, MIMEType: input.MIMEType, Status: "ready"}}, nil
}

func TestMediaUploadRouteLifecycle(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		mode   string
		status int
		object bool
	}{{"success", 200, true}, {"rollback", 500, false}, {"unknown", 500, true}, {"schema", 503, false}} {
		t.Run(tc.mode, func(t *testing.T) {
			root := t.TempDir()
			store := &mediaUploadFixture{memorySessions: store(), mode: tc.mode}
			body, typ := multipartFixture(t, []partFixture{{"file", "note.txt", "hello"}, {"alt_text", "", "alt"}})
			req := httptest.NewRequest("POST", "/api/v2/media", body)
			req.Header.Set("Content-Type", typ)
			req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			w := httptest.NewRecorder()
			NewHandlerWithConfig(codec, store, CorsPolicy{}, RefreshConfig{LocalStorage: LocalStorageConfig{Root: root}}).ServeHTTP(w, req)
			if w.Code != tc.status || store.calls != 1 || w.Header().Get("Cache-Control") != "private, no-store" || strings.Contains(w.Body.String(), "private") {
				t.Fatal(w.Code, w.Body.String(), store.calls)
			}
			if store.input.UserID != 42 || store.input.FileName != "note.txt" || store.input.AltText != "alt" || store.input.MIMEType != "text/plain" || !strings.HasPrefix(store.input.Key, "posts/files/42/") {
				t.Fatal(store.input)
			}
			object := filepath.Join(root, filepath.FromSlash(store.input.Key))
			data, err := os.ReadFile(object)
			if (err == nil) != tc.object || (tc.object && string(data) != "hello") {
				t.Fatal("unexpected file", err)
			}
			entries, err := os.ReadDir(filepath.Join(root, "temp"))
			if err != nil || len(entries) != 0 {
				t.Fatal("temporary files left", entries, err)
			}
			if tc.status == 200 {
				var response struct {
					Code    int
					Message string
					Data    PostMedia
				}
				if err = json.Unmarshal(w.Body.Bytes(), &response); err != nil || response.Code != 200 || response.Message != "media uploaded" || response.Data.MediaID != 99 {
					t.Fatal(response, err)
				}
			}
		})
	}
}

func TestMediaUploadAuthenticatesAndRejectsInvalidInput(t *testing.T) {
	codec, tokens := fixture(t)
	root := t.TempDir()
	store := &mediaUploadFixture{memorySessions: store()}
	h := NewHandlerWithConfig(codec, store, CorsPolicy{}, RefreshConfig{LocalStorage: LocalStorageConfig{Root: root}})
	r := httptest.NewRequest("POST", "/api/v2/media", strings.NewReader("ignored"))
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 401 || store.calls != 0 {
		t.Fatal(w.Code, store.calls)
	}
	if _, err := os.Stat(filepath.Join(root, "temp")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("unauthenticated created temp", err)
	}
	r = httptest.NewRequest("POST", "/api/v2/media", strings.NewReader("ignored"))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
	w = httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 400 || store.calls != 0 {
		t.Fatal(w.Code, store.calls)
	}
	body, typ := multipartFixture(t, []partFixture{{"file", "fake.txt", string([]byte{0x4d, 0x5a, 0x90, 0x00, 0x03, 0, 0, 0})}})
	r = httptest.NewRequest("POST", "/api/v2/media", body)
	r.Header.Set("Content-Type", typ)
	r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
	w = httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 400 || store.calls != 0 {
		t.Fatal(w.Code, store.calls, w.Body.String())
	}
}

func TestMediaUploadMalformedMultipartLeavesNoTemporaryFiles(t *testing.T) {
	codec, tokens := fixture(t)
	for _, missing := range []bool{false, true} {
		root := t.TempDir()
		store := &mediaUploadFixture{memorySessions: store()}
		parts := []partFixture{{"file", "a.txt", "hello"}}
		if missing {
			parts = []partFixture{{"description", "", "hello"}}
		}
		body, typ := multipartFixture(t, parts)
		data := body.Bytes()
		if !missing {
			data = data[:len(data)-8]
		}
		req := httptest.NewRequest("POST", "/api/v2/media", bytes.NewReader(data))
		req.Header.Set("Content-Type", typ)
		req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		w := httptest.NewRecorder()
		NewHandlerWithConfig(codec, store, CorsPolicy{}, RefreshConfig{LocalStorage: LocalStorageConfig{Root: root}}).ServeHTTP(w, req)
		if w.Code != 400 || store.calls != 0 {
			t.Fatal(w.Code, store.calls, w.Body.String())
		}
		if missing && !strings.Contains(w.Body.String(), "上传文件为空") {
			t.Fatal(w.Body.String())
		}
		entries, err := os.ReadDir(filepath.Join(root, "temp"))
		if err != nil || len(entries) != 0 {
			t.Fatal(entries, err)
		}
	}
}
