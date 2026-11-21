// Real H3 middleware, JWT, route, safe error wrapper and response cache policy.
// Only Oracle/config storage and logging are isolated; no external services run.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';
import { createApp, createRouter, defineEventHandler, toNodeListener } from 'h3';
import jwt from 'jsonwebtoken';
import { listenForFetch } from './helpers/loopback-listener.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(import.meta.url);
const key = 'availability-http-isolated-test-key';
const marker = 'synthetic-driver-detail-must-not-escape';
const stubs = {
  './model-source': 'export const MAX_STORED_MODEL_REVISION=999999999999999; export async function configuredModelRouter(){throw Error("isolated missing configuration");}',
  '#imports': `export const useRuntimeConfig=()=>({accessSecret:${JSON.stringify(key)}});`,
  oracledb: 'export default {OUT_FORMAT_OBJECT:4002};',
  './logging': 'export const getRequestLogContext=()=>null; export const logInfo=()=>{}; export const logWarn=()=>{}; export const logError=()=>{}; export const serializeLogError=()=>({});',
  './cache-mode': 'export const cacheProcessEpoch="isolated"; export const singleBackendCacheEnabled=true;',
  './skill-config-store': `import {SkillRegistry} from './server/services/ai/skill-selection.ts'; export async function loadSkillRegistry(event,connection){return {registry:new SkillRegistry(await connection.configuration()),generation:1};}`
};
const built = await build({
  stdin: { contents: `
    export {default as cors} from './server/middleware/00-cors';
    export {default as auth} from './server/middleware/auth';
    export {default as availability} from './server/api/v2/ai/availability.get';
  `, resolveDir: root, loader: 'ts' },
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{ name: 'availability-http-boundaries', setup(builder) {
    builder.onResolve({ filter: /.*/ }, args => {
      if (Object.hasOwn(stubs, args.path)) return { path: args.path, namespace: 'isolated' };
      if (args.path.startsWith('~/')) return { path: path.join(root, `${args.path.slice(2)}.ts`) };
      if (args.path.startsWith('node:')) return { path: args.path, external: true };
      if (!args.path.startsWith('.') && !path.isAbsolute(args.path)) return { path: pathToFileURL(require.resolve(args.path)).href, external: true };
    });
    builder.onLoad({ filter: /.*/, namespace: 'isolated' }, args => ({ contents: stubs[args.path], resolveDir: root, loader: 'js' }));
  } }]
});
const routes = await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
const token = jwt.sign({ userId: 42, userName: 'fixture', type: 'access', sessionId: 'fixture-session', jti: 'fixture-jti' }, key, { expiresIn: 300 });

async function request({ credential = token, fault, enabled = ['knowledge-answer'], pathname = '/api/v2/ai/availability' } = {}) {
  const state = { opens: 0, closes: 0, touches: 0, reads: 0, cacheCalls: 0, errors: [] };
  const app = createApp({ onError(error) { state.errors.push(error); } });
  app.use(defineEventHandler(event => {
    event.context.redis = new Proxy({}, { get() { state.cacheCalls++; throw Error(marker); } });
    event.context.getOracleConnection = async () => {
      const index = ++state.opens;
      if ((fault === 'auth-open' && index === 1) || (fault === 'config-open' && index === 2)) throw Error(marker);
      return {
        async execute(statement, binds) {
          state.touches++;
          assert.match(statement, /UPDATE n_auth_sessions/);
          assert.equal(binds.userId, 42);
          if (fault === 'auth-touch') throw Error(marker);
          return { rowsAffected: fault === 'revoked' ? 0 : 1 };
        },
        async configuration() {
          assert.equal(index, 2);
          state.reads++;
          if (fault === 'config-read') throw Error(marker);
          return enabled;
        },
        async close() {
          state.closes++;
          if ((fault === 'auth-close' && index === 1) || (fault === 'config-close' && index === 2)) throw Error(marker);
        }
      };
    };
  }));
  app.use(routes.cors);
  app.use(routes.auth);
  const router = createRouter();
  router.get('/api/v2/ai/availability', routes.availability);
  app.use(router);
  const server = createServer(toNodeListener(app));
  const origin = await listenForFetch(server);
  try {
    const response = await fetch(origin + pathname, { headers: credential ? { Authorization: `Bearer ${credential}` } : {} });
    return { state, status: response.status, headers: response.headers, body: await response.json() };
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
}

test('unauthenticated AI responses are private before the route is reached', async () => {
  for (const credential of [null, 'invalid-token']) {
    const result = await request({ credential });
    assert.equal(result.status, 401);
    assert.equal(result.headers.get('cache-control'), 'private, no-store');
    assert.equal(result.state.opens, 0);
    assert.equal(result.state.reads, 0);
  }
});

test('v2 cache policy covers conversation and profile auth failures', async () => {
  const conversation = await request({ credential: null, pathname: '/api/v2/ai/conversations' });
  assert.equal(conversation.status, 401);
  assert.equal(conversation.headers.get('cache-control'), 'private, no-store');
  const profile = await request({ credential: null, pathname: '/api/v2/users/me' });
  assert.equal(profile.status, 401);
  assert.equal(profile.headers.get('cache-control'), 'private, no-store');
});

test('failed authentication never reads configuration and retains private headers', async () => {
  for (const fault of ['auth-open', 'auth-touch', 'auth-close', 'revoked']) {
    const result = await request({ fault });
    assert.equal(result.status, 401, fault);
    assert.equal(result.headers.get('cache-control'), 'private, no-store', fault);
    assert.equal(result.state.reads, 0, fault);
    assert(!JSON.stringify(result.body).includes(marker));
  }
});

test('availability reports uncached flags and safe Skill metadata from one configuration read', async () => {
  for (const enabled of [['knowledge-answer'], [], ['writing-draft', 'group-brief']]) {
    const result = await request({ enabled });
    assert.equal(result.status, 200);
    assert.deepEqual(result.body, {
      code: 200, message: 'success', data: {
        knowledge: enabled.includes('knowledge-answer'), writing: enabled.includes('writing-draft'),
        group: enabled.includes('group-brief'), moderation: enabled.includes('moderation-advice'),
        inference: { knowledge: false, writing: false, group: false, moderation: false },
        model_config_revision: null,
        skills: [
          { id: 'knowledge-answer', purpose: 'knowledge', version: 1, enabled: enabled.includes('knowledge-answer'), explicit_selection: true },
          { id: 'writing-draft', purpose: 'writing', version: 1, enabled: enabled.includes('writing-draft'), explicit_selection: true },
          { id: 'group-brief', purpose: 'group', version: 1, enabled: enabled.includes('group-brief'), explicit_selection: true },
          { id: 'moderation-advice', purpose: 'moderation', version: 1, enabled: enabled.includes('moderation-advice'), explicit_selection: true }
        ]
      }, meta: null
    });
    assert.equal(result.headers.get('cache-control'), 'private, no-store');
    assert.equal(result.state.reads, 1);
    assert.equal(result.state.closes, 2);
    assert.equal(result.state.cacheCalls, 0);
  }
});

test('post-auth configuration connection failures return sanitized unavailable responses', async () => {
  for (const fault of ['config-open', 'config-read', 'config-close']) {
    const result = await request({ fault });
    assert.equal(result.status, 503, fault);
    assert.equal(result.body.data.code, 50301, fault);
    assert.equal(result.headers.get('cache-control'), 'private, no-store', fault);
    assert(!JSON.stringify(result.body).includes(marker));
    assert(!result.state.errors.some(error => String(error).includes(marker)));
    assert.equal(result.state.reads, fault === 'config-open' ? 0 : 1);
    assert.equal(result.state.closes, fault === 'config-open' ? 1 : 2);
  }
});
