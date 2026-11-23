package server

import (
	"bufio"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

type telemetryPolicy struct {
	RequestIDHeader, RequestIDPattern, MetricsPath, TokenEnvironmentVariable, ContentType string
	BucketsSeconds                                                                        []float64
	HTTPMethods, AIOperations                                                             []string
	MetricFamilies                                                                        map[string]struct {
		Type string
	}
}

var observabilityPolicy = func() telemetryPolicy {
	var p telemetryPolicy
	if json.Unmarshal(contracts.Observability, &p) != nil || p.RequestIDHeader == "" || p.RequestIDPattern == "" ||
		p.MetricsPath != "/metrics" || p.TokenEnvironmentVariable == "" || p.ContentType == "" ||
		len(p.BucketsSeconds) == 0 || !slices.IsSorted(p.BucketsSeconds) ||
		len(p.HTTPMethods) == 0 || len(p.AIOperations) == 0 || len(p.MetricFamilies) == 0 {
		panic("invalid observability contract")
	}
	return p
}()

var requestIDPattern = regexp.MustCompile(observabilityPolicy.RequestIDPattern)
var telemetryLogger = slog.New(slog.NewJSONHandler(os.Stderr, nil))

type requestTelemetryKey struct{}

type requestTelemetry struct {
	id        string
	telemetry *telemetry
}

func requestTelemetryFrom(ctx context.Context) requestTelemetry {
	value, _ := ctx.Value(requestTelemetryKey{}).(requestTelemetry)
	return value
}

func correlationID(header http.Header) string {
	values := header.Values(observabilityPolicy.RequestIDHeader)
	if len(values) == 1 && requestIDPattern.MatchString(values[0]) {
		return values[0]
	}
	id, err := randomUUID()
	if err != nil {
		panic("request ID randomness unavailable")
	}
	return id
}

type observedHTTP struct {
	telemetry *telemetry
	next      http.Handler
}

func (h observedHTTP) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	id := correlationID(r.Header)
	w.Header().Set(observabilityPolicy.RequestIDHeader, id)
	ctx := context.WithValue(r.Context(), requestTelemetryKey{}, requestTelemetry{id, h.telemetry})
	path := r.URL.EscapedPath()
	method := r.Method
	if !slices.Contains(observabilityPolicy.HTTPMethods, method) {
		method = "OTHER"
	}
	writer := &observedResponseWriter{ResponseWriter: w, record: func(status int) {
		elapsed := time.Since(start)
		if path != observabilityPolicy.MetricsPath {
			h.telemetry.recordHTTP(method, status, elapsed.Seconds())
		}
		h.telemetry.logger.LogAttrs(ctx, slog.LevelInfo, "http.request.completed",
			slog.String("event", "http.request.completed"), slog.String("request_id", id),
			slog.String("method", method), slog.Int("status", status),
			slog.Int64("elapsed_ms", elapsed.Milliseconds()), slog.String("path", safeLogPath(path)))
	}}

	if path == observabilityPolicy.MetricsPath {
		h.telemetry.scrape(writer, r)
	} else {
		h.next.ServeHTTP(writer, r.WithContext(ctx))
	}
	if writer.status == 0 && !writer.hijacked {
		writer.observe(http.StatusOK)
	}
}

type observedResponseWriter struct {
	http.ResponseWriter
	status   int
	hijacked bool
	record   func(int)
}

func (w *observedResponseWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

// Record the first final header without waiting for an SSE body or upgraded socket.
func (w *observedResponseWriter) observe(status int) {
	if w.status == 0 {
		w.status = status
		w.record(status)
	}
}

func (w *observedResponseWriter) WriteHeader(status int) {
	w.ResponseWriter.WriteHeader(status)
	if status == http.StatusSwitchingProtocols || status >= 200 {
		w.observe(status)
	}
}

func (w *observedResponseWriter) Write(p []byte) (int, error) {
	w.observe(http.StatusOK)
	return w.ResponseWriter.Write(p)
}

func (w *observedResponseWriter) Flush() { _ = w.FlushError() }

func (w *observedResponseWriter) FlushError() error {
	err := http.NewResponseController(w.ResponseWriter).Flush()
	if err == nil {
		w.observe(http.StatusOK)
	}
	return err
}

func (w *observedResponseWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	conn, buffer, err := http.NewResponseController(w.ResponseWriter).Hijack()
	w.hijacked = err == nil
	return conn, buffer, err
}

func (t *telemetry) scrape(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodGet || !t.metricsEnabled {
		http.NotFound(w, r)
		return
	}
	values := r.Header.Values("Authorization")
	if len(values) != 1 {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	token, bearer := strings.CutPrefix(values[0], "Bearer ")
	digest := sha256.Sum256([]byte(token))
	if !bearer || subtle.ConstantTimeCompare(digest[:], t.scrapeToken[:]) != 1 {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	w.Header().Set("Content-Type", observabilityPolicy.ContentType)
	_, _ = io.WriteString(w, t.renderMetrics())
}

// Templates are from the contract, and never include request values.
type logPathNode struct {
	children map[string]*logPathNode
	param    *logPathNode
	template string
}

var logPaths = func() *logPathNode {
	var spec struct{ Paths map[string]json.RawMessage }
	if json.Unmarshal(contracts.V2OpenAPI, &spec) != nil || len(spec.Paths) == 0 {
		panic("invalid OpenAPI paths")
	}
	root := &logPathNode{}
	for path := range spec.Paths {
		node := root
		for segment := range strings.SplitSeq(strings.TrimPrefix(path, "/"), "/") {
			if strings.HasPrefix(segment, "{") && strings.HasSuffix(segment, "}") {
				if node.param == nil {
					node.param = &logPathNode{}
				}
				node = node.param
				continue
			}
			if node.children == nil {
				node.children = make(map[string]*logPathNode)
			}
			if node.children[segment] == nil {
				node.children[segment] = &logPathNode{}
			}
			node = node.children[segment]
		}
		node.template = path
	}
	return root
}()

func safeLogPath(path string) string {
	switch path {
	case "/api/health", "/api/ready", "/_ws", "/metrics":
		return path
	}
	if strings.HasPrefix(path, "/storage/") {
		return "/storage/{path}"
	}
	if len(path) <= 4096 {
		if template := logPaths.find(strings.Split(strings.TrimPrefix(path, "/"), "/")); template != "" {
			return template
		}
	}
	return "/{unmatched}"
}

func (n *logPathNode) find(segments []string) string {
	if n == nil {
		return ""
	}
	if len(segments) == 0 {
		return n.template
	}
	if template := n.children[segments[0]].find(segments[1:]); template != "" {
		return template
	}
	if segments[0] != "" {
		return n.param.find(segments[1:])
	}
	return ""
}

type telemetry struct {
	logger         *slog.Logger
	oracle         *sql.DB
	scrapeToken    [sha256.Size]byte
	metricsEnabled bool
	metrics        telemetryMetrics
}

func newTelemetry(token string) *telemetry {
	return &telemetry{logger: telemetryLogger, metricsEnabled: token != "",
		scrapeToken: sha256.Sum256([]byte(token)), metrics: newTelemetryMetrics()}
}
