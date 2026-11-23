package server

import (
	"cmp"
	"database/sql"
	"fmt"
	"slices"
	"sort"
	"strings"
	"sync"
)

type latencyHistogram struct {
	buckets []uint64
	count   uint64
	sum     float64
}

func (h *latencyHistogram) observe(seconds float64) {
	if h.buckets == nil {
		h.buckets = make([]uint64, len(observabilityPolicy.BucketsSeconds))
	}
	first := sort.SearchFloat64s(observabilityPolicy.BucketsSeconds, seconds)
	if first < len(h.buckets) {
		h.buckets[first]++
	}
	h.count++
	h.sum += seconds
}

func (h latencyHistogram) render(out *strings.Builder, metric, labels string) {
	var cumulative uint64
	for i, boundary := range observabilityPolicy.BucketsSeconds {
		if len(h.buckets) > i {
			cumulative += h.buckets[i]
		}
		fmt.Fprintf(out, "%s_bucket{%s,le=%q} %d\n", metric, labels, fmt.Sprint(boundary), cumulative)
	}
	fmt.Fprintf(out, "%s_bucket{%s,le=\"+Inf\"} %d\n", metric, labels, h.count)
	fmt.Fprintf(out, "%s_count{%s} %d\n%s_sum{%s} %g\n", metric, labels, h.count, metric, labels, h.sum)
}

type httpMetricKey struct {
	method string
	status int
}

type aiRunMetrics struct {
	duration                    latencyHistogram
	success, failure, cancelled uint64
	quota                       uint64
}

type telemetryMetrics struct {
	mu                sync.Mutex
	http              map[httpMetricKey]*latencyHistogram
	ai                map[string]*aiRunMetrics
	cache             map[string]uint64
	socketConnections int
	socketChannels    map[int64]int
}

func newTelemetryMetrics() telemetryMetrics {
	ai := make(map[string]*aiRunMetrics, len(observabilityPolicy.AIOperations))
	for _, op := range observabilityPolicy.AIOperations {
		ai[op] = &aiRunMetrics{}
	}
	return telemetryMetrics{http: make(map[httpMetricKey]*latencyHistogram), ai: ai,
		cache: make(map[string]uint64, 3), socketChannels: make(map[int64]int)}
}

func (t *telemetry) recordHTTP(method string, status int, elapsed float64) {
	if status < 100 || status > 599 {
		return
	}
	t.metrics.mu.Lock()
	defer t.metrics.mu.Unlock()
	key := httpMetricKey{method, status}
	if t.metrics.http[key] == nil {
		t.metrics.http[key] = &latencyHistogram{}
	}
	t.metrics.http[key].observe(elapsed)
}

func (t *telemetry) recordAI(operation, outcome string, elapsed float64) {
	if t == nil {
		return
	}
	t.metrics.mu.Lock()
	defer t.metrics.mu.Unlock()
	run := t.metrics.ai[operation]
	if run == nil {
		return
	}
	run.duration.observe(elapsed)
	switch outcome {
	case "generated", "insufficient_evidence":
		run.success++
	case "cancelled":
		run.cancelled++
	case "quota_exhausted", "quota_unavailable":
		run.quota++
		run.failure++
	default:
		run.failure++
	}
}

func (t *telemetry) recordCache(result string) {
	if t == nil {
		return
	}
	t.metrics.mu.Lock()
	defer t.metrics.mu.Unlock()
	t.metrics.cache[result]++
}

func (t *telemetry) changeSocketConnections(delta int) {
	if t == nil {
		return
	}
	t.metrics.mu.Lock()
	defer t.metrics.mu.Unlock()
	t.metrics.socketConnections += delta
}

func (t *telemetry) changeSocketChannel(channelID int64, delta int) {
	if t == nil {
		return
	}
	t.metrics.mu.Lock()
	defer t.metrics.mu.Unlock()
	count := t.metrics.socketChannels[channelID] + delta
	if count <= 0 {
		delete(t.metrics.socketChannels, channelID)
	} else {
		t.metrics.socketChannels[channelID] = count
	}
}

func metricType(out *strings.Builder, name string) {
	fmt.Fprintf(out, "# TYPE %s %s\n", name, observabilityPolicy.MetricFamilies[name].Type)
}

func (t *telemetry) renderMetrics() string {
	const (
		httpCount    = "nekotribe_http_requests_total"
		httpDuration = "nekotribe_http_request_duration_seconds"
		oraclePool   = "nekotribe_oracle_pool_connections"
		cacheCount   = "nekotribe_redis_operations_total"
		socketCount  = "nekotribe_websocket_connections"
		channelCount = "nekotribe_websocket_channels"
		aiCount      = "nekotribe_ai_requests_total"
		aiDuration   = "nekotribe_ai_request_duration_seconds"
		aiQuota      = "nekotribe_ai_quota_rejections_total"
	)
	var out strings.Builder
	var pool sql.DBStats
	if t.oracle != nil {
		pool = t.oracle.Stats()
	}
	m := &t.metrics
	m.mu.Lock()
	defer m.mu.Unlock()

	keys := make([]httpMetricKey, 0, len(m.http))
	for key := range m.http {
		keys = append(keys, key)
	}
	slices.SortFunc(keys, func(a, b httpMetricKey) int {
		if byMethod := cmp.Compare(a.method, b.method); byMethod != 0 {
			return byMethod
		}
		return cmp.Compare(a.status, b.status)
	})
	metricType(&out, httpCount)
	for _, key := range keys {
		fmt.Fprintf(&out, "%s{%s} %d\n", httpCount, key.labels(), m.http[key].count)
	}
	metricType(&out, httpDuration)
	for _, key := range keys {
		m.http[key].render(&out, httpDuration, key.labels())
	}
	metricType(&out, oraclePool)
	fmt.Fprintf(&out, "%s{state=\"open\"} %d\n%s{state=\"in_use\"} %d\n%s{state=\"idle\"} %d\n",
		oraclePool, pool.OpenConnections, oraclePool, pool.InUse, oraclePool, pool.Idle)
	metricType(&out, cacheCount)
	for _, result := range []string{"hit", "miss", "degraded"} {
		fmt.Fprintf(&out, "%s{result=%q} %d\n", cacheCount, result, m.cache[result])
	}
	metricType(&out, socketCount)
	fmt.Fprintf(&out, "%s %d\n", socketCount, m.socketConnections)
	metricType(&out, channelCount)
	fmt.Fprintf(&out, "%s %d\n", channelCount, len(m.socketChannels))
	metricType(&out, aiCount)
	for _, op := range observabilityPolicy.AIOperations {
		run := m.ai[op]
		fmt.Fprintf(&out, "%s{operation=%q,result=\"success\"} %d\n%s{operation=%q,result=\"failure\"} %d\n%s{operation=%q,result=\"cancelled\"} %d\n",
			aiCount, op, run.success, aiCount, op, run.failure, aiCount, op, run.cancelled)
	}
	metricType(&out, aiDuration)
	for _, op := range observabilityPolicy.AIOperations {
		m.ai[op].duration.render(&out, aiDuration, fmt.Sprintf("operation=%q", op))
	}
	metricType(&out, aiQuota)
	for _, op := range observabilityPolicy.AIOperations {
		fmt.Fprintf(&out, "%s{operation=%q} %d\n", aiQuota, op, m.ai[op].quota)
	}
	return out.String()
}

func (k httpMetricKey) labels() string {
	return fmt.Sprintf("method=%q,status=\"%d\"", k.method, k.status)
}
