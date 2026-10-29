package server

import (
	"bytes"
	"mime/multipart"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type partFixture struct{ field, name, value string }

func multipartFixture(t *testing.T, parts []partFixture) (*bytes.Buffer, string) {
	t.Helper()
	var b bytes.Buffer
	w := multipart.NewWriter(&b)
	for _, p := range parts {
		var err error
		var target interface{ Write([]byte) (int, error) }
		if p.name != "" {
			target, err = w.CreateFormFile(p.field, p.name)
		} else {
			target, err = w.CreateFormField(p.field)
		}
		if err != nil {
			t.Fatal(err)
		}
		if _, err = target.Write([]byte(p.value)); err != nil {
			t.Fatal(err)
		}
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return &b, w.FormDataContentType()
}

func TestMediaMultipartSelectionAndCleanup(t *testing.T) {
	root := t.TempDir()
	temp := filepath.Join(root, "temp")
	if err := os.Mkdir(temp, 0700); err != nil {
		t.Fatal(err)
	}
	sentinel := filepath.Join(temp, "other-request")
	if err := os.WriteFile(sentinel, []byte("preserve"), 0600); err != nil {
		t.Fatal(err)
	}
	body, contentType := multipartFixture(t, []partFixture{{"media", "old.txt", "old"}, {"alt_text", "", "first"}, {"alt_text", "", "second"}, {"file", "chosen.txt", "chosen"}, {"file", "ignored.txt", "ignored"}, {"description", "", "description"}})
	r := httptest.NewRequest("POST", "/api/v2/media", body)
	r.Header.Set("Content-Type", contentType)
	result, err := parseMediaMultipart(r, LocalStorageConfig{Root: root}, mediaMultipartLimits{fileBytes: 64, totalBytes: 128, fieldBytes: 64, fields: 20, files: 20})
	if err != nil {
		t.Fatal(err)
	}
	if result.Selected.Name != "chosen.txt" || result.Selected.Size != 6 || result.AltText != "first" || result.Description != "description" {
		t.Fatal(result.Selected, result.AltText, result.Description)
	}
	f, err := result.OpenSelected()
	if err != nil {
		t.Fatal(err)
	}
	data := make([]byte, 6)
	if _, err = f.Read(data); err != nil {
		t.Fatal(err)
	}
	_ = f.Close()
	if string(data) != "chosen" {
		t.Fatal(string(data))
	}
	if err := result.Close(); err != nil {
		t.Fatal(err)
	}
	if err := result.Close(); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(temp)
	if err != nil || len(entries) != 1 || entries[0].Name() != "other-request" {
		t.Fatal(entries, err)
	}
	if data, err := os.ReadFile(sentinel); err != nil || string(data) != "preserve" {
		t.Fatal(err)
	}
}

func TestMediaMultipartFailuresAreBoundedAndClean(t *testing.T) {
	for _, tc := range []struct {
		name   string
		parts  []partFixture
		limits mediaMultipartLimits
		typ    string
	}{
		{"wrong type", nil, mediaMultipartLimits{}, "application/json"},
		{"missing file", []partFixture{{"description", "", "text"}}, mediaMultipartLimits{fileBytes: 10, totalBytes: 10, fieldBytes: 10, fields: 2, files: 2}, ""},
		{"file too large", []partFixture{{"file", "a.txt", strings.Repeat("a", 11)}}, mediaMultipartLimits{fileBytes: 10, totalBytes: 20, fieldBytes: 10, fields: 2, files: 2}, ""},
		{"combined too large", []partFixture{{"file", "a.txt", "123456"}, {"ignored", "b.txt", "12345"}}, mediaMultipartLimits{fileBytes: 10, totalBytes: 10, fieldBytes: 10, fields: 2, files: 2}, ""},
		{"fields too large", []partFixture{{"description", "", strings.Repeat("x", 11)}}, mediaMultipartLimits{fileBytes: 10, totalBytes: 10, fieldBytes: 10, fields: 2, files: 2}, ""},
		{"too many files", []partFixture{{"file", "a.txt", "1"}, {"file", "b.txt", "2"}}, mediaMultipartLimits{fileBytes: 10, totalBytes: 10, fieldBytes: 10, fields: 2, files: 1}, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			body, contentType := multipartFixture(t, tc.parts)
			if tc.typ != "" {
				contentType = tc.typ
			}
			r := httptest.NewRequest("POST", "/api/v2/media", body)
			r.Header.Set("Content-Type", contentType)
			if result, err := parseMediaMultipart(r, LocalStorageConfig{Root: root}, tc.limits); err == nil {
				_ = result.Close()
				t.Fatal("invalid request accepted")
			}
			entries, err := os.ReadDir(filepath.Join(root, "temp"))
			if err != nil && !os.IsNotExist(err) {
				t.Fatal(err)
			}
			if len(entries) != 0 {
				t.Fatal("request temp left behind", entries)
			}
		})
	}
}

func TestMediaMultipartRequestIsolationAndMediaFallback(t *testing.T) {
	root := t.TempDir()
	limits := mediaMultipartLimits{fileBytes: 64, totalBytes: 128, fieldBytes: 64, fields: 20, files: 20}
	newRequest := func(value string) *mediaMultipart {
		body, contentType := multipartFixture(t, []partFixture{{"media", "a.txt", value}})
		r := httptest.NewRequest("POST", "/api/v2/media", body)
		r.Header.Set("Content-Type", contentType)
		result, err := parseMediaMultipart(r, LocalStorageConfig{Root: root}, limits)
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	first, second := newRequest("first"), newRequest("second")
	if first.directory == second.directory || first.Selected.Name != "a.txt" {
		t.Fatal("request directories were reused")
	}
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}
	f, err := second.OpenSelected()
	if err != nil {
		t.Fatal(err)
	}
	data := make([]byte, 6)
	if _, err = f.Read(data); err != nil {
		t.Fatal(err)
	}
	_ = f.Close()
	if string(data) != "second" {
		t.Fatal(string(data))
	}
	if err := second.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestMediaMultipartTruncatedBodyAndLinkedTemp(t *testing.T) {
	limits := mediaMultipartLimits{fileBytes: 64, totalBytes: 128, fieldBytes: 64, fields: 20, files: 20}
	root := t.TempDir()
	body, contentType := multipartFixture(t, []partFixture{{"file", "a.txt", "body"}})
	r := httptest.NewRequest("POST", "/api/v2/media", bytes.NewReader(body.Bytes()[:body.Len()-8]))
	r.Header.Set("Content-Type", contentType)
	if m, err := parseMediaMultipart(r, LocalStorageConfig{Root: root}, limits); err == nil {
		_ = m.Close()
		t.Fatal("truncated body accepted")
	}
	entries, err := os.ReadDir(filepath.Join(root, "temp"))
	if err != nil || len(entries) != 0 {
		t.Fatal(entries, err)
	}
	otherRoot := t.TempDir()
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(otherRoot, "temp")); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	body, contentType = multipartFixture(t, []partFixture{{"file", "a.txt", "body"}})
	r = httptest.NewRequest("POST", "/api/v2/media", body)
	r.Header.Set("Content-Type", contentType)
	if m, err := parseMediaMultipart(r, LocalStorageConfig{Root: otherRoot}, limits); err == nil {
		_ = m.Close()
		t.Fatal("linked temp accepted")
	}
	entries, err = os.ReadDir(outside)
	if err != nil || len(entries) != 0 {
		t.Fatal("outside directory modified", err)
	}
}
