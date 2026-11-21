package server

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

type s3Storage struct {
	endpoint                                    url.URL
	bucket, region, accessKey, secretKey, token string
}

var s3HTTP = &http.Client{Timeout: 5 * time.Minute, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
var (
	s3Bucket      = regexp.MustCompile(`^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$`)
	s3Region      = regexp.MustCompile(`^[a-z0-9-]{1,63}$`)
	s3Access      = regexp.MustCompile(`^[A-Za-z0-9_+=.@-]{1,128}$`)
	s3Range       = regexp.MustCompile(`(?i)^bytes=([0-9]{0,16})-([0-9]{0,16})$`)
	s3Partial     = regexp.MustCompile(`^bytes [0-9]+-[0-9]+/[0-9]+$`)
	s3Unsatisfied = regexp.MustCompile(`^bytes \*/[0-9]+$`)
)

func configuredS3(get func(string) string) *s3Storage {
	address := get("STORAGE_S3_ENDPOINT")
	endpoint, err := url.Parse(address)
	storage := &s3Storage{bucket: get("STORAGE_S3_BUCKET"), region: get("STORAGE_S3_REGION"), accessKey: get("STORAGE_S3_ACCESS_KEY"), secretKey: get("STORAGE_S3_SECRET_KEY"), token: get("STORAGE_S3_SESSION_TOKEN")}
	if err != nil || (endpoint.Scheme != "http" && endpoint.Scheme != "https") || endpoint.Hostname() == "" ||
		endpoint.User != nil || (endpoint.EscapedPath() != "" && endpoint.EscapedPath() != "/") ||
		endpoint.RawQuery != "" || endpoint.ForceQuery || strings.Contains(address, "#") ||
		!s3Bucket.MatchString(storage.bucket) || !s3Region.MatchString(storage.region) || !s3Access.MatchString(storage.accessKey) ||
		!s3Printable(storage.secretKey, 1, 512) || !s3Printable(storage.token, 0, 8192) {
		return nil
	}
	storage.endpoint = *endpoint
	return storage
}

func s3Printable(value string, minimum, maximum int) bool {
	return len(value) >= minimum && len(value) <= maximum && strings.IndexFunc(value, func(r rune) bool { return r < '!' || r > '~' }) == -1
}

func s3ManagedKey(raw string) (string, bool) {
	key, err := normalizeLocalFileKey(raw)
	return key, err == nil && (strings.HasPrefix(key, "posts/") || strings.HasPrefix(key, "avatars/"))
}

func s3Path(value string) string {
	const digits = "0123456789ABCDEF"
	var output strings.Builder
	for i := 0; i < len(value); i++ {
		b := value[i]
		if (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || strings.ContainsRune("-._~/", rune(b)) {
			output.WriteByte(b)
		} else {
			output.WriteByte('%')
			output.WriteByte(digits[b>>4])
			output.WriteByte(digits[b&15])
		}
	}
	return output.String()
}

func s3HMAC(key []byte, data string) []byte {
	mac := hmac.New(sha256.New, key)
	_, _ = io.WriteString(mac, data)
	return mac.Sum(nil)
}

func (storage *s3Storage) request(ctx context.Context, method, raw, mediaType, byteRange, digest string, body io.Reader, size int64, privateRead bool) (*http.Response, error) {
	key, err := normalizeLocalFileKey(raw)
	_, public := s3ManagedKey(key)
	private := isPrivateStorageKey(key)
	privateAllowed := private && (method == http.MethodPut || method == http.MethodDelete ||
		(privateRead && (method == http.MethodGet || method == http.MethodHead)))
	if err != nil || (!public && !privateAllowed) {
		return nil, errMediaStorage
	}
	endpoint := storage.endpoint
	endpoint.Path = "/" + storage.bucket + "/" + key
	endpoint.RawPath = s3Path(endpoint.Path)
	request, err := http.NewRequestWithContext(ctx, method, endpoint.String(), body)
	if err != nil {
		return nil, errMediaStorage
	}
	date := time.Now().UTC().Format("20060102T150405Z")
	if digest == "" {
		empty := sha256.Sum256(nil)
		digest = hex.EncodeToString(empty[:])
	}
	headers := map[string]string{"host": endpoint.Host, "x-amz-date": date, "x-amz-content-sha256": digest}
	if storage.token != "" {
		headers["x-amz-security-token"] = storage.token
	}
	if method == http.MethodPut {
		request.ContentLength = size
		headers["content-length"] = strconv.FormatInt(size, 10)
		headers["content-type"] = mediaType
		headers["if-none-match"] = "*"
		if private {
			headers["cache-control"] = "private, no-store"
		}
	}
	if byteRange != "" {
		headers["range"] = byteRange
	}
	keys := make([]string, 0, len(headers))
	for name := range headers {
		keys = append(keys, name)
	}
	sort.Strings(keys)
	var canonical strings.Builder
	for _, name := range keys {
		value := headers[name]
		if name != "host" && name != "content-length" {
			request.Header.Set(name, value)
		}
		canonical.WriteString(name + ":" + strings.Join(strings.Fields(value), " ") + "\n")
	}
	request.Header.Set("Accept-Encoding", "identity")
	signed := strings.Join(keys, ";")
	canonicalHash := sha256.Sum256([]byte(strings.Join([]string{method, endpoint.RawPath, "", canonical.String(), signed, digest}, "\n")))
	scope := date[:8] + "/" + storage.region + "/s3/aws4_request"
	signingKey := s3HMAC(s3HMAC(s3HMAC(s3HMAC([]byte("AWS4"+storage.secretKey), date[:8]), storage.region), "s3"), "aws4_request")
	signature := s3HMAC(signingKey, "AWS4-HMAC-SHA256\n"+date+"\n"+scope+"\n"+hex.EncodeToString(canonicalHash[:]))
	request.Header.Set("Authorization", "AWS4-HMAC-SHA256 Credential="+storage.accessKey+"/"+scope+",SignedHeaders="+signed+",Signature="+hex.EncodeToString(signature))
	response, err := s3HTTP.Do(request)
	if err != nil {
		return nil, errMediaStorage
	}
	return response, nil
}

func (storage *s3Storage) put(ctx context.Context, media *mediaMultipart, key, mime string) error {
	file, err := media.OpenSelected()
	if err != nil {
		return errMediaStorage
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() < 1 || info.Size() != media.Selected.Size {
		return errMediaStorage
	}
	hash := sha256.New()
	if _, err := io.CopyN(hash, mediaContextReader{ctx: ctx, source: file}, info.Size()); err != nil {
		return errMediaStorage
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return errMediaStorage
	}
	response, err := storage.request(ctx, http.MethodPut, key, mime, "", hex.EncodeToString(hash.Sum(nil)), io.LimitReader(file, info.Size()), info.Size(), false)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return errMediaStorage
	}
	return nil
}

func (storage *s3Storage) delete(ctx context.Context, key string) error {
	response, err := storage.request(ctx, http.MethodDelete, key, "", "", "", nil, 0, false)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusNoContent && response.StatusCode != http.StatusNotFound {
		return errMediaStorage
	}
	return nil
}

func (storage *s3Storage) unsatisfiedRange(w http.ResponseWriter, r *http.Request, key, contentRange string, private bool) {
	if !s3Unsatisfied.MatchString(contentRange) {
		metadata, err := storage.request(r.Context(), http.MethodHead, key, "", "", "", nil, 0, private)
		if err != nil {
			storageHTTPError(w, private, http.StatusServiceUnavailable, "Storage unavailable")
			return
		}
		metadata.Body.Close()
		if metadata.StatusCode == http.StatusNotFound {
			storageReadError(w, r, key, os.ErrNotExist, private)
			return
		}
		contentRange = "bytes */" + metadata.Header.Get("Content-Length")
		if metadata.StatusCode != http.StatusOK || !s3Unsatisfied.MatchString(contentRange) {
			storageHTTPError(w, private, http.StatusServiceUnavailable, "Storage unavailable")
			return
		}
	}
	w.Header().Set("Content-Range", contentRange)
	storageHTTPError(w, private, http.StatusRequestedRangeNotSatisfiable, "Requested range not satisfiable")
}

func (storage *s3Storage) serve(w http.ResponseWriter, r *http.Request, key string, private bool) {
	_, public := s3ManagedKey(key)
	if (private && !isPrivateStorageKey(key)) || (!private && !public) {
		storageReadError(w, r, key, os.ErrNotExist, private)
		return
	}
	var byteRange string
	if value := strings.TrimSpace(r.Header.Get("Range")); r.Method != http.MethodHead && value != "" {
		parts := s3Range.FindStringSubmatch(value)
		if len(parts) == 0 || (parts[1] == "" && parts[2] == "") {
			storage.unsatisfiedRange(w, r, key, "", private)
			return
		}
		byteRange = "bytes=" + parts[1] + "-" + parts[2]
	}
	response, err := storage.request(r.Context(), r.Method, key, "", byteRange, "", nil, 0, private)
	if err != nil {
		storageHTTPError(w, private, http.StatusServiceUnavailable, "Storage unavailable")
		return
	}
	contentRange := response.Header.Get("Content-Range")
	if response.StatusCode == http.StatusRequestedRangeNotSatisfiable {
		response.Body.Close()
		if byteRange == "" {
			storageHTTPError(w, private, http.StatusServiceUnavailable, "Storage unavailable")
			return
		}
		storage.unsatisfiedRange(w, r, key, contentRange, private)
		return
	}
	defer response.Body.Close()
	switch response.StatusCode {
	case 404:
		storageHTTPError(w, private, http.StatusNotFound, "404 page not found")
		return
	case 200:
		if byteRange != "" {
			storageHTTPError(w, private, http.StatusServiceUnavailable, "Storage unavailable")
			return
		}
	case 206:
		if byteRange == "" || !s3Partial.MatchString(contentRange) {
			storageHTTPError(w, private, http.StatusServiceUnavailable, "Storage unavailable")
			return
		}
		w.Header().Set("Content-Range", contentRange)
	default:
		storageHTTPError(w, private, http.StatusServiceUnavailable, "Storage unavailable")
		return
	}
	setStorageReadHeaders(w.Header(), key, private)
	for _, name := range []string{"Content-Length", "ETag", "Last-Modified"} {
		if value := response.Header.Get(name); value != "" {
			w.Header().Set(name, value)
		}
	}
	w.WriteHeader(response.StatusCode)
	if r.Method != http.MethodHead {
		_, _ = io.Copy(w, response.Body)
	}
}
