package server

import (
	"context"
	"net"
	"net/http"
	"testing"
	"time"
)

func TestGracefulHTTPStopAndTimeouts(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	listener, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	srv := NewHTTPServer(listener.Addr().String(), http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	if srv.ReadHeaderTimeout <= 0 || srv.ReadTimeout <= 0 || srv.WriteTimeout <= 0 || srv.IdleTimeout <= 0 || srv.MaxHeaderBytes <= 0 {
		t.Fatal("missing request resource bounds")
	}
	done := make(chan error, 1)
	go func() { done <- Serve(ctx, srv, listener) }()
	resp, e := http.Get("http://" + listener.Addr().String())
	if e != nil {
		t.Fatal(e)
	}
	resp.Body.Close()
	cancel()
	select {
	case e := <-done:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("shutdown did not stop HTTP server")
	}
}
