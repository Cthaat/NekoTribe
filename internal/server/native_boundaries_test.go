package server

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestNoNativeRouteCallsCountedNuxt(t *testing.T) {
	var calls atomic.Int64
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls.Add(1); w.WriteHeader(200) }))
	defer upstream.Close()
	t.Setenv("LEGACY_BACKEND_BASE_URL", upstream.URL)
	codec, _ := fixture(t)
	s := store()
	ts := httptest.NewServer(NewHandler(codec, s, CorsPolicy{}))
	defer ts.Close()
	for _, route := range []struct {
		path   string
		status int
	}{
		{"/api/v2/auth/login", http.StatusNotFound},
		{"/storage/file", http.StatusNotFound},
		{"/uploads/file", http.StatusGone},
	} {
		r, _ := request(t, ts.Client(), ts.URL, "GET", route.path, "", "")
		if r.StatusCode != route.status {
			t.Fatalf("%s: got %d, want %d", route.path, r.StatusCode, route.status)
		}
		if route.path == "/api/v2/auth/login" && r.Header.Get("Cache-Control") != "private, no-store" {
			t.Fatal("v2 fallback must not be cached")
		}
	}
	ws, _ := request(t, ts.Client(), ts.URL, "GET", "/_ws", "", "")
	if ws.StatusCode != 400 {
		t.Fatal("malformed websocket upgrade must fail locally", ws.StatusCode)
	}
	list, _ := request(t, ts.Client(), ts.URL, "GET", "/api/v2/auth/sessions", "", "")
	if list.StatusCode != 401 {
		t.Fatal("native session list must require authentication", list.StatusCode)
	}
	if list.Header.Get("Cache-Control") != "private, no-store" {
		t.Fatal("v2 authentication errors must not be cached")
	}
	if calls.Load() != 0 {
		t.Fatal("unexpected Nuxt fallback", calls.Load())
	}
	if s.touches+s.revokes != 0 {
		t.Fatal("unexpected DB effects")
	}
}
func TestShutdownDrainsActiveRequest(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	listener, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	started, release := make(chan struct{}), make(chan struct{})
	srv := NewHTTPServer(listener.Addr().String(), http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { close(started); <-release; w.WriteHeader(204) }))
	done := make(chan error, 1)
	go func() { done <- Serve(ctx, srv, listener) }()
	response := make(chan error, 1)
	go func() {
		r, e := http.Get("http://" + listener.Addr().String())
		if e == nil {
			r.Body.Close()
		}
		response <- e
	}()
	<-started
	cancel()
	select {
	case <-done:
		t.Fatal("server returned while request active")
	case <-time.After(30 * time.Millisecond):
	}
	close(release)
	select {
	case e := <-done:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("server did not finish drain")
	}
	if e := <-response; e != nil {
		t.Fatal(e)
	}
}
