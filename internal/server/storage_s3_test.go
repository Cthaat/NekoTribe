package server

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

func TestS3StoragePublishesReadsAndCleansUp(t *testing.T) {
	const key = "posts/images/42/a.txt"
	const privateKey = "private/chat/42/a.txt"
	const data = "source-content"
	digest := sha256.Sum256([]byte(data))
	object := make(chan string, 1)
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		private := r.URL.Path == "/neko-media/"+privateKey
		if (!private && r.URL.Path != "/neko-media/"+key) || !strings.HasPrefix(r.Header.Get("Authorization"), "AWS4-HMAC-SHA256 Credential=fixture-key/") {
			t.Error("invalid signed request")
			w.WriteHeader(403)
			return
		}
		if private && (r.Method == http.MethodGet || r.Method == http.MethodHead) {
			t.Error("reserved object reached S3 through a public read")
		}
		switch r.Method {
		case http.MethodPut:
			body, err := io.ReadAll(r.Body)
			if err != nil || string(body) != data || r.Header.Get("If-None-Match") != "*" || r.Header.Get("X-Amz-Content-Sha256") != hex.EncodeToString(digest[:]) {
				t.Error("invalid upload")
				w.WriteHeader(400)
				return
			}
			if private && r.Header.Get("Cache-Control") != "private, no-store" {
				t.Error("missing private cache policy")
			}
			select {
			case object <- data:
				w.WriteHeader(200)
			default:
				w.WriteHeader(412)
			}
		case http.MethodGet:
			if len(object) == 0 {
				w.WriteHeader(404)
				return
			}
			switch r.Header.Get("Range") {
			case "bytes=20-":
				w.WriteHeader(416)
				return
			case "bytes=0-5":
			default:
				t.Error("missing range")
				w.WriteHeader(400)
				return
			}
			w.Header().Set("Content-Range", "bytes 0-5/14")
			w.WriteHeader(206)
			_, _ = io.WriteString(w, data[:6])
		case http.MethodHead:
			if len(object) == 0 {
				w.WriteHeader(404)
				return
			}
			if r.Header.Get("Range") != "" {
				t.Error("HEAD forwarded a Range header")
			}
			w.Header().Set("Content-Length", strconv.Itoa(len(data)))
			w.WriteHeader(200)
		case http.MethodDelete:
			select {
			case <-object:
			default:
			}
			w.WriteHeader(204)
		default:
			w.WriteHeader(405)
		}
	}))
	defer remote.Close()
	root := t.TempDir()
	env := map[string]string{"STORAGE_PATH": root, "STORAGE_TYPE": "s3", "STORAGE_S3_ENDPOINT": remote.URL, "STORAGE_S3_BUCKET": "neko-media", "STORAGE_S3_REGION": "us-east-1", "STORAGE_S3_ACCESS_KEY": "fixture-key", "STORAGE_S3_SECRET_KEY": "fixture-secret"}
	config := localStorageConfig(func(key string) (string, bool) { value, ok := env[key]; return value, ok })
	media := mediaStoredFixture(t, root)
	cleanup, release, err := publishRouteMedia(context.Background(), media, config, key, "text/plain")
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	if _, _, err := publishRouteMedia(context.Background(), media, config, key, "text/plain"); err == nil {
		t.Fatal("overwrote existing object")
	}
	request := httptest.NewRequest(http.MethodGet, "/storage/"+key, nil)
	request.Header.Set("Range", "bytes=0-5")
	read := httptest.NewRecorder()
	serveLocalStorage(read, request, config)
	if read.Code != 206 || read.Body.String() != data[:6] {
		t.Fatal(read.Code, read.Body.String())
	}
	for _, byteRange := range []string{"bytes=20-", "bytes=1-2,4-5"} {
		rangeRequest := httptest.NewRequest(http.MethodGet, "/storage/"+key, nil)
		rangeRequest.Header.Set("Range", byteRange)
		response := httptest.NewRecorder()
		serveLocalStorage(response, rangeRequest, config)
		if response.Code != 416 || response.Header().Get("Content-Range") != "bytes */"+strconv.Itoa(len(data)) {
			t.Fatalf("range %s: status %d, headers %v", byteRange, response.Code, response.Header())
		}
	}
	headRequest := httptest.NewRequest(http.MethodHead, "/storage/"+key, nil)
	headRequest.Header.Set("Range", "bytes=999-")
	head := httptest.NewRecorder()
	serveLocalStorage(head, headRequest, config)
	if head.Code != 200 || head.Header().Get("Content-Length") != strconv.Itoa(len(data)) ||
		head.Header().Get("Content-Range") != "" || head.Body.Len() != 0 {
		t.Fatalf("S3 HEAD: status %d, headers %v, body length %d", head.Code, head.Header(), head.Body.Len())
	}
	if err := cleanup(); err != nil {
		t.Fatal(err)
	}
	if err := deleteMediaReference(config, StorageURLPolicy{}, key, ""); err != nil {
		t.Fatal(err)
	}
	read = httptest.NewRecorder()
	serveLocalStorage(read, request, config)
	if read.Code != 404 {
		t.Fatal(read.Code)
	}
	if _, release, err := publishRouteMedia(context.Background(), media, config, privateKey, "text/plain"); err != nil {
		t.Fatal(err)
	} else {
		defer release()
	}
	for _, method := range []string{http.MethodGet, http.MethodHead} {
		result := httptest.NewRecorder()
		serveLocalStorage(result, httptest.NewRequest(method, "/storage/"+privateKey, nil), config)
		if result.Code != http.StatusNotFound {
			t.Fatal(result.Code)
		}
	}
	if err := deleteMediaReference(config, StorageURLPolicy{}, "", "/storage/"+privateKey); err != nil || len(object) != 1 {
		t.Fatal("a public URL must not remove private content", err)
	}
	if err := deleteMediaReference(config, StorageURLPolicy{}, privateKey, ""); err != nil || len(object) != 0 {
		t.Fatal("the trusted key should remove private content", err)
	}
}
