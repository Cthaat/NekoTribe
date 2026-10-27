import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import { test } from 'node:test';
import { build } from 'esbuild';
import bcrypt from 'bcrypt';
import { createApp, createError, createRouter, defineEventHandler, toNodeListener } from 'h3';
import { listenForFetch } from './helpers/loopback-listener.mjs';
import { schemaFixture } from './helpers/schema-fixture.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(import.meta.url);
const fakeSecret = 'synthetic-login-db-profile-password-token-DO-NOT-LOG';
const stubs = {
  '#imports': 'export const useRuntimeConfig = () => ({ accessSecret: "fixture-access", refreshSecret: "fixture-refresh", accessExpiresIn: 900, refreshExpiresIn: 3600 });',
  '~/server/models/v2': 'export const v2RequireSelfUser = async () => { throw new Error("synthetic-login-db-profile-password-token-DO-NOT-LOG"); };',
  './notifications': 'export const v2CreateNotification = async () => {};',
  './api-cache': 'export const readApiResponseCache = async () => ({status:"disabled"}); export const writeApiResponseCache = async () => {}; export const invalidateApiResponseCache = async () => {}; export const shouldInvalidateApiResponseCache = () => false;',
  oracledb: 'export default {OUT_FORMAT_OBJECT: 4002};',
  nodemailer: 'export default {createTransport(){throw new Error("mail disabled in tests");}};'
};
const compiled = await build({
  stdin: { contents: `
    export {default as login} from './server/api/v2/auth/tokens.post';
    export {default as challenge} from './server/api/v2/auth/two-factor/challenges.post';
    export {default as challengeById} from './server/api/v2/auth/two-factor/challenges/[id].post';
  `, resolveDir: root, loader: 'ts' },
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{ name: 'isolated-boundaries', setup(builder) {
    builder.onResolve({filter: /.*/}, args => {
      if (Object.hasOwn(stubs, args.path)) return {path: args.path, namespace: 'stub'};
      if (args.path.startsWith('~/')) return {path: path.join(root, `${args.path.slice(2)}.ts`)};
      if (args.path.startsWith('node:') || args.path === 'crypto') return {path: args.path, external: true};
      if (!args.path.startsWith('.') && !path.isAbsolute(args.path)) return {path: pathToFileURL(require.resolve(args.path)).href, external: true};
    });
    builder.onLoad({filter: /.*/, namespace: 'stub'}, args => ({contents: stubs[args.path], loader: 'js'}));
  }}]
});
const routes = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);
const passwordHash = await bcrypt.hash('fixture-password', 4);

async function fixture(failAt) {
  const schema = schemaFixture({ baseline: true });
  const sessions = [];
  const database = {
    async close() {},
    async execute(raw, binds = {}) {
      const sql = raw.replace(/\s+/g, ' ').trim();
      const metadata = schema.query(sql, binds);
      if (metadata !== undefined) {
        if (failAt === 'schema') throw new Error(fakeSecret);
        return {rows: metadata};
      }
      if (sql.includes('WHERE email = :account')) {
        if (failAt === 'login-db') throw new Error(fakeSecret);
        if (failAt === 'known-h3-with-cause') throw createError({statusCode: 401, message: '账号或密码错误', cause: new Error(fakeSecret), data: {code: 40101, message: '账号或密码错误', data: null, meta: null}});
        if (failAt === 'unknown-h3') throw createError({statusCode: 503, message: fakeSecret, data: {code: 50301, message: fakeSecret, data: null, meta: null}});
        if (failAt === 'unsafe-h3-getter') {
          const error = createError({statusCode: 401, message: '账号或密码错误'});
          Object.defineProperty(error, 'data', {get() { throw new Error(fakeSecret); }});
          throw error;
        }
        if (binds.account === 'missing') return {rows: []};
        return {rows: [{USER_ID: 1, USERNAME: 'test', PASSWORD_HASH: passwordHash, STATUS: binds.account === 'inactive' ? 'disabled' : 'active', IS_ACTIVE: binds.account === 'inactive' ? 0 : 1}]};
      }
      if (sql.includes('AS two_factor_enabled')) return {rows: [{TWO_FACTOR_ENABLED: 0, ENABLED_AT: null}]};
      if (sql.includes('FROM n_auth_two_factor_challenges c')) {
        if (failAt === 'challenge-disabled') return {rows: [{USER_ID: 1, USERNAME: 'test', REMEMBER_ME: 0}]};
        if (failAt === 'challenge-expired') return {rows: []};
        throw new Error(fakeSecret);
      }
      if (sql.includes('FROM n_user_two_factor_secrets') && failAt === 'challenge-disabled') return {rows: []};
      if (sql.startsWith('SELECT COUNT')) return {rows: [{TOTAL: 1}]};
      if (sql.startsWith('INSERT INTO n_auth_sessions')) { sessions.push(binds); return {rowsAffected: 1}; }
      if (sql.startsWith('UPDATE n_users')) return {rowsAffected: 1};
      throw new Error(`Unexpected isolated SQL ${sql}`);
    }
  };
  const app = createApp();
  app.use(defineEventHandler(event => { event.context.getOracleConnection = async () => database; }));
  const router = createRouter();
  router.post('/api/v2/auth/tokens', routes.login);
  router.post('/api/v2/auth/two-factor/challenges', routes.challenge);
  router.post('/api/v2/auth/two-factor/challenges/:id', routes.challengeById);
  app.use(router);
  const server = createServer(toNodeListener(app));
  const base = await listenForFetch(server);
  return {
    sessions,
    request: (url, body) => fetch(base + url, {method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify(body)}),
    requestRaw: (url, body) => fetch(base + url, {method: 'POST', headers: {'content-type': 'application/json'}, body}),
    close: () => new Promise(resolve => server.close(resolve))
  };
}

for (const [name, failAt, status] of [['known h3 cause', 'known-h3-with-cause', 401], ['unknown h3 error', 'unknown-h3', 500], ['throwing h3 getter', 'unsafe-h3-getter', 500]]) {
  test(`${name} cannot leak a driver error or cause`, async () => {
    const f = await fixture(failAt);
    const oldError = console.error;
    const logs = [];
    console.error = (...args) => logs.push(args);
    try {
      const response = await f.request('/api/v2/auth/tokens', {account: 'test', password: 'fixture-password'});
      assert.equal(response.status, status);
      assert.doesNotMatch(await response.text(), new RegExp(fakeSecret));
      assert.doesNotMatch(JSON.stringify(logs), new RegExp(fakeSecret));
    } finally { console.error = oldError; await f.close(); }
  });
}

test('malformed JSON remains a safe 400', async () => {
  const f = await fixture('login-db');
  try {
    const response = await f.requestRaw('/api/v2/auth/tokens', '{');
    assert.equal(response.status, 400);
  } finally { await f.close(); }
});

for (const [name, url, body, failAt, hasSession] of [
  ['login database', '/api/v2/auth/tokens', {account: 'test', password: 'fixture-password'}, 'login-db', false],
  ['login profile', '/api/v2/auth/tokens', {account: 'test', password: 'fixture-password'}, 'profile', true],
  ['challenge body route', '/api/v2/auth/two-factor/challenges', {challenge_id: 'test', code: '123456'}, 'challenge', false],
  ['challenge path route', '/api/v2/auth/two-factor/challenges/test', {code: '123456'}, 'challenge', false]
]) {
  test(`${name} hides unknown failures from HTTP and actual handler logging`, async () => {
    const f = await fixture(failAt);
    const oldError = console.error;
    const logs = [];
    console.error = (...args) => logs.push(args);
    try {
      const response = await f.request(url, body);
      assert.equal(response.status, 500);
      assert.deepEqual(response.headers.getSetCookie(), []);
      assert.doesNotMatch(await response.text(), new RegExp(fakeSecret));
      assert.doesNotMatch(JSON.stringify(logs), new RegExp(fakeSecret));
      assert.equal(f.sessions.length, Number(hasSession));
    } finally { console.error = oldError; await f.close(); }
  });
}

for (const [name, failAt, url, body, status, message] of [
  ['missing password', 'login-db', '/api/v2/auth/tokens', {account: 'test'}, 400, 'password 不能为空'],
  ['unknown account', 'profile', '/api/v2/auth/tokens', {account: 'missing', password: 'fixture-password'}, 401, '账号或密码错误'],
  ['wrong password', 'profile', '/api/v2/auth/tokens', {account: 'test', password: 'wrong'}, 401, '账号或密码错误'],
  ['inactive account', 'profile', '/api/v2/auth/tokens', {account: 'inactive', password: 'wrong'}, 403, '账号不可用'],
  ['expired challenge', 'challenge-expired', '/api/v2/auth/two-factor/challenges', {challenge_id: 'test', code: '123456'}, 401, '双因素验证已过期，请重新登录'],
  ['disabled two-factor', 'challenge-disabled', '/api/v2/auth/two-factor/challenges/test', {code: '123456'}, 422, '双因素认证尚未启用'],
  ['schema failure', 'schema', '/api/v2/auth/tokens', {account: 'test', password: 'fixture-password'}, 503, '服务暂不可用，请稍后重试。']
]) {
  test(`${name} preserves public business response without exposing raw errors`, async () => {
    const f = await fixture(failAt);
    const oldError = console.error;
    const logs = [];
    console.error = (...args) => logs.push(args);
    try {
      const response = await f.request(url, body);
      assert.equal(response.status, status);
      assert.deepEqual(response.headers.getSetCookie(), []);
      const result = await response.json();
      assert.equal(result.data.code, status * 100 + 1);
      assert.equal(result.data.message, message);
      assert.doesNotMatch(JSON.stringify(logs), new RegExp(fakeSecret));
    } finally { console.error = oldError; await f.close(); }
  });
}
