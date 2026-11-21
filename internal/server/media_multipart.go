package server

import (
	"errors"
	"fmt"
	"io"
	"log"
	"mime"
	"net/http"
	"os"
	"strings"
)

var errMediaMultipart = errors.New("invalid media upload")
var errMediaNoFile = errors.New("media upload missing file")
var errMediaAccessScope = errors.New("invalid media access scope")

type mediaMultipartLimits struct {
	fileBytes, totalBytes, fieldBytes int64
	fields, files                     int
}

var defaultMediaMultipartLimits = mediaMultipartLimits{fileBytes: 500 << 20, totalBytes: 500 << 20, fieldBytes: 20 << 20, fields: 1000, files: 1000}

type mediaTempFile struct {
	Name, MIME, path string
	Size             int64
}
type mediaMultipart struct {
	Selected             mediaTempFile
	AltText, Description string
	AccessScope          string
	root, temp, request  *os.Root
	directory            string
	files                []string
	closed               bool
}

// Close removes only files created by this request and its own empty directory.
func (m *mediaMultipart) Close() error {
	if m.closed {
		return nil
	}
	m.closed = true
	var result error
	if m.request != nil {
		for _, name := range m.files {
			if err := m.request.Remove(name); err != nil && !errors.Is(err, os.ErrNotExist) {
				result = err
			}
		}
		if err := m.request.Close(); err != nil {
			result = err
		}
	}
	if m.temp != nil {
		if m.directory != "" {
			if err := m.temp.Remove(m.directory); err != nil && !errors.Is(err, os.ErrNotExist) {
				result = err
			}
		}
		if err := m.temp.Close(); err != nil {
			result = err
		}
	}
	if m.root != nil {
		if err := m.root.Close(); err != nil {
			result = err
		}
	}
	return result
}

func (m *mediaMultipart) OpenSelected() (*os.File, error) {
	if m.closed || m.request == nil || m.Selected.path == "" {
		return nil, errMediaMultipart
	}
	return m.request.Open(m.Selected.path)
}

func parseMediaMultipart(r *http.Request, config LocalStorageConfig, limits mediaMultipartLimits) (_ *mediaMultipart, err error) {
	return parseMediaMultipartWithAlias(r, config, limits, "media")
}

func parseMediaMultipartWithAlias(r *http.Request, config LocalStorageConfig, limits mediaMultipartLimits, alias string) (*mediaMultipart, error) {
	return parseMediaMultipartRequest(r, config, limits, alias, false)
}

func parseMediaMultipartRequest(r *http.Request, config LocalStorageConfig, limits mediaMultipartLimits, alias string, requirePrivate bool) (_ *mediaMultipart, err error) {
	contentType, params, e := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if e != nil || !strings.EqualFold(contentType, "multipart/form-data") || params["boundary"] == "" {
		return nil, errMediaMultipart
	}
	if limits.fileBytes <= 0 || limits.totalBytes <= 0 || limits.fieldBytes <= 0 || limits.fields <= 0 || limits.files <= 0 {
		return nil, errMediaMultipart
	}
	reader, e := r.MultipartReader()
	if e != nil {
		return nil, errMediaMultipart
	}
	rootPath := config.Root
	if rootPath == "" {
		rootPath = "./storage"
	}
	if e = os.MkdirAll(rootPath, 0700); e != nil {
		return nil, e
	}
	m := &mediaMultipart{}
	defer func() {
		if err != nil {
			if m.Close() != nil {
				log.Print("media upload temporary cleanup unavailable")
			}
		}
	}()
	m.root, e = os.OpenRoot(rootPath)
	if e != nil {
		return nil, e
	}
	if e = m.root.Mkdir("temp", 0700); e != nil && !errors.Is(e, os.ErrExist) {
		return nil, e
	}
	info, e := m.root.Lstat("temp")
	if e != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return nil, errMediaStorage
	}
	m.temp, e = m.root.OpenRoot("temp")
	if e != nil {
		return nil, e
	}
	id, e := randomUUID()
	if e != nil {
		return nil, e
	}
	m.directory = "media-" + id
	if e = m.temp.Mkdir(m.directory, 0700); e != nil {
		m.directory = ""
		return nil, e
	}
	m.request, e = m.temp.OpenRoot(m.directory)
	if e != nil {
		return nil, e
	}
	var primary, alternate *mediaTempFile
	var fields, files int
	var totalFile, totalFields int64
	seen := map[string]bool{}
	for {
		part, e := reader.NextRawPart()
		if errors.Is(e, io.EOF) {
			break
		}
		if e != nil {
			return nil, errMediaMultipart
		}
		disposition, attrs, e := mime.ParseMediaType(part.Header.Get("Content-Disposition"))
		if e != nil || !strings.EqualFold(disposition, "form-data") || attrs["name"] == "" {
			return nil, errMediaMultipart
		}
		field := attrs["name"]
		filename, isFile := attrs["filename"]
		if !isFile {
			fields++
			if fields > limits.fields {
				return nil, errMediaMultipart
			}
			available := limits.fieldBytes - totalFields
			value, e := io.ReadAll(io.LimitReader(part, available+1))
			if e != nil || int64(len(value)) > available {
				return nil, errMediaMultipart
			}
			_ = part.Close()
			totalFields += int64(len(value))
			if !seen[field] {
				seen[field] = true
				if field == "alt_text" {
					m.AltText = string(value)
				}
				if field == "description" {
					m.Description = string(value)
				}
				if field == "access_scope" && alias == "media" {
					m.AccessScope = string(value)
				}
			}
			continue
		}
		files++
		if files > limits.files {
			return nil, errMediaMultipart
		}
		name := fmt.Sprintf("part-%d", files)
		file, e := m.request.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if e != nil {
			return nil, e
		}
		m.files = append(m.files, name)
		remaining := limits.totalBytes - totalFile
		if remaining > limits.fileBytes {
			remaining = limits.fileBytes
		}
		n, e := io.Copy(file, io.LimitReader(part, remaining+1))
		closeErr := file.Close()
		if closeErr != nil {
			return nil, errors.New("temporary media write failed")
		}
		var bodyLimit *http.MaxBytesError
		if errors.Is(e, io.ErrUnexpectedEOF) || errors.As(e, &bodyLimit) {
			return nil, errMediaMultipart
		}
		if e != nil || closeErr != nil {
			return nil, errors.New("temporary media write failed")
		}
		if n == 0 || n > remaining {
			return nil, errMediaMultipart
		}
		_ = part.Close()
		totalFile += n
		item := &mediaTempFile{Name: filename, MIME: part.Header.Get("Content-Type"), path: name, Size: n}
		if field == "file" && primary == nil {
			primary = item
		}
		if field == alias && alternate == nil {
			alternate = item
		}
	}
	if alias == "media" && (requirePrivate || seen["access_scope"]) {
		switch m.AccessScope {
		case "public":
			if requirePrivate {
				return nil, errMediaAccessScope
			}
			m.AccessScope = ""
		case "chat", "post":
		default:
			return nil, errMediaAccessScope
		}
	}
	if primary != nil {
		m.Selected = *primary
	} else if alternate != nil {
		m.Selected = *alternate
	} else {
		return nil, errMediaNoFile
	}
	return m, nil
}
