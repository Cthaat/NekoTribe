package server

import (
	"bytes"
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/hex"
	"encoding/json"
	"mime"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/textproto"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

type avatarFixture struct {
	*memorySessions
	db    *sql.DB
	input mediaUploadInput
}

func (s *avatarFixture) ReplaceUserAvatar(ctx context.Context, input mediaUploadInput) (int64, bool, error) {
	s.input = input
	return (OracleSessions{s.db}).ReplaceUserAvatar(ctx, input)
}

func TestUserAvatarSharedRoutes(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/user-avatar.json")
	if err != nil {
		t.Fatal(err)
	}
	var spec struct {
		Cases []struct {
			ID, Extension, MIME, Fault string
			Status                     int
			Parts                      []struct {
				Field, Name, Hex string
				ContentType      *string
				Size             int
			}
		}
	}
	if err := json.Unmarshal(raw, &spec); err != nil {
		t.Fatal(err)
	}
	codec, tokens := fixture(t)
	for _, tc := range spec.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			root := t.TempDir()
			old := filepath.Join(root, "old-avatar.png")
			if err := os.WriteFile(old, []byte("old"), 0600); err != nil {
				t.Fatal(err)
			}
			state := &resetTransactionState{claim: 1, user: 1}
			state.queryRows = map[string]driver.Value{avatarContract.SQL["lock"]: int64(42), avatarContract.SQL["next"]: int64(12)}
			if tc.Fault == "rollback" {
				state.failAt = 2
			}
			if tc.Fault == "commit" {
				state.fail = "commit"
			}
			db := sql.OpenDB(resetTransactionConnector{state})
			defer db.Close()
			repository := &avatarFixture{memorySessions: store(), db: db}
			var body bytes.Buffer
			multipartBody := multipart.NewWriter(&body)
			for _, p := range tc.Parts {
				content, err := hex.DecodeString(p.Hex)
				if err != nil {
					t.Fatal(err)
				}
				if p.Size > len(content) {
					content = append(content, make([]byte, p.Size-len(content))...)
				}
				params := map[string]string{"name": p.Field}
				if p.Name != "" {
					params["filename"] = p.Name
				}
				header := textproto.MIMEHeader{}
				header.Set("Content-Disposition", mime.FormatMediaType("form-data", params))
				contentType := "image/png"
				if p.ContentType != nil {
					contentType = *p.ContentType
				}
				if contentType != "" {
					header.Set("Content-Type", contentType)
				}
				part, err := multipartBody.CreatePart(header)
				if err != nil {
					t.Fatal(err)
				}
				if _, err = part.Write(content); err != nil {
					t.Fatal(err)
				}
			}
			if err := multipartBody.Close(); err != nil {
				t.Fatal(err)
			}
			req := httptest.NewRequest(http.MethodPut, "/api/v2/users/me/avatar?user_id=99", &body)
			if tc.Status != 401 {
				req.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
			}
			req.Header.Set("Content-Type", multipartBody.FormDataContentType())
			res := httptest.NewRecorder()
			storage := LocalStorageConfig{Root: root, Unsupported: tc.Fault == "storage-config"}
			NewHandlerWithConfig(codec, repository, CorsPolicy{}, RefreshConfig{LocalStorage: storage}).ServeHTTP(res, req)
			if res.Code != tc.Status || res.Header().Get("Cache-Control") != "private, no-store" ||
				strings.Contains(res.Body.String(), "private detail") {
				t.Fatal(res.Code, res.Body.String())
			}
			if storage.Unsupported {
				if !strings.Contains(res.Body.String(), `"code":50301`) ||
					!strings.Contains(res.Body.String(), "媒体存储暂不可用") {
					t.Fatal(res.Body.String())
				}
				if _, err := os.Stat(filepath.Join(root, "temp")); !os.IsNotExist(err) {
					t.Fatal("unavailable storage created a temporary directory", err)
				}
			}
			if tc.Extension == "" {
				if repository.input.Key != "" || len(state.queries) != 0 {
					t.Fatal("invalid upload reached storage")
				}
			} else {
				input := repository.input
				if input.UserID != 42 || input.MIMEType != tc.MIME || !strings.HasPrefix(input.Key, "avatars/42/") ||
					!strings.HasSuffix(input.Key, tc.Extension) {
					t.Fatal(input)
				}
				if !slices.Equal(state.queries, []string{avatarContract.SQL["insert"], avatarContract.SQL["update"]}) {
					t.Fatal(state.queries)
				}
				_, statErr := os.Stat(filepath.Join(root, filepath.FromSlash(input.Key)))
				if tc.Fault == "rollback" {
					if !os.IsNotExist(statErr) || state.commits != 0 || state.rollbacks != 1 {
						t.Fatal("rollback did not clean up")
					}
				} else if statErr != nil || state.commits != 1 {
					t.Fatal("committed or unknown object missing")
				}
				if tc.Status == 200 && !strings.Contains(res.Body.String(), `"avatar_media_id":12`) {
					t.Fatal(res.Body.String())
				}
			}
			if _, err := os.Stat(old); err != nil {
				t.Fatal(err)
			}
			items, err := os.ReadDir(filepath.Join(root, "temp"))
			if err != nil && !os.IsNotExist(err) || len(items) != 0 {
				t.Fatal("temporary file leak", err, items)
			}
		})
	}
}
