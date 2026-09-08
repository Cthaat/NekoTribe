// Runs real H3 middleware/routes, auth service, SQL helpers, JWT and bcrypt.
// Only Oracle, Redis/cache, logging, mail and profile/notification boundaries are isolated.
import assert from 'node:assert/strict';
import { before, test } from 'node:test';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import crypto from 'node:crypto';
import { build } from 'esbuild';
import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';
import { createApp, createRouter, defineEventHandler, setResponseHeader, toNodeListener } from 'h3';

const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(import.meta.url);
const runtime = { accessSecret: 'isolated-test-access-secret', refreshSecret: 'isolated-test-refresh-secret', accessExpiresIn: 900, refreshExpiresIn: 3600 };
const stubs = {
  '#imports': `export const useRuntimeConfig = () => (${JSON.stringify(runtime)});`,
  '~/server/models/v2': 'export const v2RequireSelfUser = async (_, id) => ({user_id: id, username: "test"});',
  './notifications': 'export const v2CreateNotification = async () => {};',
  './api-cache': 'export const readApiResponseCache = async () => ({status:"disabled"}); export const writeApiResponseCache = async () => {}; export const invalidateApiResponseCache = async () => {}; export const shouldInvalidateApiResponseCache = () => false;',
  './logging': 'export const getRequestLogContext = () => null; export const logError = () => {}; export const logInfo = () => {}; export const serializeLogError = () => ({});',
  oracledb: 'export default {OUT_FORMAT_OBJECT: 4002};',
  nodemailer: 'export default {createTransport(){throw new Error("Test forbids mail transport");}};'
};
const compiled = await build({
  stdin: { contents: `
    export {default as cors} from './server/middleware/00-cors';
    export {default as auth} from './server/middleware/auth';
    export {default as login} from './server/api/v2/auth/tokens.post';
    export {default as refresh} from './server/api/v2/auth/tokens/current.patch';
    export {default as logout} from './server/api/v2/auth/tokens/current.delete';
    export {default as twoFactor} from './server/api/v2/auth/two-factor/challenges.post';
  `, resolveDir: root, loader: 'ts' },
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{ name: 'isolated-boundaries', setup(builder) {
    builder.onResolve({filter: /.*/}, args => {
      if (Object.hasOwn(stubs, args.path)) return {path: args.path, namespace: 'test-stub'};
      if (args.path.startsWith('~/')) return {path: path.join(root, `${args.path.slice(2)}.ts`)};
      if (args.path.startsWith('node:') || ['crypto'].includes(args.path)) return {path: args.path, external: true};
      if (!args.path.startsWith('.') && !path.isAbsolute(args.path)) {
        return {path: pathToFileURL(require.resolve(args.path)).href, external: true};
      }
    });
    builder.onLoad({filter: /.*/, namespace: 'test-stub'}, args => ({contents: stubs[args.path], loader: 'js'}));
  }}]
});
const routes = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);
let passwordHash;
before(async () => { passwordHash = await bcrypt.hash('test-password', 4); });

function database({twoFactor = false, concurrentRefresh = false, concurrentChallenge = false} = {}) {
  const sessions = new Map();
  const challenges = new Map();
  let reads = [];
  const calls = [];
  const secret = 'JBSWY3DPEHPK3PXP';
  const cipher = crypto.createCipheriv('aes-256-gcm', crypto.createHash('sha256').update(runtime.refreshSecret).digest(), Buffer.alloc(12));
  const encrypted = Buffer.concat([cipher.update(secret), cipher.final()]);
  const db = {
    sessions, calls, close: async () => {},
    async execute(raw, binds = {}) {
      const sql = raw.replace(/\s+/g, ' ').trim();
      calls.push({sql, binds});
      const rows = values => ({rows: values});
      if (sql.startsWith('CREATE ')) return {rowsAffected: 0};
      if (sql.includes('WHERE email = :account')) return rows([{USER_ID: 1, USERNAME: 'test', PASSWORD_HASH: passwordHash, STATUS: 'active', IS_ACTIVE: 1}]);
      if (sql.includes('AS two_factor_enabled')) return rows([{TWO_FACTOR_ENABLED: Number(twoFactor), ENABLED_AT: twoFactor ? new Date() : null}]);
      if (sql.startsWith('SELECT COUNT')) return rows([{TOTAL: 1}]);
      if (sql.startsWith('INSERT INTO n_auth_sessions')) { sessions.set(binds.session_id, {...binds, revoked: false}); return {rowsAffected: 1}; }
      if (sql.startsWith('UPDATE n_users')) return {rowsAffected: 1};
      if (sql.startsWith('INSERT INTO n_auth_two_factor_challenges')) {challenges.set(binds.challenge_id, {...binds}); return {rowsAffected: 1};}
      if (sql.includes('FROM n_auth_two_factor_challenges c')) {
        const row = challenges.get(binds.challenge_id);
        const result = rows(row && !row.consumed ? [{USER_ID: 1, USERNAME: 'test', REMEMBER_ME: 0}] : []);
        if (concurrentChallenge) await new Promise(resolve => {reads.push(resolve); if (reads.length === 2) {reads.forEach(done => done()); reads = [];}});
        return result;
      }
      if (sql.includes('FROM n_user_two_factor_secrets')) return rows([{ENABLED_AT: new Date(), SECRET_ENCRYPTED: encrypted.toString('base64'), SECRET_IV: Buffer.alloc(12).toString('base64'), SECRET_AUTH_TAG: cipher.getAuthTag().toString('base64')}]);
      if (sql.includes('FROM n_user_two_factor_recovery_codes')) return rows([]);
      if (sql.startsWith('UPDATE n_auth_two_factor_challenges')) {
        const row = challenges.get(binds.challenge_id);
        if (sql.includes('AND consumed_at IS NULL') && row.consumed) return {rowsAffected: 0};
        if (sql.includes('AND expires_at > CURRENT_TIMESTAMP') && row.expires_at <= new Date()) return {rowsAffected: 0};
        row.consumed = true; return {rowsAffected: 1};
      }
      if (sql.startsWith('SELECT session_id, user_id')) {
        const row = sessions.get(binds.session_id);
        const result = rows(row && !row.revoked && row.refresh_token_hash === binds.refresh_token_hash && row.refresh_token_expires_at > new Date() ? [{SESSION_ID: row.session_id, USER_ID: row.user_id}] : []);
        if (concurrentRefresh) {
          await new Promise(resolve => {reads.push(resolve); if (reads.length === 2) {reads.forEach(done => done()); reads = [];}});
        }
        return result;
      }
      if (sql.startsWith('UPDATE n_auth_sessions')) {
        const row = sessions.get(binds.session_id ?? binds.sessionId);
        if (!row || row.revoked) return {rowsAffected: 0};
        if (sql.includes('refresh_token_hash = :old_refresh_token_hash') && row.refresh_token_hash !== binds.old_refresh_token_hash) return {rowsAffected: 0};
        if (sql.includes('AND refresh_token_hash = :refresh_token_hash') && row.refresh_token_hash !== binds.refresh_token_hash) return {rowsAffected: 0};
        if (sql.includes('AND access_jti = :access_jti') && row.access_jti !== binds.access_jti) return {rowsAffected: 0};
        if (sql.includes('AND access_jti = :accessJti') && row.access_jti !== binds.accessJti) return {rowsAffected: 0};
        if (sql.includes('AND access_token_expires_at > CURRENT_TIMESTAMP') && row.access_token_expires_at <= new Date()) return {rowsAffected: 0};
        if (sql.includes('SET revoked_at')) row.revoked = true;
        else if (sql.includes('SET access_jti')) Object.assign(row, binds);
        return {rowsAffected: 1};
      }
      throw new Error(`Unexpected isolated SQL: ${sql}`);
    },
    totp() {
      const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
      const bits = [...secret].map(char => alphabet.indexOf(char).toString(2).padStart(5, '0')).join('');
      const key = Buffer.from(bits.match(/.{8}/g).map(byte => parseInt(byte, 2)));
      const counter = Buffer.alloc(8); counter.writeBigUInt64BE(BigInt(Math.floor(Date.now() / 30000)));
      const digest = crypto.createHmac('sha1', key).update(counter).digest();
      return String((digest.readUInt32BE(digest.at(-1) & 15) & 0x7fffffff) % 1000000).padStart(6, '0');
    }
  };
  return db;
}

async function fixture(options) {
  const db = database(options);
  const app = createApp();
  app.use(defineEventHandler(event => {
    event.context.getOracleConnection = async () => db;
    setResponseHeader(event, 'Vary', 'Accept-Encoding');
  }));
  app.use(routes.cors);
  app.use(routes.auth);
  const router = createRouter();
  router.post('/api/v2/auth/tokens', routes.login);
  router.patch('/api/v2/auth/tokens/current', routes.refresh);
  router.delete('/api/v2/auth/tokens/current', routes.logout);
  router.post('/api/v2/auth/two-factor/challenges', routes.twoFactor);
  router.get('/api/v2/private', defineEventHandler(() => ({ok: true})));
  app.use(router);
  const server = createServer(toNodeListener(app));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  return {
    db,
    close: () => new Promise(resolve => server.close(resolve)),
    request: (url, method, body, headers = {}) => fetch(base + url, {method, headers: {...(body === undefined ? {} : {'content-type': 'application/json'}), ...headers}, body: body === undefined ? undefined : JSON.stringify(body)}),
    login: () => fetch(base + '/api/v2/auth/tokens', {method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify({account: 'test', password: 'test-password'})})
  };
}

function assertTokens(response, tokens) {
  assert.equal(typeof tokens.access_token, 'string');
  assert.equal(typeof tokens.refresh_token, 'string');
  assert.equal(jwt.verify(tokens.access_token, runtime.accessSecret).sessionId, tokens.session_id);
  assert.equal(jwt.verify(tokens.refresh_token, runtime.refreshSecret).type, 'refresh');
  const cookies = response.headers.getSetCookie();
  for (const name of ['access_token', 'refresh_token']) {
    const cookie = cookies.find(cookie => cookie.startsWith(`${name}=`));
    assert.ok(cookie.includes(`${name}=${tokens[name]}`));
    assert.match(cookie, /HttpOnly/i);
    assert.match(cookie, /SameSite=Lax/i);
    assert.match(cookie, /Path=\//i);
  }
}

test('login returns matching Cookie/body tokens; body refresh rotates immediately and rejects replay', async () => {
  const f = await fixture();
  try {
    const login = await f.login(); const first = (await login.json()).data.tokens;
    assertTokens(login, first);
    assert.equal((await f.request('/api/v2/private', 'GET', undefined, {authorization: `Bearer ${first.access_token}`})).status, 200);
    const now = Date.now; const fixed = now(); Date.now = () => fixed;
    let second, third;
    try {
      const refreshed = await f.request('/api/v2/auth/tokens/current', 'PATCH', {refresh_token: first.refresh_token});
      assert.equal(refreshed.status, 200); second = (await refreshed.json()).data; assertTokens(refreshed, second);
      const again = await f.request('/api/v2/auth/tokens/current', 'PATCH', {refresh_token: second.refresh_token});
      assert.equal(again.status, 200); third = (await again.json()).data;
      assert.notEqual(second.refresh_token, third.refresh_token);
    } finally { Date.now = now; }
    assert.equal((await f.request('/api/v2/auth/tokens/current', 'PATCH', {refresh_token: second.refresh_token})).status, 401);
    assert.equal((await f.request('/api/v2/private', 'GET', undefined, {authorization: `Bearer ${first.access_token}`})).status, 401);
    assert.equal((await f.request('/api/v2/private', 'GET', undefined, {authorization: `Bearer ${third.access_token}`})).status, 200);
  } finally { await f.close(); }
});

test('Cookie refresh has precedence over body and supports requests without JSON', async () => {
  const f = await fixture();
  try {
    const first = (await (await f.login()).json()).data.tokens;
    assert.equal((await f.request('/api/v2/auth/tokens/current', 'PATCH', {refresh_token: first.refresh_token}, {cookie: 'refresh_token=invalid'})).status, 401);
    const refreshed = await f.request('/api/v2/auth/tokens/current', 'PATCH', undefined, {cookie: `refresh_token=${first.refresh_token}`});
    assert.equal(refreshed.status, 200); assertTokens(refreshed, (await refreshed.json()).data);
    assert.equal((await f.request('/api/v2/auth/tokens/current', 'PATCH', {refresh_token: 123})).status, 401);
  } finally {await f.close();}
});

test('two-factor challenge returns no token; valid completion issues Cookie/body tokens', async () => {
  const f = await fixture({twoFactor: true});
  try {
    const login = await f.login(); const challenge = (await login.json()).data;
    assert.equal(challenge.two_factor_required, true); assert.equal(challenge.tokens, undefined); assert.deepEqual(login.headers.getSetCookie(), []);
    assert.equal((await f.request('/api/v2/auth/two-factor/challenges', 'POST', {challenge_id: challenge.challenge_id, code: 'invalid'})).status, 401);
    assert.equal(f.db.sessions.size, 0);
    const completed = await f.request('/api/v2/auth/two-factor/challenges', 'POST', {challenge_id: challenge.challenge_id, code: f.db.totp()});
    assert.equal(completed.status, 200); assertTokens(completed, (await completed.json()).data.tokens);
    assert.equal((await f.request('/api/v2/auth/two-factor/challenges', 'POST', {challenge_id: challenge.challenge_id, code: f.db.totp()})).status, 401);
  } finally {await f.close();}
});

test('parallel refresh consumes the stored refresh hash only once', async () => {
  const f = await fixture({concurrentRefresh: true});
  try {
    const tokens = (await (await f.login()).json()).data.tokens;
    const results = await Promise.all([1, 2].map(() => f.request('/api/v2/auth/tokens/current', 'PATCH', {refresh_token: tokens.refresh_token})));
    assert.deepEqual(results.map(response => response.status).sort(), [200, 401]);
    assert.deepEqual(results.find(response => response.status === 401).headers.getSetCookie(), []);
  } finally {await f.close();}
});

test('parallel two-factor completion consumes the challenge once and issues only one session', async () => {
  const f = await fixture({twoFactor: true, concurrentChallenge: true});
  try {
    const challenge = (await (await f.login()).json()).data;
    const code = f.db.totp();
    const responses = await Promise.all([1, 2].map(() => f.request('/api/v2/auth/two-factor/challenges', 'POST', {challenge_id: challenge.challenge_id, code})));
    assert.deepEqual(responses.map(response => response.status).sort(), [200, 401]);
    assert.equal(f.db.sessions.size, 1);
    assert.deepEqual(responses.find(response => response.status === 401).headers.getSetCookie(), []);
  } finally {await f.close();}
});

for (const mode of ['cookie', 'access-cookie', 'body', 'bearer']) {
  test(`logout via ${mode} revokes the session and clears cookies`, async () => {
    const f = await fixture();
    try {
      const tokens = (await (await f.login()).json()).data.tokens;
      const response = await f.request('/api/v2/auth/tokens/current', 'DELETE', mode === 'body' ? {refresh_token: tokens.refresh_token} : undefined,
        mode === 'cookie' ? {cookie: `refresh_token=${tokens.refresh_token}`} : mode === 'access-cookie' ? {cookie: `access_token=${tokens.access_token}`} : mode === 'bearer' ? {authorization: `Bearer ${tokens.access_token}`} : {});
      assert.equal(response.status, 200); assert.equal(f.db.sessions.get(tokens.session_id).revoked, true);
      assert.equal(response.headers.getSetCookie().filter(cookie => /Max-Age=0/.test(cookie)).length, 2);
      assert.equal((await f.request('/api/v2/private', 'GET', undefined, {authorization: `Bearer ${tokens.access_token}`})).status, 401);
      assert.equal((await f.request('/api/v2/auth/tokens/current', 'PATCH', {refresh_token: tokens.refresh_token})).status, 401);
    } finally {await f.close();}
  });
}

test('CORS allows configured preflight before auth, rejects origin/headers, merges Vary', async () => {
  const previous = process.env.CORS_ALLOWED_ORIGINS;
  process.env.CORS_ALLOWED_ORIGINS = 'https://flutter.example';
  const f = await fixture();
  try {
    const headers = {origin: 'https://flutter.example', 'access-control-request-method': 'GET', 'access-control-request-headers': 'Authorization, X-Device-Info'};
    const preflight = await f.request('/api/v2/private', 'OPTIONS', undefined, headers);
    assert.equal(preflight.status, 204); assert.equal(f.db.calls.length, 0);
    assert.equal(preflight.headers.get('access-control-allow-origin'), headers.origin);
    assert.match(preflight.headers.get('vary'), /Accept-Encoding/); assert.match(preflight.headers.get('vary'), /Origin/);
    for (const overrides of [{origin: 'https://evil.example'}, {'access-control-request-headers': 'x-unsupported'}, {'access-control-request-method': 'TRACE'}]) {
      const response = await f.request('/api/v2/private', 'OPTIONS', undefined, {...headers, ...overrides});
      assert.equal(response.status, 403); assert.equal(response.headers.get('access-control-allow-origin'), null);
    }
    const actual = await f.request('/api/v2/private', 'GET', undefined, {origin: headers.origin});
    assert.equal(actual.status, 401); assert.equal(actual.headers.get('access-control-allow-origin'), headers.origin);
  } finally {
    await f.close(); if (previous === undefined) delete process.env.CORS_ALLOWED_ORIGINS; else process.env.CORS_ALLOWED_ORIGINS = previous;
  }
});

test('absent, expired and wrong-signature refresh credentials fail before session writes', async () => {
  const f = await fixture();
  try {
    const payload = {userId: 1, sessionId: 'unknown-session', type: 'refresh'};
    for (const token of [undefined, 123, 'invalid', jwt.sign(payload, runtime.refreshSecret, {expiresIn: -1}), jwt.sign(payload, 'wrong-signature')]) {
      assert.equal((await f.request('/api/v2/auth/tokens/current', 'PATCH', {refresh_token: token})).status, 401);
    }
    assert.equal(f.db.calls.length, 0);
  } finally {await f.close();}
});

test('stale logout credentials and invalid Cookie cannot revoke a rotated session', async () => {
  const f = await fixture();
  try {
    const first = (await (await f.login()).json()).data.tokens;
    const current = (await (await f.request('/api/v2/auth/tokens/current', 'PATCH', {refresh_token: first.refresh_token})).json()).data;
    for (const [body, headers] of [
      [{refresh_token: first.refresh_token}, {}],
      [undefined, {authorization: `Bearer ${first.access_token}`}],
      [{refresh_token: current.refresh_token}, {cookie: 'refresh_token=invalid'}]
    ]) {
      assert.equal((await f.request('/api/v2/auth/tokens/current', 'DELETE', body, headers)).status, 200);
      assert.equal(f.db.sessions.get(first.session_id).revoked, false);
    }
  } finally {await f.close();}
});

test('production with COOKIE_SECURE=true retains Secure cookies and denies localhost origin', async () => {
  const original = {...process.env};
  process.env.NODE_ENV = 'production';
  process.env.COOKIE_SECURE = 'true';
  delete process.env.CORS_ALLOWED_ORIGINS; delete process.env.NUXT_CORS_ALLOWED_ORIGINS;
  delete process.env.CORS_ALLOW_LOCALHOST_ORIGINS; delete process.env.NUXT_CORS_ALLOW_LOCALHOST_ORIGINS;
  const f = await fixture();
  try {
    const response = await f.login();
    assert.equal(response.status, 200);
    for (const cookie of response.headers.getSetCookie()) assert.match(cookie, /; Secure/i);
    const preflight = await f.request('/api/v2/private', 'OPTIONS', undefined, {origin: 'http://localhost:5174', 'access-control-request-method': 'GET'});
    assert.equal(preflight.status, 403); assert.equal(preflight.headers.get('access-control-allow-origin'), null);
  } finally {
    await f.close();
    for (const key of ['NODE_ENV', 'COOKIE_SECURE', 'CORS_ALLOWED_ORIGINS', 'NUXT_CORS_ALLOWED_ORIGINS', 'CORS_ALLOW_LOCALHOST_ORIGINS', 'NUXT_CORS_ALLOW_LOCALHOST_ORIGINS']) {
      if (original[key] === undefined) delete process.env[key]; else process.env[key] = original[key];
    }
  }
});
