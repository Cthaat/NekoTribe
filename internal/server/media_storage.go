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
	return saveMediaObjectWithIdentity(ctx, m, config, key, nil)
}

type mediaObjectIdentity struct {
	file *os.File
	info os.FileInfo
}

func publishRouteMedia(ctx context.Context, media *mediaMultipart, config LocalStorageConfig, key, mime string) (cleanup func() error, release func(), err error) {
	if config.s3 != nil {
		if err := config.s3.put(ctx, media, key, mime); err != nil {
			return nil, nil, err
		}
		return func() error { return config.s3.delete(context.WithoutCancel(ctx), key) }, func() {}, nil
	}
	var identity *mediaObjectIdentity
	if err := saveMediaObjectWithIdentity(ctx, media, config, key, &identity); err != nil {
		return nil, nil, err
	}
	return func() error { return cleanupPublishedMedia(media, key, identity) }, func() {
		if identity != nil && identity.file.Close() != nil {
			log.Print("media upload object handle close unavailable")
		}
	}, nil
}

func saveMediaObjectWithIdentity(ctx context.Context, m *mediaMultipart, config LocalStorageConfig, key string, identity **mediaObjectIdentity) error {
	if config.Unsupported || m == nil || m.closed || m.root == nil || m.temp == nil || m.request == nil || m.directory == "" {
		return errMediaStorage
	}
	key, err := normalizeLocalFileKey(key)
	if err != nil || !(strings.HasPrefix(key, "posts/") || strings.HasPrefix(key, "avatars/") || isPrivateStorageKey(key)) {
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
	var pinned *os.File
	if identity != nil {
		pinned, err = m.request.Open(stage)
		if err != nil {
			return errMediaStorage
		}
		pinnedInfo, statErr := pinned.Stat()
		if statErr != nil || !os.SameFile(created, pinnedInfo) {
			_ = pinned.Close()
			return errMediaStorage
		}
	}
	if err := m.root.Link(stagedPath, filepath.FromSlash(key)); err != nil {
		if pinned != nil {
			_ = pinned.Close()
		}
		return err
	}
	if identity != nil {
		*identity = &mediaObjectIdentity{file: pinned, info: created}
	}
	return nil
}

// Remove only the inode created by this request after a confirmed rollback.
func cleanupPublishedMedia(m *mediaMultipart, key string, identity *mediaObjectIdentity) error {
	if m == nil || m.closed || m.root == nil || identity == nil || identity.file == nil || identity.info == nil {
		return errMediaStorage
	}
	key, err := normalizeLocalFileKey(key)
	if err != nil || !(strings.HasPrefix(key, "posts/") || strings.HasPrefix(key, "avatars/") || isPrivateStorageKey(key)) {
		return errMediaStorage
	}
	parts := strings.Split(key, "/")
	for i := range parts {
		current, err := m.root.Lstat(filepath.Join(parts[:i+1]...))
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return errMediaStorage
		}
		if current.Mode()&os.ModeSymlink != 0 || (i < len(parts)-1 && !current.IsDir()) {
			return errMediaStorage
		}
		if i == len(parts)-1 && (!current.Mode().IsRegular() || !os.SameFile(identity.info, current)) {
			return errMediaStorage
		}
	}
	if err := m.root.Remove(filepath.FromSlash(key)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return errMediaStorage
	}
	return nil
}
