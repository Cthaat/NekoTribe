package server

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

var errMediaStorage = errors.New("media storage unavailable")

func newMediaObjectKey(user int64, mediaType, extension string, now time.Time) (string, error) {
	if user <= 0 {
		return "", errMediaStorage
	}
	bucket := ""
	switch mediaType {
	case "image", "gif":
		bucket = "images"
	case "video":
		bucket = "videos"
	case "audio":
		bucket = "audio"
	case "file":
		bucket = "files"
	default:
		return "", errMediaStorage
	}
	extension = strings.ToLower(extension)
	if len(extension) < 2 || len(extension) > 17 || extension[0] != '.' {
		return "", errMediaStorage
	}
	for _, c := range extension[1:] {
		if !(c >= 'a' && c <= 'z') && !(c >= '0' && c <= '9') {
			return "", errMediaStorage
		}
	}
	id, err := randomUUID()
	if err != nil {
		return "", errMediaStorage
	}
	now = now.UTC()
	key := fmt.Sprintf("posts/%s/%s/%04d/%02d/%s%s", bucket, strconv.FormatInt(user, 10), now.Year(), now.Month(), id, extension)
	if _, err := normalizeLocalFileKey(key); err != nil {
		return "", errMediaStorage
	}
	return key, nil
}

type mediaContextReader struct {
	ctx    context.Context
	source io.Reader
}

func (r mediaContextReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.source.Read(p)
}

// A key is generated server-side, never from the client filename. The source is
// request-owned and stays available until the caller finishes its transaction.
func saveMediaObject(ctx context.Context, m *mediaMultipart, config LocalStorageConfig, key string) error {
	if config.Unsupported || m == nil || m.closed || m.root == nil || m.temp == nil || m.request == nil || m.directory == "" {
		return errMediaStorage
	}
	key, err := normalizeLocalFileKey(key)
	if err != nil || !strings.HasPrefix(key, "posts/") {
		return errMediaStorage
	}
	rootPath := config.Root
	if rootPath == "" {
		rootPath = "./storage"
	}
	configured, err := os.Stat(rootPath)
	if err != nil {
		return errMediaStorage
	}
	opened, err := m.root.Stat(".")
	if err != nil || !os.SameFile(configured, opened) {
		return errMediaStorage
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	source, err := m.OpenSelected()
	if err != nil {
		return errMediaStorage
	}
	defer source.Close()
	info, err := source.Stat()
	if err != nil || !info.Mode().IsRegular() || m.Selected.Size <= 0 || info.Size() != m.Selected.Size {
		return errMediaStorage
	}
	parts := strings.Split(key, "/")
	for i := 0; i < len(parts)-1; i++ {
		name := filepath.Join(parts[:i+1]...)
		if err := m.root.Mkdir(name, 0755); err != nil && !errors.Is(err, os.ErrExist) {
			return errMediaStorage
		}
		info, err := m.root.Lstat(name)
		if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return errMediaStorage
		}
	}
	id, err := randomUUID()
	if err != nil {
		return errMediaStorage
	}
	stage := "publish-" + id
	destination, err := m.request.OpenFile(stage, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	m.files = append(m.files, stage)
	defer func() {
		if e := m.request.Remove(stage); e != nil && !errors.Is(e, os.ErrNotExist) {
			log.Print("media upload temporary cleanup unavailable")
		}
	}()
	created, statErr := destination.Stat()
	if statErr != nil {
		_ = destination.Close()
		return errMediaStorage
	}
	n, copyErr := io.CopyBuffer(destination, mediaContextReader{ctx: ctx, source: io.LimitReader(source, m.Selected.Size+1)}, make([]byte, 64<<10))
	modeErr := destination.Chmod(0644)
	closeErr := destination.Close()
	if copyErr != nil || modeErr != nil || closeErr != nil || n != m.Selected.Size || ctx.Err() != nil {
		return errMediaStorage
	}
	// Ensure path-based publication still refers to the private directory and
	// staged inode opened above. Root.Link fails rather than copying across
	// filesystems or overwriting an existing destination.
	for _, pair := range []struct {
		path string
		root *os.Root
	}{
		{"temp", m.temp}, {filepath.Join("temp", m.directory), m.request},
	} {
		current, e := m.root.Lstat(pair.path)
		opened, openErr := pair.root.Stat(".")
		if e != nil || openErr != nil || !current.IsDir() || current.Mode()&os.ModeSymlink != 0 || !os.SameFile(current, opened) {
			return errMediaStorage
		}
	}
	stagedPath := filepath.Join("temp", m.directory, stage)
	current, err := m.root.Lstat(stagedPath)
	if err != nil || !current.Mode().IsRegular() || !os.SameFile(created, current) {
		return errMediaStorage
	}
	if err := ctx.Err(); err != nil {
		return errMediaStorage
	}
	return m.root.Link(stagedPath, filepath.FromSlash(key))
}
