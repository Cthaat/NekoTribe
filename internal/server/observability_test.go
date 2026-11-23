package server

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/redis/go-redis/v9"
)

const testMetricsToken = "sample-scrape-credential"

func testScrape(handler http.Handler, auth ...string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("GET", "/metrics", nil)
	for _, value := range auth {
		r.Header.Add("Authorization", value)
	}
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	return w
}

func requireMetricLines(t *testing.T, text string, lines ...string) {
	t.Helper()
	for _, line := range lines {
		if !strings.Contains(text, "\n"+line+"\n") {
			t.Errorf("missing metric sample %q", line)
		}
	}
}

func TestObservabilityHTTPHeadersScrapeAndPool(t *testing.T) {
	db := sql.OpenDB(testConnector{state: &driverState{}})
	defer db.Close()
	conn, err := db.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	cors := CorsPolicy{Origins: []string{"https://app.example.com"}}
	app := NewHandlerWithConfig(nil, OracleSessions{db}, cors, RefreshConfig{metricsToken: testMetricsToken}).(observedHTTP)
	var logs bytes.Buffer
	app.telemetry.logger = slog.New(slog.NewJSONHandler(&logs, nil))
	probe := func(context.Context) error { return nil }
	handler := WithReadiness(app, cors, probe, probe)

	send := func(method, path string, idValues ...string) *httptest.ResponseRecorder {
		t.Helper()
		r := httptest.NewRequest(method, path, strings.NewReader("body-marker"))
		for _, value := range idValues {
			r.Header.Add("X-Request-Id", value)
		}
		r.Header.Set("Origin", "https://app.example.com")
		r.Header.Set("Cookie", "access_token=cookie-marker")
		if method == "OPTIONS" {
			r.Header.Set("Access-Control-Request-Method", "GET")
			r.Header.Set("Access-Control-Request-Headers", "X-Request-Id")
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}

	health := send("GET", "/api/health", "browser.1:test")
	ready := send("GET", "/api/ready", "ready-1")
	if id := health.Header().Get("X-Request-Id"); health.Code != 200 || id != "browser.1:test" ||
		!strings.Contains(health.Header().Get("Access-Control-Expose-Headers"), "X-Request-Id") ||
		ready.Code != 200 || ready.Header().Get("X-Request-Id") != "ready-1" {
		t.Fatal("health and readiness did not preserve request ID and CORS")
	}
	uuid := regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	preflight := send("OPTIONS", "/api/v2/posts", "bad/value")
	duplicate := send("GET", "/api/v2/links/preview?url=link-query-marker", "first", "second")
	callback := send("GET", githubCallbackPath+"?code=oauth-code-marker", "callback-1")
	first, second := preflight.Header().Get("X-Request-Id"), duplicate.Header().Get("X-Request-Id")
	if preflight.Code != 204 || duplicate.Code != 401 || callback.Code != 400 ||
		!uuid.MatchString(first) || !uuid.MatchString(second) || first == second {
		t.Fatal("invalid request IDs were not replaced independently")
	}
	unknown := send("UNLISTED", "/opaque/path-marker", "unknown-1")
	if unknown.Code != 404 || safeLogPath("/api/v2/auth/oauth/github/login/flows/private-flow-id/complete") !=
		"/api/v2/auth/oauth/github/login/flows/{flow_id}/complete" ||
		safeLogPath("/storage/private-name.txt") != "/storage/{path}" {
		t.Fatal("unexpected sanitized routes or unknown method behavior")
	}

	if disabled := testScrape(NewHandler(nil, nil, CorsPolicy{})); disabled.Code != 404 ||
		disabled.Header().Get("Cache-Control") != "no-store" || !uuid.MatchString(disabled.Header().Get("X-Request-Id")) {
		t.Fatal("disabled scrape did not return a correlated 404")
	}
	if head := send("HEAD", "/metrics"); head.Code != 404 || head.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("non-GET request reached the scrape")
	}
	for _, auth := range [][]string{nil, {"Bearer wrong"}, {"Bearer " + testMetricsToken, "Bearer " + testMetricsToken}} {
		w := testScrape(handler, auth...)
		if w.Code != 401 || w.Header().Get("Cache-Control") != "no-store" || !uuid.MatchString(w.Header().Get("X-Request-Id")) {
			t.Fatal("incorrect scrape credentials were accepted")
		}
	}
	sample := testScrape(handler, "Bearer "+testMetricsToken)
	if sample.Code != 200 || sample.Header().Get("Content-Type") != observabilityPolicy.ContentType ||
		sample.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("correct scrape credentials did not return Prometheus content")
	}
	requireMetricLines(t, sample.Body.String(),
		`nekotribe_http_requests_total{method="GET",status="200"} 2`,
		`nekotribe_http_requests_total{method="GET",status="401"} 1`,
		`nekotribe_http_requests_total{method="OPTIONS",status="204"} 1`,
		`nekotribe_http_requests_total{method="OTHER",status="404"} 1`,
		`nekotribe_oracle_pool_connections{state="open"} 1`,
		`nekotribe_oracle_pool_connections{state="in_use"} 1`,
		`nekotribe_oracle_pool_connections{state="idle"} 0`,
		"nekotribe_websocket_connections 0", "nekotribe_websocket_channels 0")
	if err := conn.Close(); err != nil {
		t.Fatal(err)
	}
	requireMetricLines(t, testScrape(handler, "Bearer "+testMetricsToken).Body.String(),
		`nekotribe_http_requests_total{method="GET",status="200"} 2`,
		`nekotribe_oracle_pool_connections{state="idle"} 1`)
	for _, marker := range []string{"link-query-marker", "oauth-code-marker", "path-marker", "cookie-marker", "body-marker", testMetricsToken} {
		if strings.Contains(logs.String(), marker) || strings.Contains(sample.Body.String(), marker) {
			t.Errorf("telemetry exposed a request value")
		}
	}
	found := false
	for _, line := range strings.Split(strings.TrimSpace(logs.String()), "\n") {
		var event map[string]any
		if json.Unmarshal([]byte(line), &event) != nil {
			t.Fatal("completion record was not structured JSON")
		}
		if event["event"] == "http.request.completed" && event["request_id"] == "callback-1" &&
			event["path"] == githubCallbackPath && event["status"] == float64(400) && event["method"] == "GET" {
			found = true
		}
	}
	if !found {
		t.Fatal("callback telemetry did not retain its safe route and request ID")
	}
}

func TestObservabilityCacheAndAIQuotaUseRuntimeContext(t *testing.T) {
	codec, tokens := fixture(t)
	repo := &writingFixture{aiHTTPFixture: &aiHTTPFixture{memorySessions: store()}, latest: 4, purpose: "writing"}
	cache := &previewFixtureCache{}
	preview := &linkPreviewService{lookup: func(context.Context, string, string) ([]netip.Addr, error) {
		return nil, nil
	}}
	quota := &visionQuotaFixture{retry: 30}
	app := NewHandlerWithConfig(codec, repo, CorsPolicy{}, RefreshConfig{
		linkPreview: preview, AIModelConfig: writingConfig("https://example.com"), AIModelQuotaLimiter: quota,
		metricsToken: testMetricsToken,
	}).(observedHTTP)
	var logs bytes.Buffer
	app.telemetry.logger = slog.New(slog.NewJSONHandler(&logs, nil))
	send := func(method, path, id string, status int) {
		t.Helper()
		r := httptest.NewRequest(method, path, nil)
		r.Header.Set("Authorization", "Bearer "+tokens["access-hs256"])
		r.Header.Set("X-Request-Id", id)
		w := httptest.NewRecorder()
		app.ServeHTTP(w, r)
		if w.Code != status {
			t.Fatalf("status %d, want %d", w.Code, status)
		}
	}
	const previewPath = "/api/v2/links/preview?url=https%3A%2F%2Fexample.com"
	send("GET", previewPath, "cache-not-configured", 200)
	preview.cache = cache
	cache.readErr = redis.Nil
	send("GET", previewPath, "cache-miss", 200)
	cache.readErr = errors.New("cache-private-error")
	send("GET", previewPath, "cache-offline", 200)
	cache.readErr = nil
	cache.key = previewPolicy.CachePrefix + refreshHash("https://example.com/")
	cache.raw = `{"url":"https://example.com/","title":"Cache content marker"}`
	send("GET", previewPath, "cache-hit", 200)
	send("POST", "/api/v2/ai/conversations/f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb/generate", "ai-quota-1", 429)

	body := testScrape(app, "Bearer "+testMetricsToken).Body.String()
	requireMetricLines(t, body,
		`nekotribe_redis_operations_total{result="hit"} 1`,
		`nekotribe_redis_operations_total{result="miss"} 1`,
		`nekotribe_redis_operations_total{result="degraded"} 2`,
		`nekotribe_ai_requests_total{operation="writing_draft",result="failure"} 1`,
		`nekotribe_ai_request_duration_seconds_bucket{operation="writing_draft",le="+Inf"} 1`,
		`nekotribe_ai_request_duration_seconds_count{operation="writing_draft"} 1`,
		`nekotribe_ai_quota_rejections_total{operation="writing_draft"} 1`)
	if !strings.Contains(logs.String(), `"event":"ai.run"`) ||
		strings.Count(logs.String(), `"request_id":"ai-quota-1"`) != 2 ||
		strings.Contains(logs.String(), "cache-private-error") || strings.Contains(logs.String(), "Cache content marker") ||
		strings.Contains(logs.String(), "f1b5c80f") {
		t.Fatal("missing correlated AI audit or leaked content in telemetry")
	}
}

func TestObservabilityHistogramAndSSEHandshake(t *testing.T) {
	metric := newTelemetry(testMetricsToken)
	metric.logger = slog.New(slog.DiscardHandler)
	metric.recordHTTP("PATCH", 200, .009)
	metric.recordHTTP("PATCH", 200, .4)
	metric.recordHTTP("PATCH", 200, 20)
	metric.recordAI("knowledge_answer", "insufficient_evidence", .08)
	metric.recordAI("knowledge_answer", "cancelled", .2)
	requireMetricLines(t, metric.renderMetrics(),
		`nekotribe_http_request_duration_seconds_bucket{method="PATCH",status="200",le="0.005"} 0`,
		`nekotribe_http_request_duration_seconds_bucket{method="PATCH",status="200",le="0.01"} 1`,
		`nekotribe_http_request_duration_seconds_bucket{method="PATCH",status="200",le="0.5"} 2`,
		`nekotribe_http_request_duration_seconds_bucket{method="PATCH",status="200",le="+Inf"} 3`,
		`nekotribe_http_request_duration_seconds_count{method="PATCH",status="200"} 3`,
		`nekotribe_ai_requests_total{operation="knowledge_answer",result="success"} 1`,
		`nekotribe_ai_requests_total{operation="knowledge_answer",result="cancelled"} 1`)

	started, release, finished := make(chan error, 1), make(chan struct{}), make(chan struct{})
	app := observedHTTP{metric, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		stream := &aiStreamResponse{ResponseWriter: w}
		started <- stream.delta("stream payload")
		<-release
		respond(stream, 200, 200, "success", nil)
	})}
	w := httptest.NewRecorder()
	go func() {
		defer close(finished)
		app.ServeHTTP(w, httptest.NewRequest("POST", "/api/v2/ai/conversations/example/generate", nil))
	}()
	err := <-started
	during := testScrape(app, "Bearer "+testMetricsToken).Body.String()
	close(release)
	<-finished
	if err != nil || !w.Flushed || w.Header().Get("X-Request-Id") == "" ||
		!strings.Contains(w.Body.String(), "event: delta") || !strings.Contains(w.Body.String(), "event: done") {
		t.Fatal("observed response writer did not preserve SSE")
	}
	requireMetricLines(t, during,
		`nekotribe_http_requests_total{method="POST",status="200"} 1`,
		`nekotribe_http_request_duration_seconds_count{method="POST",status="200"} 1`)
}

type observabilityChatFixture struct{}

func (observabilityChatFixture) SubscribeChatChannel(context.Context, int64) (<-chan []byte, func(), error) {
	return nil, nil, errors.New("remote chat transport unavailable")
}

func TestObservabilityWebSocketHandshakeAndDistinctLocalChannels(t *testing.T) {
	codec, tokens := fixture(t)
	sessions := &chatSocketTestSessions{}
	sessions.allowed.Store(true)
	handler := NewHandlerWithConfig(codec, sessions, CorsPolicy{}, RefreshConfig{
		NotificationEvents: &fakeSocketSource{queues: map[int64]chan []byte{}},
		ChatChannelEvents:  observabilityChatFixture{}, metricsToken: testMetricsToken,
	})
	app := httptest.NewServer(handler)
	defer app.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	endpoint := "ws" + strings.TrimPrefix(app.URL, "http") + "/_ws?token=" + url.QueryEscape(tokens["access-hs256"])
	connect := func(id string) *websocket.Conn {
		t.Helper()
		headers := http.Header{}
		headers.Set("X-Request-Id", id)
		conn, response, err := websocket.Dial(ctx, endpoint, &websocket.DialOptions{HTTPHeader: headers})
		if err != nil || response.Header.Get("X-Request-Id") != id {
			t.Fatalf("failed observed WebSocket upgrade: %v", err)
		}
		t.Cleanup(func() { _ = conn.CloseNow() })
		_ = socketRead(t, conn)
		return conn
	}
	a := connect("socket-a")
	b := connect("socket-b")
	check := func(connections, channels int) {
		t.Helper()
		lines := []string{fmt.Sprintf("nekotribe_websocket_connections %d", connections), fmt.Sprintf("nekotribe_websocket_channels %d", channels)}
		for {
			r, _ := http.NewRequestWithContext(ctx, "GET", app.URL+"/metrics", nil)
			r.Header.Set("Authorization", "Bearer "+testMetricsToken)
			response, err := app.Client().Do(r)
			if err != nil {
				t.Fatal(err)
			}
			body, err := io.ReadAll(response.Body)
			response.Body.Close()
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(string(body), "\n"+lines[0]+"\n") && strings.Contains(string(body), "\n"+lines[1]+"\n") {
				requireMetricLines(t, string(body), `nekotribe_http_requests_total{method="GET",status="101"} 2`)
				return
			}
			select {
			case <-ctx.Done():
				t.Fatalf("socket gauges did not converge to %v", lines)
			case <-time.After(10 * time.Millisecond):
			}
		}
	}
	check(2, 0)
	for _, conn := range []*websocket.Conn{a, b} {
		if err := conn.Write(ctx, websocket.MessageText, []byte(`{"type":"chat_join_channel","data":{"channelId":7}}`)); err != nil {
			t.Fatal(err)
		}
		if event := socketRead(t, conn); event["type"] != "system_notification" {
			t.Fatal("local channel was not joined")
		}
	}
	check(2, 1)
	if err := a.Write(ctx, websocket.MessageText, []byte(`{"type":"chat_leave_channel","data":{"channelId":7}}`)); err != nil {
		t.Fatal(err)
	}
	if err := b.Write(ctx, websocket.MessageText, []byte(`{"type":"chat_leave_channel","data":{"channelId":7}}`)); err != nil {
		t.Fatal(err)
	}
	check(2, 0)
	if err := b.Write(ctx, websocket.MessageText, []byte(`{"type":"chat_join_channel","data":{"channelId":7}}`)); err != nil {
		t.Fatal(err)
	}
	if event := socketRead(t, b); event["type"] != "system_notification" {
		t.Fatal("rejoined subscription was not acknowledged")
	}
	check(2, 1)
	_ = a.CloseNow()
	check(1, 1)
	_ = b.CloseNow()
	check(0, 0)
}
