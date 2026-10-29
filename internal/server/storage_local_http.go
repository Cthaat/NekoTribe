package server

import (
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type LocalStorageConfig struct {
	Root        string
	Unsupported bool
}

func localStorageConfig(lookup func(string) (string, bool)) LocalStorageConfig {
	get := func(key string) string { v, _ := lookup(key); return strings.TrimSpace(v) }
	root := get("STORAGE_PATH")
	if root == "" {
		root = get("STORAGE_ROOT_DIR")
	}
	if root == "" {
		root = "./storage"
	}
	return LocalStorageConfig{Root: root, Unsupported: get("STORAGE_TYPE") == "s3"}
}

var localMIME = map[string]string{
	".7z": "application/x-7z-compressed", ".csv": "text/csv", ".doc": "application/msword", ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
	".gif": "image/gif", ".gz": "application/gzip", ".jpeg": "image/jpeg", ".jpg": "image/jpeg", ".json": "application/json", ".md": "text/markdown",
	".mp3": "audio/mpeg", ".mp4": "video/mp4", ".odp": "application/vnd.oasis.opendocument.presentation", ".ods": "application/vnd.oasis.opendocument.spreadsheet", ".odt": "application/vnd.oasis.opendocument.text",
	".ogg": "audio/ogg", ".pdf": "application/pdf", ".png": "image/png", ".ppt": "application/vnd.ms-powerpoint", ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
	".rar": "application/vnd.rar", ".rtf": "application/rtf", ".tar": "application/x-tar", ".tsv": "text/tab-separated-values", ".txt": "text/plain", ".wav": "audio/wav", ".webm": "video/webm",
	".xls": "application/vnd.ms-excel", ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", ".xml": "application/xml", ".zip": "application/zip",
}

const defaultAvatar = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAQAAAAAYLlVAAAACXBIWXMAAAsTAAALEwEAmpwYAAAAiklEQVR4nO3XwQmAMBAEwTn77y6doC3YgGCWoJcQecBqYSkAAAAAAAAAAAAAAGBc2q7r+7y7e0T7Yx5smN1vyXodD9bK7q7I0cxdMM9wPZz8x0y2H2Y9nLxj5mx1dbrYqX5cJ8eVnqE7x1B8hTn7gk3f4g0AAAAAAAAAAAAAAIB3bQF6rA1Xj2GmQAAAAABJRU5ErkJggg=="

func serveLocalStorage(w http.ResponseWriter, r *http.Request, config LocalStorageConfig) {
	if config.Unsupported {
		http.Error(w, "Storage provider not implemented", http.StatusNotImplemented)
		return
	}
	key, err := normalizeLocalFileKey(strings.TrimPrefix(r.URL.Path, "/storage/"))
	if err != nil {
		http.Error(w, "Invalid storage path", http.StatusBadRequest)
		return
	}
	if strings.EqualFold(strings.SplitN(key, "/", 2)[0], "temp") {
		http.NotFound(w, r)
		return
	}
	rootPath := config.Root
	if rootPath == "" {
		rootPath = "./storage"
	}
	root, err := os.OpenRoot(rootPath)
	if err != nil {
		storageReadError(w, r, key, err)
		return
	}
	defer root.Close()
	parts := strings.Split(key, "/")
	for i := range parts {
		info, err := root.Lstat(filepath.Join(parts[:i+1]...))
		if err != nil {
			storageReadError(w, r, key, err)
			return
		}
		if info.Mode()&os.ModeSymlink != 0 || (i < len(parts)-1 && !info.IsDir()) {
			http.NotFound(w, r)
			return
		}
		if i == len(parts)-1 && !info.Mode().IsRegular() {
			http.NotFound(w, r)
			return
		}
	}
	file, err := root.Open(filepath.FromSlash(key))
	if err != nil {
		storageReadError(w, r, key, err)
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		http.Error(w, "Internal Server Error", 500)
		return
	}
	if !info.Mode().IsRegular() {
		http.NotFound(w, r)
		return
	}
	size := uint64(info.Size())
	byteRange, err := parseLocalByteRange(r.Header.Get("Range"), size)
	if err != nil {
		w.Header().Set("Content-Range", fmt.Sprintf("bytes */%d", size))
		http.Error(w, "Invalid range header", 416)
		return
	}
	mimeType := localMIME[strings.ToLower(path.Ext(key))]
	if mimeType == "" {
		mimeType = "application/octet-stream"
	}
	h := w.Header()
	h.Set("Content-Type", mimeType)
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Accept-Ranges", "bytes")
	h.Set("Cache-Control", "public, max-age=31536000, immutable")
	h.Set("Last-Modified", info.ModTime().UTC().Format(http.TimeFormat))
	millis := float64(info.ModTime().UnixNano()) / float64(time.Millisecond)
	h.Set("ETag", fmt.Sprintf("\"%d-%s\"", size, strconv.FormatFloat(millis, 'f', -1, 64)))
	length := size
	if byteRange != nil {
		length = byteRange.End - byteRange.Start + 1
		h.Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", byteRange.Start, byteRange.End, size))
	}
	h.Set("Content-Length", strconv.FormatUint(length, 10))
	if byteRange != nil {
		w.WriteHeader(http.StatusPartialContent)
		_, _ = io.CopyN(w, io.NewSectionReader(file, int64(byteRange.Start), int64(length)), int64(length))
		return
	}
	_, _ = io.CopyN(w, file, int64(length))
}

func storageReadError(w http.ResponseWriter, r *http.Request, key string, err error) {
	if errors.Is(err, os.ErrNotExist) {
		if key == "default-avatar.png" {
			data, _ := base64.StdEncoding.DecodeString(defaultAvatar)
			w.Header().Set("Content-Type", "image/png")
			w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
			w.Header().Set("Content-Length", strconv.Itoa(len(data)))
			_, _ = w.Write(data)
			return
		}
		http.NotFound(w, r)
		return
	}
	http.Error(w, "Internal Server Error", 500)
}
