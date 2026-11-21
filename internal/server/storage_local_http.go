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
	s3          *s3Storage
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
	config := LocalStorageConfig{Root: root}
	if get("STORAGE_TYPE") == "s3" {
		config.s3 = configuredS3(get)
		config.Unsupported = config.s3 == nil
	}
	return config
}

var localMIME = map[string]string{
	".avif": "image/avif", ".webp": "image/webp",
	".oga": "audio/ogg", ".opus": "audio/ogg", ".spx": "audio/ogg",
	".ogm": "video/ogg", ".ogv": "video/ogg",
	".7z": "application/x-7z-compressed", ".csv": "text/csv", ".doc": "application/msword", ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
	".gif": "image/gif", ".gz": "application/gzip", ".jpeg": "image/jpeg", ".jpg": "image/jpeg", ".json": "application/json", ".md": "text/markdown",
	".mp3": "audio/mpeg", ".mp4": "video/mp4", ".odp": "application/vnd.oasis.opendocument.presentation", ".ods": "application/vnd.oasis.opendocument.spreadsheet", ".odt": "application/vnd.oasis.opendocument.text",
	".ogg": "audio/ogg", ".pdf": "application/pdf", ".png": "image/png", ".ppt": "application/vnd.ms-powerpoint", ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
	".rar": "application/vnd.rar", ".rtf": "application/rtf", ".tar": "application/x-tar", ".tsv": "text/tab-separated-values", ".txt": "text/plain", ".wav": "audio/wav", ".webm": "video/webm",
	".xls": "application/vnd.ms-excel", ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", ".xml": "application/xml", ".zip": "application/zip",
}

const defaultAvatar = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAA/UlEQVR42u2YOw4CMQxENyOuyg2oKai5AbejouQI9FCQOJOf8lyuVva8OJE/6fl6HyubjsUNAAAAAAAAAJa2UyO/t/vj68v1cm4RKNl7oV/pTTHUU33ODyMBMsV5GdRZvZ1B/dV7GagDFWdpSQIZAAAAAMLtjaUvIgPRs3S1pbYMFAkyNtXOK5QpyzsSmN/AX3H2gSY12k4vPFJSyAA49tkLucbCmvcdfMT27UgYQ5OoD7vVJOrDzjWP+lgITaU+EGibOtDt+EvDUYkBAGATgEbzVH24na5QtyQUBdKQbZQxhEZt1FzONWop63JbtVZZeKSkkAEAAAAAADCHfQBIWmGUrvIeKwAAAABJRU5ErkJggg=="

func retiredStorageRoute(w http.ResponseWriter, r *http.Request) bool {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		return false
	}
	requested := r.URL.EscapedPath()
	prefix, suffix, found := strings.Cut(strings.TrimPrefix(requested, "/"), "/")
	if !found || suffix == "" || (prefix != "upload" && prefix != "uploads") {
		return false
	}
	w.Header().Set("Cache-Control", "no-store")
	if r.Method == http.MethodHead {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusGone)
		return true
	}
	respond(w, http.StatusGone, http.StatusGone,
		"Legacy /"+prefix+" path removed. Public files are served from /storage.",
		map[string]string{"requested_path": requested, "storage_base": "/storage"})
	return true
}

func serveLocalStorage(w http.ResponseWriter, r *http.Request, config LocalStorageConfig) {
	key, err := normalizeLocalFileKey(strings.TrimPrefix(r.URL.Path, "/storage/"))
	if err != nil {
		http.Error(w, "Invalid storage path", http.StatusBadRequest)
		return
	}
	prefix, _, _ := strings.Cut(key, "/")
	if strings.EqualFold(prefix, "temp") || strings.EqualFold(prefix, "private") {
		http.NotFound(w, r)
		return
	}
	if config.Unsupported {
		if _, managed := s3ManagedKey(key); !managed {
			storageReadError(w, r, key, os.ErrNotExist, false)
			return
		}
		storageHTTPError(w, false, http.StatusServiceUnavailable, "Storage unavailable")
		return
	}
	serveStorageObject(w, r, config, key, false)
}

func serveStorageObject(w http.ResponseWriter, r *http.Request, config LocalStorageConfig, key string, private bool) {
	if config.s3 != nil {
		config.s3.serve(w, r, key, private)
		return
	}
	rootPath := config.Root
	if rootPath == "" {
		rootPath = "./storage"
	}
	root, err := os.OpenRoot(rootPath)
	if err != nil {
		storageReadError(w, r, key, err, private)
		return
	}
	defer root.Close()
	parts := strings.Split(key, "/")
	for i := range parts {
		info, err := root.Lstat(filepath.Join(parts[:i+1]...))
		if err != nil {
			storageReadError(w, r, key, err, private)
			return
		}
		if info.Mode()&os.ModeSymlink != 0 || (i < len(parts)-1 && !info.IsDir()) {
			storageHTTPError(w, private, http.StatusNotFound, "404 page not found")
			return
		}
		if i == len(parts)-1 && !info.Mode().IsRegular() {
			storageHTTPError(w, private, http.StatusNotFound, "404 page not found")
			return
		}
	}
	file, err := root.Open(filepath.FromSlash(key))
	if err != nil {
		storageReadError(w, r, key, err, private)
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		storageHTTPError(w, private, http.StatusInternalServerError, "Internal Server Error")
		return
	}
	if !info.Mode().IsRegular() {
		storageHTTPError(w, private, http.StatusNotFound, "404 page not found")
		return
	}
	size := uint64(info.Size())
	rangeHeader := ""
	if r.Method != http.MethodHead {
		rangeHeader = r.Header.Get("Range")
	}
	byteRange, err := parseLocalByteRange(rangeHeader, size)
	if err != nil {
		w.Header().Set("Content-Range", fmt.Sprintf("bytes */%d", size))
		storageHTTPError(w, private, http.StatusRequestedRangeNotSatisfiable, "Invalid range header")
		return
	}
	h := w.Header()
	setStorageReadHeaders(h, key, private)
	h.Set("Last-Modified", info.ModTime().UTC().Format(http.TimeFormat))
	millis := float64(info.ModTime().UnixNano()) / float64(time.Millisecond)
	h.Set("ETag", fmt.Sprintf("\"%d-%s\"", size, strconv.FormatFloat(millis, 'f', -1, 64)))
	length := size
	if byteRange != nil {
		length = byteRange.End - byteRange.Start + 1
		h.Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", byteRange.Start, byteRange.End, size))
	}
	h.Set("Content-Length", strconv.FormatUint(length, 10))
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	if byteRange != nil {
		w.WriteHeader(http.StatusPartialContent)
		_, _ = io.CopyN(w, io.NewSectionReader(file, int64(byteRange.Start), int64(length)), int64(length))
		return
	}
	_, _ = io.CopyN(w, file, int64(length))
}

func setStorageReadHeaders(h http.Header, key string, private bool) {
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Accept-Ranges", "bytes")
	if private {
		h.Set("Content-Type", "application/octet-stream")
		h.Set("Content-Disposition", "attachment")
		h.Set("Cache-Control", "private, no-store")
		return
	}
	base := path.Base(key)
	extension := path.Ext(base)
	if extension == base {
		extension = ""
	}
	mimeType := localMIME[strings.ToLower(extension)]
	if mimeType == "" {
		mimeType = "application/octet-stream"
	}
	h.Set("Content-Type", mimeType)
	h.Set("Cache-Control", "public, max-age=31536000, immutable")
}

func storageHTTPError(w http.ResponseWriter, private bool, status int, publicMessage string) {
	if private {
		respondPrivateMediaError(w, status)
		return
	}
	http.Error(w, publicMessage, status)
}

func storageReadError(w http.ResponseWriter, r *http.Request, key string, err error, private bool) {
	if errors.Is(err, os.ErrNotExist) {
		if !private && key == "default-avatar.png" {
			data, _ := base64.StdEncoding.DecodeString(defaultAvatar)
			w.Header().Set("Content-Type", "image/png")
			w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
			w.Header().Set("Content-Length", strconv.Itoa(len(data)))
			if r.Method == http.MethodHead {
				w.WriteHeader(http.StatusOK)
			} else {
				_, _ = w.Write(data)
			}
			return
		}
		storageHTTPError(w, private, http.StatusNotFound, "404 page not found")
		return
	}
	storageHTTPError(w, private, http.StatusInternalServerError, "Internal Server Error")
}
