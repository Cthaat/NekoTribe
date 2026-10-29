package server

import (
	"context"
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func mediaStoredFixture(t *testing.T, root string) *mediaMultipart {
	t.Helper()
	body, contentType := multipartFixture(t, []partFixture{{"file", "source.txt", "source-content"}})
	r := httptest.NewRequest("POST", "/api/v2/media", body)
	r.Header.Set("Content-Type", contentType)
	m, err := parseMediaMultipart(r, LocalStorageConfig{Root: root}, mediaMultipartLimits{fileBytes: 100, totalBytes: 100, fieldBytes: 100, fields: 5, files: 5})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := m.Close(); err != nil {
			t.Error(err)
		}
	})
	return m
}

func TestMediaStorageWritesWithoutOverwriting(t *testing.T) {
	root := t.TempDir()
	m := mediaStoredFixture(t, root)
	key := "posts/files/42/2026/10/item.txt"
	if err := saveMediaObject(context.Background(), m, LocalStorageConfig{Root: root}, key); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(root, filepath.FromSlash(key))
	data, err := os.ReadFile(target)
	if err != nil || string(data) != "source-content" {
		t.Fatal(string(data), err)
	}
	if err := saveMediaObject(context.Background(), m, LocalStorageConfig{Root: root}, key); !errors.Is(err, os.ErrExist) {
		t.Fatal("collision accepted", err)
	}
	data, err = os.ReadFile(target)
	if err != nil || string(data) != "source-content" {
		t.Fatal("original changed", err)
	}
	entries, err := os.ReadDir(filepath.Join(root, "temp", m.directory))
	if err != nil || len(entries) != 1 || entries[0].Name() != "part-1" {
		t.Fatal("staged files left after publication or collision", entries, err)
	}
}

func TestMediaStorageRejectsUnsafePathsAndCleansPartialCopies(t *testing.T) {
	root := t.TempDir()
	m := mediaStoredFixture(t, root)
	for _, key := range []string{"../escape", "temp/other", "posts/../escape"} {
		if err := saveMediaObject(context.Background(), m, LocalStorageConfig{Root: root}, key); err == nil {
			t.Fatal("accepted", key)
		}
	}
	if err := saveMediaObject(context.Background(), m, LocalStorageConfig{Root: root, Unsupported: true}, "posts/a.txt"); err == nil {
		t.Fatal("S3 fell back")
	}
	if err := saveMediaObject(context.Background(), m, LocalStorageConfig{Root: t.TempDir()}, "posts/a.txt"); err == nil {
		t.Fatal("accepted a different configured storage root")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := saveMediaObject(ctx, m, LocalStorageConfig{Root: root}, "posts/cancel.txt"); err == nil {
		t.Fatal("cancel ignored")
	}
	if _, err := os.Stat(filepath.Join(root, "posts", "cancel.txt")); !os.IsNotExist(err) {
		t.Fatal("cancelled object remains", err)
	}
	m.Selected.Size++
	if err := saveMediaObject(context.Background(), m, LocalStorageConfig{Root: root}, "posts/partial.txt"); err == nil {
		t.Fatal("truncated source accepted")
	}
	if _, err := os.Stat(filepath.Join(root, "posts", "partial.txt")); !os.IsNotExist(err) {
		t.Fatal("partial object remains", err)
	}
}

func TestMediaStorageRejectsLinkedParent(t *testing.T) {
	root := t.TempDir()
	m := mediaStoredFixture(t, root)
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "posts")); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	if err := saveMediaObject(context.Background(), m, LocalStorageConfig{Root: root}, "posts/file.txt"); err == nil {
		t.Fatal("linked parent accepted")
	}
	entries, err := os.ReadDir(outside)
	if err != nil || len(entries) != 0 {
		t.Fatal("outside changed", err)
	}
}

func TestMediaCleanupNeverDeletesReplacement(t *testing.T) {
	root := t.TempDir()
	m := mediaStoredFixture(t, root)
	key := "posts/files/42/object.txt"
	var identity *mediaObjectIdentity
	if err := saveMediaObjectWithIdentity(context.Background(), m, LocalStorageConfig{Root: root}, key, &identity); err != nil {
		t.Fatal(err)
	}
	defer identity.file.Close()
	file := filepath.Join(root, filepath.FromSlash(key))
	if err := os.Remove(file); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, []byte("replacement"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := cleanupPublishedMedia(m, key, identity); err == nil {
		t.Fatal("replacement treated as owned")
	}
	data, err := os.ReadFile(file)
	if err != nil || string(data) != "replacement" {
		t.Fatal("replacement removed", err)
	}
}

type mediaCancelAfterRead struct {
	context.Context
	checks int
}

type mediaVisibilityProbe struct {
	context.Context
	target   string
	observed bool
	checks   int
}

func (p *mediaVisibilityProbe) Err() error {
	p.checks++
	if _, err := os.Lstat(p.target); err == nil {
		p.observed = true
	}
	return nil
}

func TestMediaStoragePublishesOnlyAfterCopyCompletes(t *testing.T) {
	root := t.TempDir()
	body, contentType := multipartFixture(t, []partFixture{{"file", "source.txt", strings.Repeat("x", 256<<10)}})
	r := httptest.NewRequest("POST", "/api/v2/media", body)
	r.Header.Set("Content-Type", contentType)
	m, err := parseMediaMultipart(r, LocalStorageConfig{Root: root}, mediaMultipartLimits{fileBytes: 300 << 10, totalBytes: 300 << 10, fieldBytes: 100, fields: 5, files: 5})
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	target := filepath.Join(root, "posts", "complete.txt")
	probe := &mediaVisibilityProbe{Context: context.Background(), target: target}
	if err := saveMediaObject(probe, m, LocalStorageConfig{Root: root}, "posts/complete.txt"); err != nil {
		t.Fatal(err)
	}
	if probe.checks < 3 || probe.observed {
		t.Fatal("target became visible while copy was in progress", probe.checks, probe.observed)
	}
	info, err := os.Stat(target)
	if err != nil || info.Size() != 256<<10 {
		t.Fatal(info, err)
	}
}

func (c *mediaCancelAfterRead) Err() error {
	c.checks++
	if c.checks >= 3 {
		return context.Canceled
	}
	return nil
}

func TestMediaStorageRemovesPartialFileWhenCopyIsCancelled(t *testing.T) {
	root := t.TempDir()
	body, contentType := multipartFixture(t, []partFixture{{"file", "source.txt", strings.Repeat("x", 256<<10)}})
	r := httptest.NewRequest("POST", "/api/v2/media", body)
	r.Header.Set("Content-Type", contentType)
	m, err := parseMediaMultipart(r, LocalStorageConfig{Root: root}, mediaMultipartLimits{fileBytes: 300 << 10, totalBytes: 300 << 10, fieldBytes: 100, fields: 5, files: 5})
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	ctx := &mediaCancelAfterRead{Context: context.Background()}
	if err := saveMediaObject(ctx, m, LocalStorageConfig{Root: root}, "posts/cancelled.txt"); err == nil {
		t.Fatal("cancelled copy succeeded")
	}
	if ctx.checks < 3 {
		t.Fatal("copy did not start")
	}
	if _, err := os.Stat(filepath.Join(root, "posts", "cancelled.txt")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("partial file remains", err)
	}
	f, err := m.OpenSelected()
	if err != nil {
		t.Fatal("source disappeared", err)
	}
	_ = f.Close()
}

func TestMediaObjectKeyUsesUserDateAndSafeExtension(t *testing.T) {
	when := time.Date(2026, 11, 1, 0, 30, 0, 0, time.FixedZone("local", 8*3600))
	key, err := newMediaObjectKey(42, "image", ".PNG", when)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(key, "posts/images/42/2026/10/") || !strings.HasSuffix(key, ".png") {
		t.Fatal(key)
	}
	for _, bad := range []string{"../x", ".png/other", ".png.", ".p ng"} {
		if _, err := newMediaObjectKey(42, "image", bad, when); err == nil {
			t.Fatal("accepted", bad)
		}
	}
}
