package server

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"strings"

	"github.com/gabriel-vasile/mimetype"
)

// This bounded detector is not yet wired into the upload route. Its output is
// compared against Nuxt's file-type library before the policy is accepted.
func detectMediaContent(reader io.Reader) (*mediaDetectedType, error) {
	buffer := make([]byte, 4096)
	n, err := io.ReadFull(reader, buffer)
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
		return nil, errMediaStorage
	}
	prefix := buffer[:n]
	// A ZIP entry or APNG control chunk may lie beyond this bounded prefix.
	// Reject uncertain results until streaming container inspection is added.
	if n == len(buffer) {
		if bytes.HasPrefix(prefix, []byte{'P', 'K', 3, 4}) {
			return nil, errMediaStorage
		}
		if bytes.HasPrefix(prefix, []byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a}) && !pngHasDecisiveChunk(prefix) {
			return nil, errMediaStorage
		}
	}
	detected := mimetype.Detect(prefix)
	if detected.Is("application/octet-stream") {
		return nil, nil
	}
	if detected.Is("application/vnd.microsoft.portable-executable") {
		return &mediaDetectedType{Ext: "exe", MIME: "application/x-msdownload"}, nil
	}
	for parent := detected; parent != nil; parent = parent.Parent() {
		if parent.Is("application/x-elf") {
			return &mediaDetectedType{Ext: "elf", MIME: "application/x-elf"}, nil
		}
	}
	// Nuxt's binary detector does not infer ordinary text or its textual
	// subtypes; RTF is a binary-signature exception in its detector.
	if !detected.Is("application/rtf") {
		for parent := detected; parent != nil; parent = parent.Parent() {
			if parent.Is("text/plain") {
				return nil, nil
			}
		}
	}
	ext := strings.TrimPrefix(detected.Extension(), ".")
	if ext == "" {
		return nil, errMediaStorage
	}
	return &mediaDetectedType{Ext: ext, MIME: mediaNormalizeMIME(detected.String())}, nil
}

func pngHasDecisiveChunk(data []byte) bool {
	for position := 8; position+8 <= len(data); {
		length := uint64(binary.BigEndian.Uint32(data[position : position+4]))
		if length > 0x7fffffff {
			return false
		}
		kind := string(data[position+4 : position+8])
		if kind == "acTL" || kind == "IDAT" {
			return true
		}
		next := uint64(position) + 12 + length
		if next > uint64(len(data)) {
			return false
		}
		position = int(next)
	}
	return false
}
