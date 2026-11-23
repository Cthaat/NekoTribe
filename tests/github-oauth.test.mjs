import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { Readable } from 'node:stream';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { test } from 'node:test';
import { build } from 'esbuild';
import { createEvent } from 'h3';

const read = name => JSON.parse(readFileSync(new URL(`../specifications/requirements/${name}.json`, import.meta.url), 'utf8'));
const { sql, endpoints } = read('github-oauth');
const { sql: passkey, passwordHashPattern } = read('passkey-auth');
const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(import.meta.url);
const fixtureSecret = 'isolated-fixture-oauth-local';
const redirectUri = 'https://accounts.example.com/api/v2/auth/oauth/github/callback';
const digest = data => createHash('sha256').update(data).digest('hex');
const stubs = {
  '../../database/readiness': 'export const requireFeatureSchema = async () => {};',
  './auth': 'export const v2LoginAfterVerifiedCredential = async (_event, _db, userId, remember) => ({code:200,data:{userId,remember}});',
  './passkey-auth': `const format=new RegExp(${JSON.stringify(passwordHashPattern)});export const hasPasswordLogin=hash=>format.test(hash);`,
  './api-cache': 'export const readApiResponseCache = async () => ({status:"disabled"}); export const writeApiResponseCache = async () => {}; export const invalidateApiResponseCache = async () => {}; export const shouldInvalidateApiResponseCache = () => false;',
  oracledb: 'export default {OUT_FORMAT_OBJECT:4002};',
};
const built = await build({
  stdin: { contents: `export * from './server/services/v2/github-oauth'; export {createRequestLogContext} from './server/utils/logging'`, resolveDir: root },
  bundle: true, write: false, platform: 'node', format: 'esm', plugins: [{ name: 'github-authorization-fixtures', setup(builder) {
    builder.onResolve({ filter: /.*/ }, ({ path }) => {
      if (Object.hasOwn(stubs, path)) return { path, namespace: 'fixture' };
      if (path.startsWith('node:')) return { path, external: true };
      if (!path.startsWith('.')) return { path: pathToFileURL(require.resolve(path)).href, external: true };
    });
    builder.onLoad({ filter: /.*/, namespace: 'fixture' }, ({ path }) => ({ contents: stubs[path] }));
  } }],
});
const api = await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);

function event(db, { userId, sessionId = 'sess-original', url = '/', body, flowId } = {}) {
  const req = Readable.from(body ? [Buffer.from(JSON.stringify(body))] : []);
  req.url = url;
  req.method = body ? 'POST' : 'GET';
  req.headers = { host: 'accounts.example.com' };
  req.socket = { remoteAddress: '127.0.0.1' };
  const headers = new Map();
  const res = { statusCode: 200, setHeader: (key, value) => headers.set(key.toLowerCase(), value), getHeader: key => headers.get(key.toLowerCase()) };
  const context = createEvent(req, res);
  context.context.getOracleConnection = async () => { db.open++; return db; };
  if (userId) context.context.auth = { userId, sessionId, type: 'access' };
  if (flowId) context.context.params = { flow_id: flowId };
  return { context, headers, res };
}

function repository() {
  const flows = new Map();
  const links = new Map();
  const owner = { USER_ID: 42, PASSWORD_HASH: 'no-password' };
  const row = source => source ? { rows: [Object.fromEntries(Object.entries(source).map(([field, value]) => [field.toUpperCase(), value]))] } : { rows: [] };
  const count = rowsAffected => ({ rowsAffected });
  return { flows, links, owner, open: 0, hasPasskey: false,
    async execute(statement, args) {
      const flow = flows.get(args.flow_id);
      switch (statement) {
        case sql.prune: return count(0);
        case sql.begin: flows.set(args.flow_id, { ...args, status: 'pending' }); return count(1);
        case sql.callbackLock: return row([...flows.values()].find(flow => flow.state_hash === args.state_hash && flow.status === 'pending'));
        case sql.callbackClaim: flow.status = 'checking'; return count(1);
        case sql.callbackFinish: Object.assign(flow, args, { pkce_verifier: null }); return count(1);
        case sql.completeLock: return row(flow && Object.keys(args).every(key => args[key] === flow[key]) ? flow : null);
        case sql.completeConsume: return count(Number(flows.delete(args.flow_id)));
        case passkey.lockOwner: return row(args.user_id === 42 ? owner : null);
        case sql.linkForUser: return row(links.get(args.user_id));
        case sql.linkForGitHub: return row([...links.values()].find(link => link.github_user_id === args.github_user_id));
        case sql.linkCreate: links.set(args.user_id, { ...args, linked_at: new Date('2026-11-22T06:00:00Z') }); return count(1);
        case sql.linkRemove: return count(Number(links.delete(args.user_id)));
        case sql.passkeyCount: return row({ total: Number(this.hasPasskey) });
        default: assert.fail('Unexpected OAuth fixture query');
      }
    },
    async commit() {}, async rollback() {}, async close() { this.open--; },
  };
}

test('GitHub binds once to the original session and uses the resulting ID for login', async t => {
  const config = { GITHUB_OAUTH_CLIENT_ID: 'isolated-client', GITHUB_OAUTH_CLIENT_SECRET: fixtureSecret, GITHUB_OAUTH_REDIRECT_URI: redirectUri };
  const before = Object.fromEntries(Object.keys(config).map(key => [key, process.env[key]]));
  Object.assign(process.env, config);
  t.after(() => {
    for (const [key, value] of Object.entries(before)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
  });
  const db = repository();
  const calls = [];
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    assert.equal(db.open, 0);
    assert.equal(options.redirect, 'error');
    calls.push(url);
    if (url === endpoints.exchange) {
      assert.equal(options.body.get('client_secret'), fixtureSecret);
      assert.equal(options.body.get('redirect_uri'), redirectUri);
      return Response.json({ access_token: 'fixture-access-token' });
    }
    assert.equal(url, endpoints.profile);
    assert.equal(options.headers.Authorization, 'Bearer fixture-access-token');
    return Response.json({ id: 245, login: 'fixture-user', email: 'ignored@example.com' });
  });

  const start = async purpose => {
    const input = event(db, purpose === 'link' ? { userId: 42 } : {});
    const { data } = await api.v2StartGitHubOAuth(input.context, db, purpose);
    const uri = new URL(data.authorization_url);
    const state = uri.searchParams.get('state');
    const record = db.flows.get(data.flow_id);
    assert.equal(uri.origin + uri.pathname, endpoints.authorize);
    assert.equal(uri.searchParams.get('code_challenge_method'), 'S256');
    assert.equal(uri.searchParams.get('code_challenge'), Buffer.from(digest(record.pkce_verifier), 'hex').toString('base64url'));
    assert.equal(record.state_hash, digest(state));
    assert.equal(record.flow_key_hash, digest(data.flow_key));
    assert.ok(!data.authorization_url.includes(data.flow_key) && !data.authorization_url.includes(fixtureSecret));
    return { data, state };
  };
  const complete = (flow, purpose, input = {}) => api.v2CompleteGitHubOAuth(event(db, {
    ...(purpose === 'link' ? { userId: 42 } : {}), flowId: flow.data.flow_id,
    body: { flow_key: flow.data.flow_key, remember_me: true }, ...input,
  }).context, db, purpose);
  const callback = async (state, query = 'code=unit-fixture') => {
    const url = `/api/v2/auth/oauth/github/callback?state=${state}&${query}`;
    const requested = event(db, { url });
    const logged = api.createRequestLogContext(requested.context);
    assert.equal(logged.rawUrl, url.split('?')[0]);
    assert.deepEqual(logged.query, {});
    const html = await api.v2GitHubCallback(requested.context);
    assert.equal(requested.headers.get('referrer-policy'), 'no-referrer');
    assert.equal(requested.headers.get('cache-control'), 'private, no-store');
    for (const value of [state, 'unit-fixture', 'fixture-access-token', fixtureSecret]) assert.ok(!html.includes(value));
    return requested.res.statusCode;
  };

  const link = await start('link');
  assert.deepEqual((await complete(link, 'link')).data, { status: 'pending' });
  assert.equal(await callback(link.state), 200);
  assert.equal(await callback(link.state), 401);
  assert.equal(calls.length, 2);
  await assert.rejects(complete(link, 'link', { sessionId: 'sess-replaced' }), { statusCode: 401 });
  const linked = await complete(link, 'link');
  assert.equal(linked.data.link.github_user_id, '245');
  await assert.rejects(complete(link, 'link'), { statusCode: 401 });

  const login = await start('login');
  assert.equal(await callback(login.state), 200);
  await assert.rejects(complete(login, 'login', { body: { flow_key: 'A'.repeat(43) } }), { statusCode: 401 });
  assert.deepEqual((await complete(login, 'login')).data, { status: 'completed', login: { userId: 42, remember: true } });
  const cancelled = await start('login');
  assert.equal(await callback(cancelled.state, 'error=access_denied'), 401);
  await assert.rejects(complete(cancelled, 'login'), { statusCode: 401 });

  const owner = event(db, { userId: 42 }).context;
  await assert.rejects(api.v2DeleteGitHubLink(owner, db), { statusCode: 409 });
  db.hasPasskey = true;
  assert.equal((await api.v2DeleteGitHubLink(owner, db)).data, null);
  assert.deepEqual((await api.v2GetGitHubLink(owner, db)).data, { link: null });
});
