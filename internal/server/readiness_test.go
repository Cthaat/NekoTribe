package server

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestReadinessRecovers(t *testing.T) {
	redisError := errors.New("private connection details")
	handler := WithReadiness(
		http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) }),
		CorsPolicy{Origins: []string{"https://client.example.test"}},
		func(context.Context) error { return nil },
		func(context.Context) error { return redisError },
	)

	for _, test := range []struct {
		path   string
		code   int
		status string
	}{
		{"/api/health", http.StatusNoContent, ""},
		{"/api/ready", http.StatusServiceUnavailable, `{"status":"unavailable"}`},
		{"/api/ready", http.StatusOK, `{"status":"ready"}`},
	} {
		response := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodGet, test.path, nil)
		request.Header.Set("Origin", "https://client.example.test")
		handler.ServeHTTP(response, request)
		if response.Code != test.code || strings.TrimSpace(response.Body.String()) != test.status {
			t.Fatalf("%s returned HTTP %d with %q", test.path, response.Code, response.Body.String())
		}
		if test.path == "/api/ready" {
			if response.Header().Get("Access-Control-Allow-Origin") != "https://client.example.test" {
				t.Fatal("configured browser origin could not read readiness")
			}
			if response.Header().Get("Cache-Control") != "no-store" {
				t.Fatal("readiness response is cacheable")
			}
			redisError = nil
		}
	}
}
