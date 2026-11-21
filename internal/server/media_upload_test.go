package server

import (
	"bytes"
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"image"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
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

func TestMediaUploadRealTailIndexedMP4(t *testing.T) {
	binaryPath, fixturePath := os.Getenv("NEKO_TEST_FFPROBE"), os.Getenv("NEKO_TEST_TAIL_MP4")
	if binaryPath == "" || fixturePath == "" {
		t.Skip("requires NEKO_TEST_FFPROBE and NEKO_TEST_TAIL_MP4 (640x360, 2 seconds)")
	}
	t.Setenv("FFPROBE_PATH", binaryPath)
	video, err := os.ReadFile(fixturePath)
	if err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	store := &mediaUploadFixture{memorySessions: store()}
	body, typ := multipartFixture(t, []partFixture{{"file", "video.mp4", string(video)}})
	req := httptest.NewRequest("POST", "/api/v2/media", body)
	req.Header.Set("Content-Type", typ)
	req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
	w := httptest.NewRecorder()
	NewHandlerWithConfig(codec, store, CorsPolicy{}, RefreshConfig{LocalStorage: LocalStorageConfig{Root: t.TempDir()}}).ServeHTTP(w, req)
	input := store.input
	if w.Code != 200 || input.MIMEType != "video/mp4" || input.Width == nil || *input.Width != 640 || input.Height == nil || *input.Height != 360 || input.Duration == nil || *input.Duration != 2 {
		t.Fatal(w.Code, input, w.Body.String())
	}
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

func (s *mediaUploadIntegratedFixture) CheckPrivateMediaUploadSchema(ctx context.Context) error {
	return (OracleSessions{s.db}).CheckPrivateMediaUploadSchema(ctx)
}

func TestPrivateMediaUploadRoute(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		name, mode, wantScope string
		scopes                []string
		status                int
		publish               bool
	}{
		{"chat", "success", "chat", []string{"chat"}, 200, true},
		{"first text scope", "success", "post", []string{"post", "public"}, 200, true},
		{"legacy pre-T19", "pre-t19", "", nil, 200, true},
		{"explicit public pre-T19", "pre-t19", "", []string{"public", "chat"}, 200, true},
		{"missing schema", "pre-t19", "chat", []string{"chat"}, 503, false},
		{"schema disappears before insert", "schema-race", "chat", []string{"chat"}, 503, false},
		{"invalid scope", "success", "", []string{"Chat"}, 400, false},
		{"invalid scope without file", "success", "", []string{"Chat"}, 400, false},
		{"blank scope", "success", "", []string{"", "post"}, 400, false},
		{"confirmed rollback", "insert", "chat", []string{"chat"}, 500, false},
		{"uncertain rollback", "rollback", "post", []string{"post"}, 500, true},
		{"uncertain commit", "commit", "post", []string{"post"}, 500, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			state := &mediaUploadDBState{mode: tc.mode}
			db := sql.OpenDB(mediaUploadConnector{state})
			defer db.Close()
			store := &mediaUploadIntegratedFixture{memorySessions: store(), db: db, mode: tc.mode}
			parts := []partFixture{{"file", "note.txt", "hello"}}
			if tc.name == "invalid scope without file" {
				parts = nil
			}
			for _, scope := range tc.scopes {
				parts = append(parts, partFixture{"access_scope", "", scope})
			}
			body, contentType := multipartFixture(t, parts)
			req := httptest.NewRequest("POST", "/api/v2/media", body)
			req.Header.Set("Content-Type", contentType)
			req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			w := httptest.NewRecorder()
			policy := StorageURLPolicy{invalidPublicBase: tc.wantScope != ""}
			NewHandlerWithConfig(codec, store, CorsPolicy{}, RefreshConfig{LocalStorage: LocalStorageConfig{Root: root}, Storage: policy}).ServeHTTP(w, req)
			if w.Code != tc.status || strings.Contains(w.Body.String(), "private column diagnostic") {
				t.Fatal(w.Code, w.Body.String())
			}
			var insert listQueryCall
			for _, call := range state.calls {
				if strings.HasPrefix(call.sql, "INSERT INTO n_media_assets") {
					insert = call
				}
			}
			if tc.status == 400 && (len(state.calls) != 0 || !strings.Contains(w.Body.String(), "媒体访问范围无效")) {
				t.Fatal(state.calls, w.Body.String())
			}
			if tc.status == 503 {
				if !strings.Contains(w.Body.String(), "媒体存储暂不可用") ||
					(tc.mode == "pre-t19" && (len(state.calls) != 1 || insert.sql != "")) ||
					(tc.mode == "schema-race" && (state.rollbacks != 1 || insert.sql == "")) {
					t.Fatal(state.calls, w.Body.String())
				}
			}
			if tc.wantScope != "" && (len(state.calls) == 0 || state.calls[0].sql != "SELECT access_scope FROM n_media_assets WHERE 1=0") {
				t.Fatal(state.calls)
			}
			if tc.status == 200 && tc.wantScope == "" && (len(state.calls) == 0 || !strings.Contains(state.calls[0].sql, "seq_media_id")) {
				t.Fatal(state.calls)
			}
			if insert.sql != "" {
				values := map[string]driver.Value{}
				for _, arg := range insert.args {
					values[arg.Name] = arg.Value
				}
				if tc.wantScope == "" {
					if strings.Contains(insert.sql, "access_scope") || !strings.HasPrefix(values["storage_key"].(string), "posts/files/42/") {
						t.Fatal(insert)
					}
				} else if !strings.Contains(insert.sql, "access_scope") || values["access_scope"] != tc.wantScope ||
					!strings.HasPrefix(values["storage_key"].(string), "private/"+tc.wantScope+"/files/42/") ||
					values["public_url"] != "/api/v2/media/99/content" || values["thumbnail_url"] != nil {
					t.Fatal(insert)
				}
				if tc.status == 200 && tc.wantScope != "" &&
					(!strings.Contains(w.Body.String(), "\"public_url\":\"/api/v2/media/99/content\"") ||
						strings.Contains(w.Body.String(), values["storage_key"].(string)) || !strings.Contains(w.Body.String(), "\"thumbnail_url\":null")) {
					t.Fatal(w.Body.String())
				}
			} else if tc.status == 200 {
				t.Fatal("missing insert")
			}
			var files int
			if err := filepath.WalkDir(root, func(_ string, d os.DirEntry, err error) error {
				if err == nil && !d.IsDir() {
					files++
				}
				return err
			}); err != nil || (tc.publish && files != 1) || (!tc.publish && files != 0) {
				t.Fatal(files, err)
			}
		})
	}
}

func TestDedicatedPrivateMediaUploadRoute(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		name, method string
		scopes       []string
		status       int
	}{
		{"chat", "POST", []string{"chat"}, 200},
		{"post", "POST", []string{"post", "public"}, 200},
		{"missing", "POST", nil, 400},
		{"public", "POST", []string{"public", "post"}, 400},
		{"blank", "POST", []string{""}, 400},
		{"invalid", "POST", []string{"CHAT"}, 400},
		{"no session", "POST", []string{"chat"}, 401},
		{"schema", "POST", []string{"chat"}, 503},
		{"other method", "DELETE", []string{"chat"}, 405},
		{"preflight", "OPTIONS", nil, 204},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			state := &mediaUploadDBState{}
			if tc.name == "schema" {
				state.mode = "pre-t19"
			}
			db := sql.OpenDB(mediaUploadConnector{state})
			defer db.Close()
			store := &mediaUploadIntegratedFixture{memorySessions: store(), db: db}
			parts := []partFixture{}
			if tc.name != "missing" {
				parts = append(parts, partFixture{"file", "note.txt", "hello"})
			}
			for _, scope := range tc.scopes {
				parts = append(parts, partFixture{"access_scope", "", scope})
			}
			body, contentType := multipartFixture(t, parts)
			req := httptest.NewRequest(tc.method, "/api/v2/media/private", body)
			req.Header.Set("Content-Type", contentType)
			if tc.name != "no session" {
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			}
			req.Header.Set("Origin", "https://example.test")
			if tc.method == http.MethodOptions {
				req.Header.Set("Access-Control-Request-Method", "POST")
				req.Header.Set("Access-Control-Request-Headers", "authorization,content-type")
			}
			w := httptest.NewRecorder()
			NewHandlerWithConfig(codec, store, CorsPolicy{Origins: []string{"https://example.test"}}, RefreshConfig{LocalStorage: LocalStorageConfig{Root: root}}).ServeHTTP(w, req)
			if w.Code != tc.status {
				t.Fatal(w.Code, w.Body.String())
			}
			if tc.status == 200 && (len(state.calls) == 0 || state.commits != 1 ||
				!strings.Contains(w.Body.String(), "\"public_url\":\"/api/v2/media/99/content\"")) {
				t.Fatal(state.calls, state.commits, w.Body.String())
			}
			if tc.status == 400 && (len(state.calls) != 0 || !strings.Contains(w.Body.String(), "媒体访问范围无效")) {
				t.Fatal(state.calls, w.Body.String())
			}
			if tc.status == 503 && (len(state.calls) != 1 || !strings.Contains(w.Body.String(), "媒体存储暂不可用")) {
				t.Fatal(state.calls, w.Body.String())
			}
			if tc.status == 405 && w.Header().Get("Allow") != "POST, OPTIONS" {
				t.Fatal(w.Header())
			}
			if tc.status != 200 {
				for _, prefix := range []string{"private", "posts"} {
					_, err := os.Stat(filepath.Join(root, prefix))
					if !errors.Is(err, os.ErrNotExist) {
						t.Fatal(prefix, err)
					}
				}
			}
		})
	}
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
			if w.Code != http.StatusServiceUnavailable || store.calls != 0 {
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

type uploadDeadlineRecorder struct {
	*httptest.ResponseRecorder
	read, write time.Time
}

func (w *uploadDeadlineRecorder) SetReadDeadline(deadline time.Time) error {
	w.read = deadline
	return nil
}

func (w *uploadDeadlineRecorder) SetWriteDeadline(deadline time.Time) error {
	w.write = deadline
	return nil
}

func TestMediaUploadAuthenticatesAndRejectsInvalidInput(t *testing.T) {
	codec, tokens := fixture(t)
	root := t.TempDir()
	store := &mediaUploadFixture{memorySessions: store()}
	h := NewHandlerWithConfig(codec, store, CorsPolicy{}, RefreshConfig{LocalStorage: LocalStorageConfig{Root: root}})
	r := httptest.NewRequest("POST", "/api/v2/media", strings.NewReader("ignored"))
	r.Header.Set("Content-Type", "application/json")
	w := &uploadDeadlineRecorder{ResponseRecorder: httptest.NewRecorder()}
	h.ServeHTTP(w, r)
	if w.Code != 401 || store.calls != 0 || !w.read.IsZero() || !w.write.IsZero() {
		t.Fatal(w.Code, store.calls)
	}
	if _, err := os.Stat(filepath.Join(root, "temp")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("unauthenticated created temp", err)
	}
	r = httptest.NewRequest("POST", "/api/v2/media", strings.NewReader("ignored"))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
	w = &uploadDeadlineRecorder{ResponseRecorder: httptest.NewRecorder()}
	h.ServeHTTP(w, r)
	if w.Code != 400 || store.calls != 0 || !w.read.IsZero() || !w.write.IsZero() {
		t.Fatal(w.Code, store.calls)
	}
	body, typ := multipartFixture(t, []partFixture{{"file", "fake.txt", string([]byte{0x4d, 0x5a, 0x90, 0x00, 0x03, 0, 0, 0})}})
	r = httptest.NewRequest("POST", "/api/v2/media", body)
	r.Header.Set("Content-Type", typ)
	r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
	w = &uploadDeadlineRecorder{ResponseRecorder: httptest.NewRecorder()}
	started := time.Now()
	h.ServeHTTP(w, r)
	if w.Code != 400 || store.calls != 0 {
		t.Fatal(w.Code, store.calls, w.Body.String())
	}
	if w.read.Before(started.Add(mediaUploadBodyTimeout)) ||
		w.write.Sub(w.read) != mediaUploadResponseGrace {
		t.Fatal("authorized multipart upload did not receive bounded deadlines")
	}
}

func TestMediaUploadMetadataByteLimits(t *testing.T) {
	codec, tokens := fixture(t)
	for _, tc := range []struct {
		name, alt, description string
		status, calls          int
	}{
		{"exact bound", strings.Repeat("猫", 166) + "ab", strings.Repeat("猫", 333) + "a", 200, 1},
		{"alt overflow", strings.Repeat("猫", 167), "", 400, 0},
		{"description overflow", "", strings.Repeat("猫", 334), 400, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			repository := &mediaUploadFixture{memorySessions: store()}
			body, typ := multipartFixture(t, []partFixture{
				{"file", "note.txt", "hello"}, {"alt_text", "", tc.alt}, {"description", "", tc.description},
			})
			req := httptest.NewRequest(http.MethodPost, "/api/v2/media", body)
			req.Header.Set("Content-Type", typ)
			req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			w := httptest.NewRecorder()
			NewHandlerWithConfig(codec, repository, CorsPolicy{}, RefreshConfig{LocalStorage: LocalStorageConfig{Root: root}}).ServeHTTP(w, req)
			if w.Code != tc.status || repository.calls != tc.calls {
				t.Fatal(w.Code, w.Body.String(), repository.calls)
			}
			if tc.calls == 0 {
				if !strings.Contains(w.Body.String(), "媒体替代文本或描述过长") {
					t.Fatal(w.Body.String())
				}
				if _, err := os.Stat(filepath.Join(root, "posts")); !errors.Is(err, os.ErrNotExist) {
					t.Fatal("metadata rejection created a public object", err)
				}
			} else if repository.input.AltText != tc.alt || repository.input.Description != tc.description {
				t.Fatal("metadata changed before writing")
			}
			if entries, err := os.ReadDir(filepath.Join(root, "temp")); err != nil || len(entries) != 0 {
				t.Fatal("temporary files left", entries, err)
			}
		})
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
