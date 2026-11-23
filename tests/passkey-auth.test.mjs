import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, randomBytes, sign } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { Readable } from 'node:stream';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { test } from 'node:test';
import { isoCBOR } from '@simplewebauthn/server/helpers';
import { createEvent } from 'h3';
import { build } from 'esbuild';

const { sql } = JSON.parse(readFileSync(new URL('../specifications/requirements/passkey-auth.json', import.meta.url), 'utf8'));
const { sql: githubSql } = JSON.parse(readFileSync(new URL('../specifications/requirements/github-oauth.json', import.meta.url), 'utf8'));
const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(import.meta.url);
const stubs = {
  '../../database/readiness': 'export const requireFeatureSchema = async () => {};',
  './auth': 'export const v2LoginAfterVerifiedCredential = async (_event, _db, userId, remember) => ({code:200,data:{userId,remember}});',
  './api-cache': 'export const readApiResponseCache = async () => ({status:"disabled"}); export const writeApiResponseCache = async () => {}; export const invalidateApiResponseCache = async () => {}; export const shouldInvalidateApiResponseCache = () => false;',
  './logging': 'export const getRequestLogContext = () => null; export const logError = () => {}; export const logInfo = () => {}; export const serializeLogError = () => ({});',
  oracledb: 'export default {OUT_FORMAT_OBJECT:4002};',
};
const built = await build({
  stdin: { contents: `export * from './server/services/v2/passkey-auth'; export {userHandle} from './server/services/v2/passkey-webauthn';`, resolveDir: root },
  bundle: true, write: false, platform: 'node', format: 'esm', plugins: [{ name: 'passkey-db-fixture', setup(builder) {
    builder.onResolve({ filter: /.*/ }, ({ path }) => {
      if (Object.hasOwn(stubs, path)) return { path, namespace: 'fixture' };
      if (path.startsWith('node:')) return { path, external: true };
      if (path.startsWith('@simplewebauthn/server')) {
        return { path: new URL(path.endsWith('/helpers') ? '../node_modules/@simplewebauthn/server/esm/helpers/index.js' :
          '../node_modules/@simplewebauthn/server/esm/index.js', import.meta.url).href, external: true };
      }
      if (!path.startsWith('.')) return { path: pathToFileURL(require.resolve(path)).href, external: true };
    });
    builder.onLoad({ filter: /.*/, namespace: 'fixture' }, ({ path }) => ({ contents: stubs[path] }));
  } }],
});
const api = await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
const origin = 'https://accounts.example.com';
const rpId = 'accounts.example.com';
const digest = input => createHash('sha256').update(input).digest();
const b64 = bytes => Buffer.from(bytes).toString('base64url');

function browserCredential() {
  const keys = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const jwk = keys.publicKey.export({ format: 'jwk' });
  const credentialId = randomBytes(24);
  const fields = { id: b64(credentialId), rawId: b64(credentialId), type: 'public-key', clientExtensionResults: {} };
  const key = new Map([[1, 2], [3, -7], [-1, 1], [-2, Buffer.from(jwk.x, 'base64url')], [-3, Buffer.from(jwk.y, 'base64url')]]);
  function clientData(type, challenge, from) {
    return Buffer.from(JSON.stringify({ type, challenge, origin: from, crossOrigin: false }));
  }

  function authData(flags, counter) {
    const value = Buffer.alloc(37);
    digest(rpId).copy(value);
    value[32] = flags;
    value.writeUInt32BE(counter, 33);
    return value;
  }
  return {
    id: fields.id, jwk,
    registration(challenge) {
      const details = Buffer.alloc(18);
      details.writeUInt16BE(credentialId.length, 16);
      const auth = Buffer.concat([authData(0x45, 0), details, credentialId, isoCBOR.encode(key)]);
      const attestation = new Map([['fmt', 'none'], ['attStmt', new Map()], ['authData', auth]]);
      return { ...fields, response: { clientDataJSON: b64(clientData('webauthn.create', challenge, origin)), attestationObject: b64(isoCBOR.encode(attestation)) } };
    },
    assertion(challenge, { from = origin, flags = 0x05, handle = 42, counter = 1 } = {}) {
      const data = clientData('webauthn.get', challenge, from);
      const auth = authData(flags, counter);
      const signature = sign('sha256', Buffer.concat([auth, digest(data)]), keys.privateKey);
      return { ...fields, response: { clientDataJSON: b64(data), authenticatorData: b64(auth), signature: b64(signature), userHandle: b64(api.userHandle(handle)) } };
    },
  };
}

function apiEvent({ userId, session = 'sess-fixture', body, id } = {}) {
  const req = Readable.from(body ? [Buffer.from(JSON.stringify(body))] : []);
  req.method = body ? 'POST' : 'GET';
  const headers = new Map();
  const res = { setHeader: (key, value) => headers.set(key, value), getHeader: key => headers.get(key) };
  const event = createEvent(req, res);
  if (userId) event.context.auth = { userId, sessionId: session, type: 'access' };
  if (id) event.context.params = { credential_id: id };
  return event;
}

function repository() {
  const challenges = new Map();
  const credentials = new Map();
  const asRow = values => Object.fromEntries(Object.entries(values).map(([key, value]) => [key.toUpperCase(), value]));
  const owner = { USER_ID: 42, PASSWORD_HASH: 'no-local-password', USERNAME: 'fixture-user', DISPLAY_NAME: 'Fixture', IS_ACTIVE: 1, STATUS: 'active' };
  const rows = (...values) => ({ rows: values.filter(Boolean) });
  const written = rowsAffected => ({ rowsAffected });
  return {
    challenges, credentials, owner,
    async execute(statement, binds) {
      switch (statement) {
        case githubSql.linkForUser: throw Object.assign(new Error(), { code: 'ORA-00942' });
        case sql.owner:
        case sql.lockOwner: return rows(binds.user_id === 42 ? owner : null);
        case sql.credentialList: return rows(...[...credentials.values()].filter(entry => entry.USER_ID === binds.user_id));
        case sql.credentialRead: return rows(credentials.get(binds.credential_id));
        case sql.credentialInsert: {
          if (credentials.has(binds.credential_id)) throw Object.assign(new Error(), { code: 'ORA-00001' });
          credentials.set(binds.credential_id, asRow({ ...binds, created_at: new Date('2026-11-22T12:00:00Z'), last_used_at: null }));
          return written(1);
        }
        case sql.credentialUse: Object.assign(credentials.get(binds.credential_id), asRow({ ...binds, last_used_at: new Date('2026-11-22T12:10:00Z') })); return written(1);
        case sql.credentialDelete: return written(Number(credentials.delete(binds.credential_id)));
        case sql.challengePrune: return written(0);
        case sql.challengeInsert: challenges.set(binds.challenge_id, binds); return written(1);
        case sql.challengeLock: {
          const row = challenges.get(binds.challenge_id);
          return rows(row && !row.expired && Object.keys(binds).every(key => binds[key] === row[key]) ? asRow(row) : null);
        }
        case sql.challengeDelete: return written(Number(challenges.delete(binds.challenge_id)));
        default: assert.fail('Unexpected Passkey fixture query');
      }
    },
    async commit() {}, async rollback() {},
  };
}

test('registers a real ES256 fixture key and verifies the matching assertion exactly once', async t => {
  const before = { id: process.env.WEBAUTHN_RP_ID, origins: process.env.WEBAUTHN_ORIGINS };
  process.env.WEBAUTHN_RP_ID = rpId;
  process.env.WEBAUTHN_ORIGINS = origin;
  t.after(() => {
    for (const [key, value] of Object.entries({ WEBAUTHN_RP_ID: before.id, WEBAUTHN_ORIGINS: before.origins })) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
  });
  const db = repository();
  const browser = browserCredential();
  const registered = apiEvent({ userId: 42 });
  const begin = (await api.v2PasskeyOptions(registered, db, 'register')).data;
  assert.equal(begin.options.authenticatorSelection.residentKey, 'required');
  assert.deepEqual(begin.options.pubKeyCredParams.map(entry => entry.alg), [-7]);
  const registration = { challenge_id: begin.challenge_id, credential: browser.registration(begin.options.challenge), label: 'Test key' };
  await assert.rejects(api.v2PasskeyVerify(apiEvent({ userId: 42, session: 'other-session', body: registration }), db, 'register'), { statusCode: 401 });
  assert.equal(db.challenges.has(begin.challenge_id), true);
  const result = (await api.v2PasskeyVerify(apiEvent({ userId: 42, body: registration }), db, 'register')).data;
  assert.deepEqual(Object.keys(result.credential).sort(), ['created_at', 'credential_id', 'label', 'last_used_at']);
  assert.equal(result.credential.label, 'Test key');
  assert.equal(db.credentials.get(browser.id).PUBLIC_X, browser.jwk.x);
  assert.equal(db.credentials.get(browser.id).PUBLIC_Y, browser.jwk.y);

  async function signIn(options) {
    const begin = (await api.v2PasskeyOptions(apiEvent(), db, 'login')).data;
    const body = { challenge_id: begin.challenge_id, credential: browser.assertion(begin.options.challenge, options), remember_me: true };
    return { body, request: api.v2PasskeyVerify(apiEvent({ body }), db, 'login') };
  }
  for (const invalid of [{ from: 'https://different.example.com' }, { flags: 1 }, { handle: 21 }]) {
    const attempt = await signIn(invalid);
    await assert.rejects(attempt.request, { statusCode: 401 });
    assert.equal(db.challenges.has(attempt.body.challenge_id), false);
    assert.equal(db.credentials.get(browser.id).SIGN_COUNT, 0);
  }
  const completed = await signIn();
  assert.deepEqual((await completed.request).data, { userId: 42, remember: true });
  assert.equal(db.credentials.get(browser.id).SIGN_COUNT, 1);
  await assert.rejects(api.v2PasskeyVerify(apiEvent({ body: completed.body }), db, 'login'), { statusCode: 401 });
  await assert.rejects((await signIn({ counter: 1 })).request, { statusCode: 401 });

  await assert.rejects(api.v2DeletePasskey(apiEvent({ userId: 42, id: browser.id }), db), { statusCode: 409 });
  db.owner.PASSWORD_HASH = '$2b$10$' + 'a'.repeat(53);
  assert.equal((await api.v2DeletePasskey(apiEvent({ userId: 42, id: browser.id }), db)).data, null);
  assert.deepEqual((await api.v2ListPasskeys(apiEvent({ userId: 42 }), db)).data.credentials, []);
});
