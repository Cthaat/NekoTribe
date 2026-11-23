import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createServer, request } from 'node:http';
import { createRequire } from 'node:module';
import { test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';
import { createApp, createError, defineEventHandler, toNodeListener } from 'h3';

const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(import.meta.url);
const { outputFiles } = await build({
  stdin: {
    contents: `
      export { default as logging } from './server/plugins/03-log';
      export { default as metrics } from './server/routes/metrics.get';
      export { AiRunAudit } from './server/services/ai/run-audit';
      export { sessionManager } from './server/utils/wsSession';
      export { default as cors } from './server/middleware/00-cors';
      export { observeCacheRead } from './server/utils/observability';`,
    resolveDir: root,
  },
  define: { defineNitroPlugin: 'Object' },
  alias: { '~': root },
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{ name: 'isolated-driver', setup(builder) {
    builder.onResolve({ filter: /^h3$/ }, ({ path }) => ({
      path: pathToFileURL(require.resolve(path).replace(/\.cjs$/, '.mjs')).href, external: true
    }));
    builder.onResolve({ filter: /^(\.\.\/utils\/oracle|~\/server\/utils\/v2)$/ }, ({ path }) => ({ path, namespace: 'fixture' }));
    builder.onLoad({ filter: /.*/, namespace: 'fixture' }, ({ path }) => ({
      contents: path.endsWith('/oracle') ? 'export const oraclePoolMetrics = () => ({open: 4, inUse: 1});'
        : 'export const v2Throw = () => { throw new Error("unexpected"); };',
    }));
  } }],
});
const subject = await import(`data:text/javascript;base64,${Buffer.from(outputFiles[0].text).toString('base64')}`);

test('real HTTP responses, streams and scrape authorization share the native metrics and correlation context', { timeout: 6000 }, async t => {
  const oldToken = process.env.METRICS_TOKEN;
  const oldOrigins = process.env.CORS_ALLOWED_ORIGINS;
  delete process.env.METRICS_TOKEN;
  process.env.CORS_ALLOWED_ORIGINS = 'https://app.example.test';
  t.after(() => {
    if (oldToken === undefined) delete process.env.METRICS_TOKEN; else process.env.METRICS_TOKEN = oldToken;
    if (oldOrigins === undefined) delete process.env.CORS_ALLOWED_ORIGINS; else process.env.CORS_ALLOWED_ORIGINS = oldOrigins;
  });
  const requestHooks = [];
  subject.logging({ hooks: { hook: (name, handler) => {
    assert.equal(name, 'request');
    requestHooks.push(handler);
  } } });
  const app = createApp({ onRequest: event => requestHooks.forEach(hook => hook(event)) });
  app.use(subject.cors);
  app.use('/metrics', subject.metrics);
  app.use('/api/v2/links/preview', defineEventHandler(event => {
    new subject.AiRunAudit(event, 'knowledge_answer', 1).finish('quota_exhausted');
    subject.observeCacheRead('degraded');
    throw createError({ statusCode: 422 });
  }));
  let closeStream;
  app.use('/stream', defineEventHandler(({ node: { res } }) => {
    res.setHeader('Content-Type', 'text/event-stream');
    res.write('data: first\n\n');
    return new Promise(resolve => { closeStream = () => { res.end(); resolve(); }; });
  }));
  const server = createServer(toNodeListener(app));
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(async () => {
    closeStream?.();
    await new Promise(resolve => {
      server.close(resolve);
      server.closeAllConnections();
    });
  });
  const base = `http://127.0.0.1:${server.address().port}`;
  const calls = t.mock.method(console, 'info', () => {});
  assert.equal((await fetch(base + '/metrics')).status, 404);
  process.env.METRICS_TOKEN = 'local-fixture-only';
  assert.equal((await fetch(base + '/metrics')).status, 401);
  assert.equal((await fetch(base + '/metrics', { headers: { Authorization: 'Bearer wrong' } })).status, 401);
  const duplicated = await new Promise((resolve, reject) => {
    request(base + '/metrics', { headers: ['Host', new URL(base).host, 'Authorization', 'Bearer local-fixture-only', 'Authorization', 'Bearer local-fixture-only',
      'X-Request-Id', 'same', 'X-Request-Id', 'same'] }, response => {
      response.resume();
      resolve(response);
    }).on('error', reject).end();
  });
  assert.equal(duplicated.statusCode, 401);
  assert.match(duplicated.headers['x-request-id'], /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/);

  const error = await fetch(base + '/api/v2/links/preview?other=private-query', {
    headers: { Origin: 'https://app.example.test', 'X-Request-Id': 'offline:req-1' },
  });
  assert.equal(error.status, 422);
  assert.equal(error.headers.get('x-request-id'), 'offline:req-1');
  assert.match(error.headers.get('access-control-expose-headers'), /x-request-id/i);
  const stream = await fetch(base + '/stream', { headers: { 'X-Request-Id': 'offline/invalid' } });
  assert.notEqual(stream.headers.get('x-request-id'), 'offline/invalid');

  const peer = { send() {}, close() {} };
  subject.sessionManager.addSession('fixture-local-a', peer, { userId: 11, type: 'access' }, async () => true);
  subject.sessionManager.addSession('fixture-local-b', peer, { userId: 12, type: 'access' }, async () => true);
  for (const id of ['fixture-local-a', 'fixture-local-b']) {
    subject.sessionManager.joinRoom(id, 'chat:channel:55');
    t.after(() => subject.sessionManager.removeSession(id));
  }
  const scrape = () => fetch(base + '/metrics', { headers: { Authorization: 'Bearer local-fixture-only' } });
  const response = await scrape();
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.headers.get('content-type'), 'text/plain; version=0.0.4; charset=utf-8');
  const body = await response.text();
  assert.match(body, /nekotribe_http_requests_total\{method="GET",status="200"\} 1\n/);
  assert.match(body, /nekotribe_http_request_duration_seconds_bucket\{method="GET",status="422",le="\+Inf"\} 1\n/);
  assert.doesNotMatch(body, /status="(?:401|404)"/);
  assert.match(body, /nekotribe_oracle_pool_connections\{state="idle"\} 3\n/);
  assert.match(body, /nekotribe_redis_operations_total\{result="degraded"\} 1\n/);
  assert.match(body, /nekotribe_websocket_connections 2\n/);
  assert.match(body, /nekotribe_websocket_channels 1\n/);
  assert.match(body, /nekotribe_ai_requests_total\{operation="knowledge_answer",result="failure"\} 1\n/);
  assert.match(body, /nekotribe_ai_quota_rejections_total\{operation="knowledge_answer"\} 1\n/);
  closeStream();
  await stream.text();
  const logged = calls.mock.calls.map(call => call.arguments[1]);
  assert(logged.some(record => record.event === 'ai.run' && record.request_id === 'offline:req-1'));
  assert(logged.some(record => record.statusCode === 422 && record.request_id === 'offline:req-1'));
  assert.doesNotMatch(JSON.stringify(logged) + body, /private-query|local-fixture-only|offline\/invalid/);
});
