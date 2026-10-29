package server

import (
	"path/filepath"
	"strings"
)

// Detector output is supplied by a separate content inspection component.
type mediaDetectedType struct {
	Ext  string `json:"ext"`
	MIME string `json:"mime"`
}
type mediaSelectedType struct {
	Extension string `json:"extension"`
	MIMEType  string `json:"mimeType"`
	MediaType string `json:"mediaType"`
	Supported bool   `json:"supported"`
}

var mediaFallbackMIME = map[string]string{
	".7z": "application/x-7z-compressed", ".csv": "text/csv", ".doc": "application/msword", ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document", ".gz": "application/gzip", ".json": "application/json", ".md": "text/markdown", ".odp": "application/vnd.oasis.opendocument.presentation", ".ods": "application/vnd.oasis.opendocument.spreadsheet", ".odt": "application/vnd.oasis.opendocument.text", ".pdf": "application/pdf", ".ppt": "application/vnd.ms-powerpoint", ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation", ".rar": "application/vnd.rar", ".rtf": "application/rtf", ".tar": "application/x-tar", ".tsv": "text/tab-separated-values", ".txt": "text/plain", ".xls": "application/vnd.ms-excel", ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", ".xml": "application/xml", ".zip": "application/zip",
}
var mediaSupportedMIME = map[string]bool{
	"image/avif": true, "image/gif": true, "image/jpeg": true, "image/png": true, "image/webp": true,
	"audio/mpeg": true, "audio/ogg": true, "audio/wav": true, "video/mp4": true, "video/ogg": true, "video/webm": true,
	"application/json": true, "application/msword": true, "application/pdf": true, "application/rtf": true, "application/vnd.ms-excel": true, "application/vnd.ms-powerpoint": true,
	"application/vnd.oasis.opendocument.presentation": true, "application/vnd.oasis.opendocument.spreadsheet": true, "application/vnd.oasis.opendocument.text": true,
	"application/vnd.openxmlformats-officedocument.presentationml.presentation": true, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": true, "application/vnd.openxmlformats-officedocument.wordprocessingml.document": true,
	"application/xml": true, "text/csv": true, "text/markdown": true, "text/plain": true, "text/tab-separated-values": true, "text/xml": true,
	"application/gzip": true, "application/vnd.rar": true, "application/x-7z-compressed": true, "application/x-rar-compressed": true, "application/x-tar": true, "application/zip": true,
}

func selectMediaFileType(name, uploaded string, detected *mediaDetectedType) mediaSelectedType {
	base := filepath.Base(name)
	extension := filepath.Ext(base)
	if base == "." || base == ".." || (extension == base && strings.HasPrefix(base, ".")) {
		extension = ""
	}
	extension = strings.ToLower(extension)
	if extension == "" {
		extension = ".bin"
	}
	detectedMIME := ""
	if detected != nil {
		if detected.Ext != "" {
			extension = "." + strings.ToLower(detected.Ext)
		}
		detectedMIME = mediaNormalizeMIME(detected.MIME)
	}
	uploaded = mediaNormalizeMIME(uploaded)
	fallback := mediaFallbackMIME[extension]
	mimeType := detectedMIME
	if mimeType == "" {
		if uploaded == "application/octet-stream" && fallback != "" {
			mimeType = fallback
		} else if uploaded != "" {
			mimeType = uploaded
		} else {
			mimeType = fallback
		}
	}
	mediaType := "file"
	switch {
	case mimeType == "image/gif":
		mediaType = "gif"
	case mediaSupportedMIME[mimeType] && strings.HasPrefix(mimeType, "image/"):
		mediaType = "image"
	case strings.HasPrefix(mimeType, "video/"):
		mediaType = "video"
	case strings.HasPrefix(mimeType, "audio/"):
		mediaType = "audio"
	}
	return mediaSelectedType{Extension: extension, MIMEType: mimeType, MediaType: mediaType, Supported: mediaSupportedMIME[mimeType]}
}

func mediaNormalizeMIME(value string) string {
	return strings.ToLower(strings.TrimFunc(strings.SplitN(value, ";", 2)[0], jsTrimSpace))
}
