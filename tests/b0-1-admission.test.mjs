import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { once } from 'node:events';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';
import { createApp, defineEventHandler, toNodeListener } from 'h3';
import Redis from 'ioredis';
import { listenForFetch } from './helpers/loopback-listener.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(import.meta.url);
const vectors = JSON.parse(await readFile(new URL('../specifications/scenarios/b0-1-rate-limit.json', import.meta.url)));
const built = await build({
  stdin: { resolveDir: root, contents: [
    "export {default as admission} from './server/middleware/01-v2-admission'",
    "export {default as cors} from './server/middleware/00-cors'",
    "export {retiredSentimentOperation as retired} from './server/utils/sentiment-retirement'",
    "export {default as errorHandler} from './node_modules/nitropack/dist/runtime/internal/error/prod.mjs'"
  ].join('\n') }, bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{ name: 'h3', setup(b) {
    b.onResolve({filter: /^h3$/}, () => ({
      path: pathToFileURL(require.resolve('h3').replace(/\.cjs$/, '.mjs')).href, external: true
    }));
  } }]
});
const subject = await import('data:text/javascript;base64,' + Buffer.from(built.outputFiles[0].text).toString('base64'));

async function serve(t, redis, business = () => ({ok: true})) {
  const app = createApp({onError: subject.errorHandler});
  app.use(defineEventHandler(event => { event.context.redis = redis; }));
  app.use(subject.cors);
  app.use(subject.admission);
  app.use('/api/v2/integrations/sentiment-flow', subject.retired);
  app.use(defineEventHandler(business));
  const server = createServer(toNodeListener(app));
  const base = await listenForFetch(server);
  t.after(() => new Promise(resolve => server.close(resolve)));
  return (request, headers = {}) => {
    const [method, url] = request.split(' ');
    return fetch(base + url, { method, headers: {accept: 'application/json', ...headers} });
  };
}

test('B0.1 route tiers use operation and method, ignoring caller-controlled headers and query', async t => {
  const calls = [];
  const send = await serve(t, { eval: async (_, keys, key, limit, window) => {
    assert.equal(keys, 1);
    calls.push([key, limit, window]);
    return [1, limit - 1, window];
  } });
  const fixtures = vectors.cases.filter(v => v.expect.tier);
  for (const [request, tier] of [
    ['GET /api/v2/auth/sessions', 'read'], ['DELETE /api/v2/auth/tokens/current', 'write'],
    ['PATCH /api/v2/users/me/email', 'auth'], ['POST /api/v2/users/me/two-factor/confirm', 'auth'],
    ['POST /api/v2/users/me/ai-provider/test', 'ai'], ['PUT /api/v2/users/me/avatar', 'transfer'],
    ['POST /api/v2/posts?pretend=upload', 'write']
  ]) fixtures.push({input: {request}, expect: {tier, limit: {read:100, write:40}[tier] ?? 10,
    windowSeconds: ['read','write'].includes(tier) ? 10 : 60}});
  const trusted = process.env.TRUST_PROXY;
  delete process.env.TRUST_PROXY;
  t.after(() => { if (trusted === undefined) delete process.env.TRUST_PROXY; else process.env.TRUST_PROXY = trusted; });
  for (const {input, expect} of fixtures) {
    const response = await send(input.request, {'x-forwarded-for': '192.0.2.8', 'content-type': 'multipart/form-data'});
    assert.equal(response.status, 200, input.request);
    assert.deepEqual(calls.at(-1), ['neko:v2:admission:1:' + expect.tier + ':127.0.0.1', expect.limit, expect.windowSeconds * 1000]);
    assert.equal(Number(response.headers.get('RateLimit-Remaining')), expect.limit - 1);
  }
  process.env.TRUST_PROXY = '1';
  for (const [address, canonical] of [['::FFFF:c000:208','192.0.2.8'], ['2001:0DB8:0:0::8','2001:db8::8'], ['bad','127.0.0.1']]) {
    await send('POST /api/v2/auth/tokens', {'x-forwarded-for':address});
    assert.equal(calls.at(-1)[0], 'neko:v2:admission:1:auth:' + canonical);
  }
  delete process.env.TRUST_PROXY;
});

test('B0.1 HTTP rejects before dispatch, retains Nitro transport, CORS and cache boundary', async t => {
  const previous = process.env.CORS_ALLOWED_ORIGINS;
  process.env.CORS_ALLOWED_ORIGINS = 'https://app.example';
  t.after(() => { if (previous === undefined) delete process.env.CORS_ALLOWED_ORIGINS; else process.env.CORS_ALLOWED_ORIGINS = previous; });
  let calls = 0, dispatched = 0, ttl = 0;
  const send = await serve(t, {eval: async () => { calls++; return [0, 0, ttl]; }}, () => { dispatched++; return 'ok'; });
  for (const id of ['tier-rejection','head-rejection']) {
    const {input, expect} = vectors.cases.find(v => v.id === id);
    ttl = input.ttlMs;
    const response = await send(input.request, {origin:'https://app.example'});
    assert.equal(response.status, expect.status);
    assert.equal(response.headers.get('cache-control'), 'private, no-store');
    for (const [name, value] of Object.entries(expect.headers)) {
      assert.equal(response.headers.get(name), String(value));
      assert.ok(response.headers.get('access-control-expose-headers').toLowerCase().split(',').includes(name.toLowerCase()));
    }
    if (id === 'head-rejection') assert.equal((await response.arrayBuffer()).byteLength, 0);
    else {
      const body = await response.json();
      assert.equal(body.error, true);
      assert.equal(body.statusCode, 429);
      assert.ok(body.data.message);
      assert.deepEqual(body.data, {...expect.business, message: body.data.message});
    }
  }
  const retired = await send(vectors.cases.find(v => v.id === 'retired-before-admission').input.request);
  assert.equal(retired.status, 410);
  assert.equal((await send('OPTIONS /api/v2/auth/tokens')).status, 204);
  assert.deepEqual([calls, dispatched], [2, 0]);
  const failOpen = await serve(t, {eval: async () => { throw Error('offline'); }});
  assert.equal((await failOpen('GET /api/v2/posts')).status, 200);
});

test('B0.1 concurrent HTTP workers execute the production Lua against isolated Redis', async t => {
  const bin = process.env.REDIS_SERVER_BINARY || 'redis-server';
  if (spawnSync(bin, ['--version'], {windowsHide:true}).error?.code === 'ENOENT') {
    return t.skip('Set REDIS_SERVER_BINARY to run the isolated Redis integration');
  }
  const dir = await mkdtemp(path.join(tmpdir(), 'neko-admission-'));
  const probe = createServer();
  const port = new URL(await listenForFetch(probe)).port;
  await new Promise(resolve => probe.close(resolve));
  const password = randomBytes(24).toString('hex');
  const config = path.join(dir, 'redis.conf');
  await writeFile(config, ['bind 127.0.0.1', 'port ' + port, 'requirepass ' + password, 'save ""', 'appendonly no'].join('\n'));
  const child = spawn(bin, [config], {cwd:dir, stdio:'ignore', windowsHide:true});
  const exited = once(child, 'exit');
  const clients = [];
  t.after(async () => {
    for (const client of clients) client.disconnect();
    child.kill();
    await exited;
    await rm(dir, {recursive:true, force:true});
  });
  for (let i = 0; i < 3; i++) {
    const client = new Redis({host:'127.0.0.1', port:Number(port), password, retryStrategy:n => n < 40 ? 50 : null});
    client.on('error', () => {});
    clients.push(client);
    await client.ping();
  }
  let dispatched = 0;
  const workers = await Promise.all(clients.map(client => serve(t, client, () => {dispatched++; return 'ok';})));
  const race = vectors.cases.find(v => v.id === 'shared-race');
  const request = 'POST /api/v2/auth/tokens';
  const results = await Promise.all(workers.flatMap(send => Array.from({length:race.input.parallelPerBackend.nuxt}, () => send(request))));
  assert.equal(results.filter(r => r.status === 200).length, race.expect.admitted);
  assert.equal(results.filter(r => r.status === 429).length, race.expect.rejected);
  assert.equal(dispatched, race.expect.dispatched);
  const key = 'neko:v2:admission:1:auth:127.0.0.1';
  assert.equal(await clients[0].get(key), String(race.expect.admitted));
  await clients[0].pexpire(key, 850);
  const denied = await workers[0](request);
  assert.equal(denied.headers.get('Retry-After'), '1');
  assert.ok(await clients[0].pttl(key) <= 850);
  assert.equal((await workers[1]('GET /api/v2/posts')).status, 200);
  await delay(875);
  assert.equal((await workers[2](request)).status, 200);
  assert.equal(await clients[0].get(key), '1');
});
