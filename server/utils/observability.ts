import { createHash, randomUUID, timingSafeEqual } from 'node:crypto';
import contract from '../../specifications/requirements/observability.json';

const requestIdPattern = new RegExp(contract.requestIdPattern);
const methods = new Set(contract.httpMethods);
const buckets = contract.bucketsSeconds;

export type AiOperation = 'knowledge_answer' | 'writing_draft' | 'group_draft' | 'moderation_advice' | 'image_description';
type AiResult = 'success' | 'failure' | 'cancelled';
type CacheResult = 'hit' | 'miss' | 'degraded';

interface Histogram {
  bins: number[];
  count: number;
  sum: number;
}

interface HttpSeries extends Histogram {
  method: string;
  status: number;
}

export const metricsContentType = contract.contentType;

export function correlationId(value: string | undefined | null): string {
  return value && requestIdPattern.exec(value)?.[0] === value ? value : randomUUID();
}

export function metricsStatus(token: string | undefined, authorization: string | string[] | undefined): 200 | 401 | 404 {
  if (!token) return 404;
  if (typeof authorization !== 'string' || !authorization.startsWith('Bearer ')) return 401;
  const digest = (text: string) => createHash('sha256').update(text).digest();
  return timingSafeEqual(digest(authorization.slice(7)), digest(token)) ? 200 : 401;
}

function newHistogram(): Histogram {
  return { bins: buckets.map(() => 0), count: 0, sum: 0 };
}

function observe(series: Histogram, seconds: number): void {
  series.count++;
  series.sum += seconds;
  buckets.forEach((limit, index) => {
    if (seconds <= limit) series.bins[index]!++;
  });
}

function histogramLines(name: string, labels: string, series: Histogram): string[] {
  const lines = buckets.map((limit, index) => `${name}_bucket{${labels},le="${limit}"} ${series.bins[index]}`);
  return [...lines, `${name}_bucket{${labels},le="+Inf"} ${series.count}`,
    `${name}_count{${labels}} ${series.count}`, `${name}_sum{${labels}} ${series.sum}`];
}

const httpSeries = new Map<string, HttpSeries>();
const redisReads: Record<CacheResult, number> = { hit: 0, miss: 0, degraded: 0 };
const aiSeries = new Map(contract.aiOperations.map(operation => [operation, {
  duration: newHistogram(), results: { success: 0, failure: 0, cancelled: 0 }, quotaRejections: 0
}]));

export function observeHttp(method: string, status: number, seconds: number): void {
  if (!Number.isInteger(status) || status < 100 || status > 599) return;
  const boundedMethod = methods.has(method) ? method : 'OTHER';
  const key = `${boundedMethod}/${status}`;
  let series = httpSeries.get(key);
  if (!series) {
    series = { method: boundedMethod, status, ...newHistogram() };
    httpSeries.set(key, series);
  }
  observe(series, seconds);
}

export function observeCacheRead(result: CacheResult): void {
  redisReads[result]++;
}

export function observeAi(operation: AiOperation, result: AiResult, seconds: number, quotaRejected: boolean): void {
  const series = aiSeries.get(operation)!;
  series.results[result]++;
  if (quotaRejected) series.quotaRejections++;
  observe(series.duration, seconds);
}

export function renderMetrics(pool: { open: number; inUse: number }, sockets: { connections: number; channels: number }): string {
  const metrics: Record<string, string[]> = {};
  for (const [name, { type }] of Object.entries(contract.metricFamilies)) {
    metrics[name] = [`# TYPE ${name} ${type}`];
  }
  const append = (name: keyof typeof contract.metricFamilies, ...samples: string[]) => metrics[name]!.push(...samples);
  for (const series of httpSeries.values()) {
    const labels = `method="${series.method}",status="${series.status}"`;
    append('nekotribe_http_requests_total', `nekotribe_http_requests_total{${labels}} ${series.count}`);
    append('nekotribe_http_request_duration_seconds', ...histogramLines('nekotribe_http_request_duration_seconds', labels, series));
  }
  for (const [state, value] of Object.entries({ open: pool.open, in_use: pool.inUse, idle: Math.max(0, pool.open - pool.inUse) })) {
    append('nekotribe_oracle_pool_connections', `nekotribe_oracle_pool_connections{state="${state}"} ${value}`);
  }
  for (const [result, value] of Object.entries(redisReads)) {
    append('nekotribe_redis_operations_total', `nekotribe_redis_operations_total{result="${result}"} ${value}`);
  }
  append('nekotribe_websocket_connections', `nekotribe_websocket_connections ${sockets.connections}`);
  append('nekotribe_websocket_channels', `nekotribe_websocket_channels ${sockets.channels}`);
  for (const [operation, series] of aiSeries) {
    const labels = `operation="${operation}"`;
    for (const [result, value] of Object.entries(series.results)) {
      append('nekotribe_ai_requests_total', `nekotribe_ai_requests_total{${labels},result="${result}"} ${value}`);
    }
    append('nekotribe_ai_request_duration_seconds', ...histogramLines('nekotribe_ai_request_duration_seconds', labels, series.duration));
    append('nekotribe_ai_quota_rejections_total', `nekotribe_ai_quota_rejections_total{${labels}} ${series.quotaRejections}`);
  }
  return Object.values(metrics).flat().join('\n') + '\n';
}
