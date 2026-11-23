package server

import (
	"context"
	"encoding/json"
	"net/http"
	"sync"
	"time"
)

const readinessTimeout = 2 * time.Second

type readinessProbe struct {
	done     chan struct{}
	deadline time.Time
	ready    bool
}

func WithReadiness(next http.Handler, cors CorsPolicy, checkOracle, checkRedis func(context.Context) error) http.Handler {
	if observed, ok := next.(observedHTTP); ok {
		observed.next = withReadiness(observed.next, cors, checkOracle, checkRedis)
		return observed
	}
	return withReadiness(next, cors, checkOracle, checkRedis)
}

func withReadiness(next http.Handler, cors CorsPolicy, checkOracle, checkRedis func(context.Context) error) http.Handler {
	var mu sync.Mutex
	var active *readinessProbe
	start := func() *readinessProbe {
		mu.Lock()
		defer mu.Unlock()
		if active != nil {
			return active
		}
		probe := &readinessProbe{done: make(chan struct{}), deadline: time.Now().Add(readinessTimeout)}
		active = probe
		go func() {
			ctx, cancel := context.WithDeadline(context.Background(), probe.deadline)
			defer cancel()
			results := make(chan error, 2)
			go func() { results <- checkOracle(ctx) }()
			go func() { results <- checkRedis(ctx) }()
			first, second := <-results, <-results
			probe.ready = first == nil && second == nil && time.Now().Before(probe.deadline)
			mu.Lock()
			close(probe.done)
			active = nil
			mu.Unlock()
		}()
		return probe
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.EscapedPath() != "/api/ready" {
			next.ServeHTTP(w, r)
			return
		}
		preflight(w, r, cors)
		probe := start()
		ctx, cancel := context.WithDeadline(r.Context(), probe.deadline)
		defer cancel()
		ready := false
		select {
		case <-probe.done:
			ready = probe.ready
		case <-ctx.Done():
		}
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Type", "application/json")
		status := "ready"
		if !ready {
			status = "unavailable"
			w.WriteHeader(http.StatusServiceUnavailable)
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"status": status})
	})
}
