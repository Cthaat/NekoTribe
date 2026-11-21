package server

import (
	"errors"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

type localByteRange struct {
	Start uint64 `json:"start"`
	End   uint64 `json:"end"`
}

var errLocalFileKey = errors.New("invalid storage path")
var errLocalRange = errors.New("invalid storage byte range")
var localDeviceName = regexp.MustCompile(`^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³]|CONIN\$|CONOUT\$)$`)
var localRangePattern = regexp.MustCompile(`^bytes=([0-9]*)-([0-9]*)$`)

func isPrivateStorageKey(key string) bool {
	return strings.HasPrefix(key, "private/chat/") || strings.HasPrefix(key, "private/post/")
}

func normalizeLocalFileKey(key string) (string, error) {
	if !utf8.ValidString(key) {
		return "", errLocalFileKey
	}
	key = strings.ReplaceAll(key, `\`, "/")
	for _, part := range strings.Split(key, "/") {
		if part == "" || part == "." || part == ".." || strings.HasSuffix(part, ".") || strings.HasSuffix(part, " ") {
			return "", errLocalFileKey
		}
		for _, r := range part {
			if r < 32 || r == 127 || strings.ContainsRune(`<>:"|?*`, r) {
				return "", errLocalFileKey
			}
		}
		base := []byte(strings.TrimRight(strings.SplitN(part, ".", 2)[0], " "))
		for i, b := range base {
			if b >= 'a' && b <= 'z' {
				base[i] = b - 'a' + 'A'
			}
		}
		if localDeviceName.Match(base) {
			return "", errLocalFileKey
		}
	}
	return key, nil
}
func parseLocalByteRange(header string, size uint64) (*localByteRange, error) {
	header = strings.TrimFunc(header, jsTrimSpace)
	if header == "" {
		return nil, nil
	}
	parts := localRangePattern.FindStringSubmatch(strings.ToLower(header))
	if parts == nil || size == 0 {
		return nil, errLocalRange
	}
	start, end := uint64(0), size-1
	if parts[1] == "" {
		if parts[2] == "" {
			return nil, errLocalRange
		}
		suffix, err := strconv.ParseUint(parts[2], 10, 64)
		if err != nil || suffix > size {
			suffix = size
		}
		if suffix == 0 {
			return nil, errLocalRange
		}
		start = size - suffix
	} else {
		var err error
		start, err = strconv.ParseUint(parts[1], 10, 64)
		if err != nil || start >= size {
			return nil, errLocalRange
		}
		if parts[2] != "" {
			candidate, err := strconv.ParseUint(parts[2], 10, 64)
			if err == nil && candidate < size {
				end = candidate
			}
		}
	}
	if end < start {
		return nil, errLocalRange
	}
	return &localByteRange{Start: start, End: end}, nil
}
