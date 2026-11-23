# Native backend observability

Nuxt, Go and Rust apply the same contract. No database migration is required.

## Request correlation

On every HTTP request, accept a single `X-Request-Id` matching the ASCII pattern in [the metric contract](observability.json). Generate a UUID v4 when the header is missing, invalid or repeated. Return the resulting ID on success, errors, preflight and the WebSocket handshake where supported by the server. Expose the header to allowed Web clients. Request completion logs and `ai.run` audits use that ID as `request_id`. Every request has an independent correlation context. Background work may omit an inbound request ID.

Log HTTP method, status, elapsed time and a sanitized path. Keep request bodies, cookie and Authorization headers, OAuth callback queries, link preview queries, prompts and upstream responses out of telemetry. Existing logs retain their redaction rules. Metric labels use finite values only. Scrape authorization values never enter logs, metrics, or responses.

## Scrape endpoint

`GET /metrics` is enabled by a nonempty server-side `METRICS_TOKEN`. With no token configured it returns 404. Otherwise it requires a single `Authorization: Bearer <METRICS_TOKEN>` and returns 401 if missing or wrong. Apply constant-time comparison and `Cache-Control: no-store`. Successful scrapes return current process metrics in UTF-8 Prometheus `text/plain; version=0.0.4; charset=utf-8`. Scrapes use process counters and in-memory connection state. Keep the endpoint off public ingress and send credentials over protected transport. Scrapes are excluded from HTTP metrics.

| Metric suffix after `nekotribe_` | Meaning |
| --- | --- |
| `http_requests_total` | Requests with known final HTTP status, including handled errors. Method is `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `OPTIONS`, `HEAD`, or `OTHER`. |
| `http_request_duration_seconds` | Time until response headers are ready. For SSE and upgrades measure the handshake, excluding stream lifetime. Labels match the request counter. |
| `oracle_pool_connections` | Driver pool connection counts `open`, `in_use`, `idle` from the existing native pool. Zero before initialization. |
| `redis_operations_total` | Cache reads grouped by `hit`, `miss`, `degraded`. Missing or unavailable Redis for an otherwise cache-eligible request is degradation. |
| `websocket_connections` | Active local accepted sockets. |
| `websocket_channels` | Distinct chat channels with at least one active local subscriber. |
| `ai_requests_total` | Audited app AI runs classified by operation and `success`, `failure`, `cancelled` (quota outcomes count as failure). Insufficient evidence is a successful handled outcome. |
| `ai_request_duration_seconds` | Elapsed audited AI run time in seconds, grouped by operation. |
| `ai_quota_rejections_total` | AI runs stopped by quota exhaustion or unavailability, grouped by operation. |

Emit cumulative histogram buckets and include `+Inf`, `_count` and `_sum`. Counters reset with the process. Emit zero gauges when the subsystem is inactive. The operation values match existing `ai.run` audit names. Prometheus identifies deployments using scrape target labels. [Prometheus exposition format](https://prometheus.io/docs/instrumenting/exposition_formats/)
