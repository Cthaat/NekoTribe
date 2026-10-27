// Runs real H3 middleware/routes, auth service, SQL helpers, JWT and bcrypt.
// Only Oracle, Redis/cache, logging, mail and profile/notification boundaries are isolated.
import assert from 'node:assert/strict';
import { before, test } from 'node:test';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import crypto from 'node:crypto';
import { build } from 'esbuild';
import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';
import { createApp, createError, createRouter, defineEventHandler, setResponseHeader, toNodeListener } from 'h3';
import { schemaFixture } from './helpers/schema-fixture.mjs';
import { listenForFetch } from './helpers/loopback-listener.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(import.meta.url);
const runtime = { accessSecret: 'isolated-test-access-secret', refreshSecret: 'isolated-test-refresh-secret', accessExpiresIn: 900, refreshExpiresIn: 3600 };
const stubs = {
  '#imports': `export const useRuntimeConfig = () => (${JSON.stringify(runtime)});`,
  '~/server/models/v2': 'export const v2RequireSelfUser = async (_, id) => { if (globalThis.__loginProfileError) throw globalThis.__loginProfileError; return globalThis.__registrationProfile ?? {user_id: id, username: "test"}; };',
  './notifications': 'export const v2CreateNotification = async () => { if (globalThis.__loginAlertError) throw globalThis.__loginAlertError; };',
  './api-cache': 'export const readApiResponseCache = async () => ({status:"disabled"}); export const writeApiResponseCache = async () => {}; export const invalidateApiResponseCache = async () => {}; export const shouldInvalidateApiResponseCache = () => false;',
  './logging': 'export const getRequestLogContext = () => null; export const logError = (_, payload) => globalThis.__authCompatErrors?.push(payload); export const logInfo = () => {}; export const serializeLogError = error => ({message: error?.message, stack: error?.stack});',
  oracledb: 'export default {OUT_FORMAT_OBJECT: 4002};',
  nodemailer: 'export default {createTransport(options){if (!globalThis.__otpTestMail) throw new Error("Test forbids mail transport"); return {sendMail: async message => globalThis.__otpTestMail(options, message)};}};'
};
const compiled = await build({
  stdin: { contents: `
    export {default as cors} from './server/middleware/00-cors';
    export {default as auth} from './server/middleware/auth';
    export {default as login} from './server/api/v2/auth/tokens.post';
    export {default as refresh} from './server/api/v2/auth/tokens/current.patch';
    export {default as logout} from './server/api/v2/auth/tokens/current.delete';
    export {default as twoFactor} from './server/api/v2/auth/two-factor/challenges.post';
    export {default as verifyOtp} from './server/api/v2/auth/otp/verification.post';
    export {default as createOtp} from './server/api/v2/auth/otp.post';
    export {default as register} from './server/api/v2/auth/registration.post';
    export {default as resetPassword} from './server/api/v2/auth/password-reset.post';
    export {v2ListSessions} from './server/services/v2/auth';
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
test('session list preserves the SQL filters, pagination and current-session mapping', async () => {
  const calls = [];
  const connection = {async execute(sql, binds) {
    calls.push({sql: sql.replace(/\s+/g, ' ').trim(), binds});
    if (calls.length === 1) return {rows: [{TOTAL: 3}]};
    return {rows: [{SESSION_ID:'fixture-session-42',DEVICE_INFO:null,IP_ADDRESS:'127.0.0.1',LAST_ACCESSED_AT:new Date('2026-01-01T00:00:00Z'),CREATED_AT:null}]};
  }};
  const result = await routes.v2ListSessions({path:'/api/v2/auth/sessions?page=2&page_size=1',context:{auth:{userId:42,sessionId:'fixture-session-42'}}}, connection);
  assert.deepEqual(result,{code:200,message:'success',data:[{session_id:'fixture-session-42',device_info:'',ip_address:'127.0.0.1',last_accessed_at:'2026-01-01T00:00:00.000Z',created_at:'',is_current:true}],meta:{page:2,page_size:1,total:3,has_next:true}});
  assert.match(calls[0].sql,/user_id = :user_id AND revoked_at IS NULL/);
  assert.match(calls[1].sql,/ROW_NUMBER\(\) OVER \(ORDER BY last_accessed_at DESC\)/);
  assert.deepEqual(calls[1].binds,{user_id:42,start_row:2,end_row:2});
});
let passwordHash;
let recoveryHash;
before(async () => {
  passwordHash = await bcrypt.hash('test-password', 4);
  recoveryHash = await bcrypt.hash('ABCDEFGHIJKLMNO', 4);
});

test('shared bcrypt fixtures match the Nuxt password verifier, including byte truncation', async () => {
  const vectors = JSON.parse(readFileSync(path.join(root, 'specifications/scenarios/auth-bcrypt.json'), 'utf8'));
  assert.equal(vectors.id, 'AUTH-BCRYPT');
  for (const vector of vectors.cases) {
    assert.equal(await bcrypt.compare(vector.password, vector.hash), vector.valid, vector.id);
  }
});

test('shared 2FA ciphertext fixtures match the Nuxt AES-GCM format and reject tampering', () => {
  const vectors = JSON.parse(readFileSync(path.join(root, 'specifications/scenarios/auth-twofactor-crypto.json'), 'utf8'));
  assert.equal(vectors.id, 'AUTH-2FA-CRYPTO');
  for (const vector of vectors.cases) {
    let result = null;
    try {
      const key = crypto.createHash('sha256').update(vector.refreshSecret).digest();
      const decipher = crypto.createDecipheriv('aes-256-gcm', key, Buffer.from(vector.iv, 'base64'));
      decipher.setAuthTag(Buffer.from(vector.tag, 'base64'));
      result = Buffer.concat([decipher.update(Buffer.from(vector.encrypted, 'base64')), decipher.final()]).toString('utf8');
    } catch { /* invalid key or tag must not authenticate */ }
    assert.equal(result, vector.expected, vector.id);
  }
});

function database({twoFactor = false, concurrentRefresh = false, concurrentChallenge = false, concurrentRecovery = false, newDevice = false} = {}) {
  const schema = schemaFixture({ baseline: true });
  const sessions = new Map();
  const challenges = new Map();
  let reads = [];
  let recoveryReads = 0;
  let recoveryUsed = false;
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
      const metadata = schema.query(sql, binds);
      if (metadata !== undefined) return rows(metadata);
      if (sql.startsWith('SELECT verified_at FROM n_auth_otp_events WHERE account')) {
        if (db.registrationFault === 'otp') throw new Error('registration-internal-fixture');
        if (db.registrationFromOTP) {const otp=db.otp;return rows(otp?.verified && !otp.expired && otp.account===binds.account && otp.type===binds.otp_type && otp.verification_id===binds.verification_id ? [{VERIFIED_AT:new Date('2026-01-02T03:04:05Z')}] : []);}
        const r=db.registrationState;
        return rows(r && !r.otp && binds.account==='new@example.test' && binds.otp_type==='register' && binds.verification_id==='otp_fixture' ? [{VERIFIED_AT:new Date('2026-01-02T03:04:05Z')}] : []);
      }
      if (sql.startsWith('SELECT COUNT(*) AS total FROM n_users WHERE email')) {
        if (db.registrationFault === 'duplicate') throw new Error('registration-internal-fixture');
        return rows([{TOTAL:db.registrationState?.duplicate ? 1 : 0}]);
      }
      if (sql.startsWith('SELECT seq_user_id.NEXTVAL')) {
        if (db.registrationFault === 'sequence') throw new Error('registration-internal-fixture');
        return rows([{ID:123}]);
      }
      if (sql.startsWith('INSERT INTO n_users')) {
        if (db.registrationFault === 'insert') throw new Error('registration-internal-fixture');
        db.registrationInserts = (db.registrationInserts ?? 0)+1;db.registrationInserted=binds;return {rowsAffected:1};
      }
      if (sql.startsWith('SELECT seq_otp_event_id.NEXTVAL')) return rows([{ID:123}]);
      if (sql.startsWith('INSERT INTO n_auth_otp_events')) {
        if (db.otpCreateFault === 'insert') throw new Error('otp-create-private-fixture');
        db.otpCreated = binds; db.otpInserts = (db.otpInserts ?? 0) + 1; return {rowsAffected:1};
      }
      if (sql.startsWith('SELECT verification_code_hash FROM n_auth_otp_events')) {
        if (db.otpFault === 'lookup') throw new Error('otp-internal-sensitive-fixture');
        const otp = db.otp;
        return rows(otp && !otp.expired && otp.account === binds.account && otp.type === binds.otp_type && otp.verification_id === binds.verification_id ? [{VERIFICATION_CODE_HASH: otp.hash}] : []);
      }
      if (sql.startsWith('UPDATE n_auth_otp_events SET verified_at')) {
        if (db.otpFault === 'update') throw new Error('otp-internal-sensitive-fixture');
        db.otpUpdates = (db.otpUpdates ?? 0) + 1;
        if (db.otp) db.otp.verified=true;
        return {rowsAffected: 1};
      }
      if (sql.startsWith('SELECT verified_at FROM n_auth_otp_events')) {
        if (db.otpFault === 'readback') throw new Error('otp-internal-sensitive-fixture');
        return rows(db.resetEmptyReadback ? [] : [{VERIFIED_AT: new Date(db.otp.verified_at)}]);
      }
      if (sql.startsWith('UPDATE n_users SET password_hash')) {
        db.resetPasswordWrites = (db.resetPasswordWrites ?? 0) + 1;
        if (db.resetPasswordFault === 'write') throw new Error('reset-private-fixture');
        if (db.resetMissingUser) return {rowsAffected: 0};
        db.resetPasswordHash = binds.password_hash;
        assert.equal(binds.email, 'fake@example.test');
        return {rowsAffected: 1};
      }
      if (sql.includes('WHERE email = :account')) return rows([{USER_ID: 1, USERNAME: 'test', PASSWORD_HASH: passwordHash, STATUS: 'active', IS_ACTIVE: 1}]);
      if (sql.includes('AS two_factor_enabled')) return rows([{TWO_FACTOR_ENABLED: Number(twoFactor), ENABLED_AT: twoFactor ? new Date() : null}]);
      if (sql.startsWith('SELECT COUNT')) return rows([{TOTAL: newDevice ? 0 : 1}]);
      if (sql.includes('AS login_alerts')) return rows([{EMAIL: 'fixture@example.test', LOGIN_ALERTS: 1, EMAIL_NOTIFICATION_ENABLED: 1}]);
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
      if (sql.includes('FROM n_user_two_factor_recovery_codes')) {
        const result = rows(concurrentRecovery && !recoveryUsed ? [{RECOVERY_CODE_ID: 1, CODE_HASH: recoveryHash}] : []);
        if (concurrentRecovery && ++recoveryReads <= 2) await new Promise(resolve => {reads.push(resolve); if (reads.length === 2) {reads.forEach(done => done()); reads = [];}});
        return result;
      }
      if (sql.startsWith('UPDATE n_user_two_factor_recovery_codes')) {
        if (sql.includes('AND used_at IS NULL') && recoveryUsed) return {rowsAffected: 0};
        recoveryUsed = true; return {rowsAffected: 1};
      }
      if (sql.startsWith('UPDATE n_auth_two_factor_challenges')) {
        const row = challenges.get(binds.challenge_id);
        if (sql.includes('AND consumed_at IS NULL') && row.consumed) return {rowsAffected: 0};
        if (sql.includes('AND expires_at > CURRENT_TIMESTAMP') && row.expires_at <= new Date()) return {rowsAffected: 0};
        row.consumed = true; return {rowsAffected: 1};
      }
      if (sql.startsWith('SELECT session_id, user_id')) {
        const row = sessions.get(binds.session_id);
        const result = rows(row && row.user_id === binds.user_id && !row.revoked && row.refresh_token_hash === binds.refresh_token_hash && row.refresh_token_expires_at > new Date() ? [{SESSION_ID: row.session_id, USER_ID: row.user_id}] : []);
        if (concurrentRefresh) {
          await new Promise(resolve => {reads.push(resolve); if (reads.length === 2) {reads.forEach(done => done()); reads = [];}});
        }
        return result;
      }
      if (sql.startsWith('UPDATE n_auth_sessions')) {
        const row = sessions.get(binds.session_id ?? binds.sessionId);
        if (!row || row.revoked) return {rowsAffected: 0};
        if (row.user_id !== (binds.user_id ?? binds.userId)) return {rowsAffected: 0};
        if (sql.includes('refresh_token_hash = :old_refresh_token_hash') && row.refresh_token_hash !== binds.old_refresh_token_hash) return {rowsAffected: 0};
        if (sql.includes('AND refresh_token_expires_at > CURRENT_TIMESTAMP') && row.refresh_token_expires_at <= new Date()) return {rowsAffected: 0};
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
  router.post('/api/v2/auth/otp/verification', routes.verifyOtp);
  router.post('/api/v2/auth/otp', routes.createOtp);
  router.post('/api/v2/auth/registration', routes.register);
  router.post('/api/v2/auth/password-reset', routes.resetPassword);
  router.get('/api/v2/private', defineEventHandler(() => ({ok: true})));
  app.use(router);
  const server = createServer(toNodeListener(app));
  const base = await listenForFetch(server);
  return {
    db,
    close: () => new Promise(resolve => server.close(resolve)),
    request: (url, method, body, headers = {}) => fetch(base + url, {method, headers: {...(body === undefined ? {} : {'content-type': 'application/json'}), ...headers}, body: body === undefined ? undefined : JSON.stringify(body)}),
    refreshForm: token => fetch(base + '/api/v2/auth/tokens/current', {method: 'PATCH', headers: {'content-type': 'application/x-www-form-urlencoded', cookie: 'access_token=expired'}, body: new URLSearchParams({refresh_token: token})}),
    logoutForm: token => fetch(base + '/api/v2/auth/tokens/current', {method: 'DELETE', headers: {'content-type': 'application/x-www-form-urlencoded'}, body: new URLSearchParams({refresh_token: token})}),
    login: () => fetch(base + '/api/v2/auth/tokens', {method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify({account: 'test', password: 'test-password'})})
  };
}

test('shared password reset scenarios preserve validation, side effects and error privacy', async () => {
  const vectors = JSON.parse(readFileSync(path.join(root, 'specifications/scenarios/auth-password-reset.json'), 'utf8'));
  assert.equal(vectors.cases.length, 17);
  const f = await fixture();
  const otpHash = await bcrypt.hash('123456', 4);
  globalThis.__authCompatErrors = [];
  try {
    for (const vector of vectors.cases) {
      f.db.otp = {account:'fake@example.test',type:'password_reset',verification_id:'otp_fixture',hash:otpHash,verified_at:'2026-01-02T03:04:05.000Z',expired:!!vector.expired};
      f.db.otpUpdates = 0;
      f.db.otpFault = vector.fault === 'mark' ? 'update' : vector.fault;
      f.db.resetPasswordWrites = 0;
      f.db.resetPasswordFault = vector.fault;
      f.db.resetMissingUser = !!vector.missing_user;
      f.db.resetEmptyReadback = !!vector.empty_readback;
      f.db.resetPasswordHash = null;
      const response = await f.request('/api/v2/auth/password-reset', 'POST', {...vectors.base,...vector.patch}, {cookie:'access_token=expired'});
      const text = await response.text();
      assert.equal(response.status, vector.status, vector.id);
      assert.equal(f.db.otpUpdates, vector.marks, vector.id);
      assert.equal(f.db.resetPasswordWrites, vector.writes, vector.id);
      assert.equal(response.headers.getSetCookie().length, 0, vector.id);
      assert.doesNotMatch(text, /synthetic-new-password|reset-private-fixture|otp-internal-sensitive-fixture/, vector.id);
      const result = JSON.parse(text);
      assert.equal(response.status === 200 ? result.message : result.data?.message, vector.message, vector.id);
      if (vector.status === 200) {
        assert.deepEqual(result, {code:200,message:'password reset success',data:null,meta:null}, vector.id);
        assert.ok(await bcrypt.compare(String(vector.patch.new_password ?? vectors.base.new_password).trim(), f.db.resetPasswordHash), vector.id);
      }
    }
    assert.doesNotMatch(JSON.stringify(globalThis.__authCompatErrors), /reset-private-fixture|otp-internal-sensitive-fixture/);
  } finally { await f.close(); delete globalThis.__authCompatErrors; }
});

test('isolated OTP creation, verification and registration form one Nuxt flow', async () => {
  const vectors=JSON.parse(readFileSync(path.join(root,'specifications/scenarios/auth-registration.json'),'utf8'));const f=await fixture();let code;
  globalThis.__registrationProfile=vectors.profile;globalThis.__otpTestMail=async (_,message)=>{code=message.text.match(/\b\d{6}\b/)?.[0];};
  try {
    const created=await f.request('/api/v2/auth/otp','POST',{account:vectors.base.email,type:'register'});assert.equal(created.status,200);const data=(await created.json()).data;
    f.db.otp={account:data.account,type:'register',verification_id:data.verification_id,hash:f.db.otpCreated.verification_code_hash,verified_at:'2026-01-02T03:04:05.000Z'};
    f.db.registrationFromOTP=true;const early=await f.request('/api/v2/auth/registration','POST',{...vectors.base,verification_id:data.verification_id});assert.equal(early.status,422);
    const verified=await f.request('/api/v2/auth/otp/verification','POST',{account:data.account,type:'register',verification_id:data.verification_id,code});assert.equal(verified.status,200);
    const registered=await f.request('/api/v2/auth/registration','POST',{...vectors.base,verification_id:data.verification_id});assert.equal(registered.status,200);assert.equal((await registered.json()).data.user.user_id,123);assert.equal(registered.headers.getSetCookie().length,0);
  } finally {delete globalThis.__registrationProfile;delete globalThis.__otpTestMail;await f.close();}
});

test('shared registration scenarios preserve validation, commits and error privacy', async () => {
  const vectors=JSON.parse(readFileSync(path.join(root,'specifications/scenarios/auth-registration.json'),'utf8'));
  const f=await fixture();const oldError=console.error;console.error=()=>{};globalThis.__authCompatErrors=[];
  try {
    assert.equal(vectors.hashInterop.hashes.length,2);for(const sample of vectors.hashInterop.hashes){assert.ok(await bcrypt.compare(vectors.hashInterop.password,sample.hash));assert.equal(await bcrypt.compare(vectors.hashInterop.wrongPassword,sample.hash),false);}
    for (const vector of vectors.cases) {
      f.db.registrationState=vector;f.db.registrationFault=vector.fault;f.db.registrationInserts=0;f.db.registrationInserted=null;
      globalThis.__registrationProfile=vectors.profile;globalThis.__loginProfileError=vector.fault==='profile'?new Error('registration-internal-fixture'):vector.profile_missing?createError({statusCode:404,message:'用户不存在',data:{code:40401,message:'用户不存在',data:null,meta:null}}):null;
      const body={...vectors.base,...vector.patch};const startCalls=f.db.calls.length;const response=await f.request('/api/v2/auth/registration','POST',body,{cookie:'access_token=expired'});const text=await response.text();
      assert.equal(response.status,vector.status,vector.id);assert.equal(response.headers.getSetCookie().length,0,vector.id);assert.equal(f.db.registrationInserts,vector.inserts,vector.id);assert.doesNotMatch(text,/registration-internal-fixture|synthetic-password/,vector.id);
      if(vector.status===200){assert.deepEqual(JSON.parse(text).data.user,vectors.profile,vector.id);assert.ok(await bcrypt.compare(body.password.trim(),f.db.registrationInserted.password_hash));assert.equal(f.db.registrationInserted.user_id,123);const calls=f.db.calls.slice(startCalls);assert.match(calls[0].sql,/expires_at > CURRENT_TIMESTAMP AND verified_at IS NOT NULL/);assert.deepEqual(calls[0].binds,{account:'new@example.test',otp_type:'register',verification_id:'otp_fixture'});assert.match(calls[1].sql,/email = :email OR username = :username/);assert.match(calls[3].sql,/TO_DATE\(:birth_date, 'YYYY-MM-DD'\)/);if(vector.expected_phone!==undefined)assert.equal(f.db.registrationInserted.phone,vector.expected_phone,vector.id);if(vector.id==='REG-19'){assert.equal(f.db.registrationInserted.bio,'  retained  ');assert.equal(f.db.registrationInserted.location,'false');assert.equal(f.db.registrationInserted.phone,'123');}}
    }
    assert.doesNotMatch(JSON.stringify(globalThis.__authCompatErrors),/registration-internal-fixture|synthetic-password/);
  } finally {console.error=oldError;delete globalThis.__authCompatErrors;delete globalThis.__registrationProfile;delete globalThis.__loginProfileError;await f.close();}
});

test('shared OTP creation scenarios preserve commits, safe failures and delivery boundaries', async () => {
  const vectors = JSON.parse(readFileSync(path.join(root, 'specifications/scenarios/auth-otp-creation.json'), 'utf8'));
  const f = await fixture(); const oldError = console.error; console.error = () => {};
  const keys = ['SMTP_HOST','NUXT_SMTP_HOST','SMTP_PORT','NUXT_SMTP_PORT','SMTP_USER','NUXT_SMTP_USER','SMTP_PASS','NUXT_SMTP_PASS'];
  const original = Object.fromEntries(keys.map(key => [key,process.env[key]]));
  for (const key of keys) delete process.env[key];
  process.env.SMTP_HOST = 'unused.example.test'; process.env.NUXT_SMTP_HOST = 'mail.example.test';
  process.env.SMTP_PORT = '2465'; process.env.SMTP_USER = 'sender@example.test'; process.env.SMTP_PASS = 'synthetic-mail-password';
  globalThis.__authCompatErrors = [];
  try {
    for (const vector of vectors.cases) {
      f.db.otpInserts = 0; f.db.otpCreated = null; f.db.otpCreateFault = vector.fault; let sent = 0; let mail;
      globalThis.__otpTestMail = async (config, message) => {sent++; mail = message; assert.equal(config.host,'mail.example.test'); assert.equal(config.port,2465); assert.equal(config.auth.user,'sender@example.test'); assert.equal(config.secure,true); assert.equal(f.db.otpInserts,1,vector.id); if (vector.fault === 'mail') throw new Error('otp-create-private-fixture');};
      const start = Date.now();
      const response = await f.request('/api/v2/auth/otp', 'POST', vector.body, {cookie:'access_token=expired'});
      const text = await response.text(); assert.equal(response.status,vector.status,vector.id); assert.doesNotMatch(text,/otp-create-private-fixture/,vector.id);
      assert.equal(response.headers.getSetCookie().length,0,vector.id); assert.equal(f.db.otpInserts,vector.inserts,vector.id); assert.equal(sent,vector.sends,vector.id);
      if (vector.status === 200) {
        const data = JSON.parse(text).data; const code = mail.text.match(/\b\d{6}\b/)?.[0];
        assert.match(data.verification_id,/^otp_[0-9a-f-]{36}$/); assert.equal(data.account,'fake@example.test');
        assert.ok(Date.parse(data.expires_at) >= start+300000 && Date.parse(data.expires_at) <= Date.now()+300000);
        assert.ok(code && await bcrypt.compare(code,f.db.otpCreated.verification_code_hash)); assert.equal(f.db.otpCreated.verification_id,data.verification_id);
        assert.equal(text.includes(code),false,vector.id);
        f.db.otp = {account:data.account,type:f.db.otpCreated.otp_type,verification_id:data.verification_id,hash:f.db.otpCreated.verification_code_hash,verified_at:'2026-01-02T03:04:05.000Z'};
        const verified = await f.request('/api/v2/auth/otp/verification','POST',{account:data.account,type:f.db.otpCreated.otp_type,verification_id:data.verification_id,code});
        assert.equal(verified.status,200,vector.id);
      }
    }
    assert.doesNotMatch(JSON.stringify(globalThis.__authCompatErrors),/otp-create-private-fixture|synthetic-mail-password/);
  } finally {for (const key of keys) original[key] === undefined ? delete process.env[key] : process.env[key] = original[key]; delete globalThis.__authCompatErrors; delete globalThis.__otpTestMail; console.error = oldError; await f.close();}
});

test('shared OTP verification scenarios use the real Nuxt route and bcrypt', async () => {
  const vectors = JSON.parse(readFileSync(path.join(root, 'specifications/scenarios/auth-otp-verification.json'), 'utf8'));
  assert.equal(vectors.cases.length, 16);
  const f = await fixture();
  const oldConsoleError = console.error; const consoleErrors = []; globalThis.__authCompatErrors = [];
  console.error = (...args) => consoleErrors.push(args.map(String).join(' '));
  try {
    for (const vector of vectors.cases) {
      f.db.otp = {...vectors.fixture, expired: !!vector.expired}; f.db.otpFault = vector.fault; f.db.otpUpdates = 0;
      const count = vector.repeat ? 2 : 1;
      for (let i = 0; i < count; i++) {
        const response = await f.request('/api/v2/auth/otp/verification', 'POST', vector.body, {cookie:'access_token=expired'});
        assert.equal(response.status,vector.status, vector.id);
        assert.equal(response.headers.getSetCookie().length, 0, vector.id);
        const raw = await response.text();
        assert.doesNotMatch(raw,/otp-internal-sensitive-fixture/,vector.id);
        if (vector.status === 200) {
          const payload = JSON.parse(raw);
          assert.deepEqual(payload.data,{account:vectors.fixture.account,verified:true,verified_at:vectors.fixture.verified_at}, vector.id);
        }
      }
      assert.equal(f.db.otpUpdates,vector.updates,vector.id);
    }
    assert.doesNotMatch(JSON.stringify(globalThis.__authCompatErrors),/otp-internal-sensitive-fixture/);
    assert.doesNotMatch(consoleErrors.join('\n'),/otp-internal-sensitive-fixture/);
  } finally {console.error = oldConsoleError; delete globalThis.__authCompatErrors; await f.close();}
});

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

test('new-device alert failures do not leak raw errors or block login', async () => {
  const f = await fixture({newDevice: true});
  const priorError = console.error;
  const logs = [];
  console.error = (...args) => logs.push(args.map(value => value instanceof Error ? value.stack ?? value.message : String(value)));
  globalThis.__loginAlertError = new Error('synthetic-alert-password-and-token');
  try {
    const response = await f.login();
    assert.equal(response.status, 200);
    assertTokens(response, (await response.json()).data.tokens);
    assert.doesNotMatch(JSON.stringify(logs), /synthetic-alert-password-and-token/);
  } finally {
    console.error = priorError;
    delete globalThis.__loginAlertError;
    await f.close();
  }
});

test('login profile failure cannot return authentication cookies after the session was written', async () => {
  const f = await fixture();
  globalThis.__loginProfileError = Object.assign(new Error('synthetic-profile-unavailable'), {statusCode: 503, statusMessage: 'Unavailable'});
  try {
    const response = await f.login();
    assert.equal(response.status, 500);
    assert.deepEqual(response.headers.getSetCookie(), []);
    assert.equal(f.db.sessions.size, 1);
  } finally {
    delete globalThis.__loginProfileError;
    await f.close();
  }
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

test('refresh does not fall back from a whitespace-only cookie or bypass session ownership and expiry', async () => {
  const f = await fixture();
  try {
    const tokens = (await (await f.login()).json()).data.tokens;
    const row = f.db.sessions.get(tokens.session_id);
    const endpoint = '/api/v2/auth/tokens/current';
    const body = {refresh_token: tokens.refresh_token};
    const spaces = await f.request(endpoint, 'PATCH', body, {cookie: 'refresh_token=%20%20'});
    assert.equal(spaces.status, 401);
    assert.deepEqual(spaces.headers.getSetCookie(), []);
    row.user_id = 2;
    const foreign = await f.request(endpoint, 'PATCH', body);
    assert.equal(foreign.status, 401);
    assert.deepEqual(foreign.headers.getSetCookie(), []);
    row.user_id = 1;
    row.refresh_token_expires_at = new Date(Date.now() - 1000);
    const expired = await f.request(endpoint, 'PATCH', body);
    assert.equal(expired.status, 401);
    assert.deepEqual(expired.headers.getSetCookie(), []);
  } finally { await f.close(); }
});

test('refresh accepts form data even with a stale access cookie', async () => {
  const f = await fixture();
  try {
    const tokens = (await (await f.login()).json()).data.tokens;
    const response = await f.refreshForm(tokens.refresh_token);
    assert.equal(response.status, 200);
    const refreshed = (await response.json()).data;
    assert.equal(refreshed.session_id, tokens.session_id);
    assertTokens(response, refreshed);
  } finally { await f.close(); }
});

test('refresh hides storage failures and never sends newly issued cookies', async () => {
  for (const statement of ['SELECT session_id, user_id', 'UPDATE n_auth_sessions']) {
    const f = await fixture();
    try {
      const tokens = (await (await f.login()).json()).data.tokens;
      const execute = f.db.execute;
      f.db.execute = async (sql, binds) => {
        if (sql.replace(/\s+/g, ' ').trim().startsWith(statement)) throw new Error('synthetic-storage-secret');
        return execute.call(f.db, sql, binds);
      };
      globalThis.__authCompatErrors = [];
      const response = await f.request('/api/v2/auth/tokens/current', 'PATCH', {refresh_token: tokens.refresh_token});
      assert.equal(response.status, 500);
      assert.deepEqual(response.headers.getSetCookie(), []);
      assert.doesNotMatch(await response.text(), /synthetic-storage-secret/);
      assert.doesNotMatch(JSON.stringify(globalThis.__authCompatErrors), /synthetic-storage-secret/);
    } finally { await f.close(); }
  }
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

test('one recovery code cannot complete two different challenges concurrently or be replayed', async () => {
  const f = await fixture({twoFactor: true, concurrentRecovery: true});
  try {
    const challenges = await Promise.all([1, 2].map(async () => (await (await f.login()).json()).data));
    assert.notEqual(challenges[0].challenge_id, challenges[1].challenge_id);
    const responses = await Promise.all(challenges.map(challenge => f.request('/api/v2/auth/two-factor/challenges', 'POST', {challenge_id: challenge.challenge_id, code: 'ABCDE-FGHIJ-KLMNO'})));
    assert.deepEqual(responses.map(response => response.status).sort(), [200, 401]);
    assert.equal(f.db.sessions.size, 1);
    assert.deepEqual(responses.find(response => response.status === 401).headers.getSetCookie(), []);
    const rejected = challenges[responses.findIndex(response => response.status === 401)];
    assert.equal((await f.request('/api/v2/auth/two-factor/challenges', 'POST', {challenge_id: rejected.challenge_id, code: 'ABCDE-FGHIJ-KLMNO'})).status, 401);
    assert.equal(f.db.sessions.size, 1);
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

test('logout ignores invalid refresh but whitespace-only refresh falls back to access', async () => {
  const f = await fixture();
  try {
    const tokens = (await (await f.login()).json()).data.tokens;
    const path = '/api/v2/auth/tokens/current';
    const failed = await f.request(path, 'DELETE', {refresh_token: tokens.refresh_token}, {
      cookie: 'refresh_token=invalid', authorization: `Bearer ${tokens.access_token}`
    });
    assert.equal(failed.status, 200);
    assert.equal(f.db.sessions.get(tokens.session_id).revoked, false);
    const cleared = await f.request(path, 'DELETE', {refresh_token: 'invalid'}, {
      cookie: 'refresh_token=%20%20', authorization: `Bearer ${tokens.access_token}`
    });
    assert.equal(cleared.status, 200);
    assert.equal(f.db.sessions.get(tokens.session_id).revoked, true);
    assert.equal(cleared.headers.getSetCookie().filter(cookie => /Max-Age=0/.test(cookie)).length, 2);
  } finally { await f.close(); }
});

test('logout hides storage failures and does not clear cookies on failed writes', async () => {
  const f = await fixture();
  try {
    const tokens = (await (await f.login()).json()).data.tokens;
    const execute = f.db.execute;
    f.db.execute = async (sql, binds) => {
      if (sql.replace(/\s+/g, ' ').trim().startsWith('UPDATE n_auth_sessions')) throw new Error('synthetic-logout-storage-secret');
      return execute.call(f.db, sql, binds);
    };
    globalThis.__authCompatErrors = [];
    const response = await f.request('/api/v2/auth/tokens/current', 'DELETE', {refresh_token: tokens.refresh_token});
    assert.equal(response.status, 500);
    assert.deepEqual(response.headers.getSetCookie(), []);
    assert.doesNotMatch(await response.text(), /synthetic-logout-storage-secret/);
    assert.doesNotMatch(JSON.stringify(globalThis.__authCompatErrors), /synthetic-logout-storage-secret/);
    assert.equal(f.db.sessions.get(tokens.session_id).revoked, false);
  } finally { await f.close(); }
});

test('logout preserves cookie priority, and a raw Authorization token is not Bearer', async () => {
  const f = await fixture();
  try {
    const tokens = (await (await f.login()).json()).data.tokens;
    const path = '/api/v2/auth/tokens/current';
    for (const headers of [
      {cookie: 'access_token=invalid', authorization: `Bearer ${tokens.access_token}`},
      {authorization: tokens.access_token}
    ]) {
      assert.equal((await f.request(path, 'DELETE', undefined, headers)).status, 200);
      assert.equal(f.db.sessions.get(tokens.session_id).revoked, false);
    }
  } finally { await f.close(); }
});

test('logout close failure hides cookie changes but cannot undo a committed revoke', async () => {
  const f = await fixture();
  try {
    const tokens = (await (await f.login()).json()).data.tokens;
    f.db.close = async () => { throw new Error('synthetic-close-secret'); };
    const response = await f.request('/api/v2/auth/tokens/current', 'DELETE', {refresh_token: tokens.refresh_token});
    assert.equal(response.status, 500);
    assert.deepEqual(response.headers.getSetCookie(), []);
    assert.doesNotMatch(await response.text(), /synthetic-close-secret/);
    assert.equal(f.db.sessions.get(tokens.session_id).revoked, true);
  } finally { await f.close(); }
});

test('logout form can revoke a matching session even after its database expiry', async () => {
  const f = await fixture();
  try {
    const tokens = (await (await f.login()).json()).data.tokens;
    const row = f.db.sessions.get(tokens.session_id);
    row.refresh_token_expires_at = new Date(Date.now() - 1000);
    const response = await f.logoutForm(tokens.refresh_token);
    assert.equal(response.status, 200);
    assert.equal(row.revoked, true);
    assert.equal(response.headers.getSetCookie().filter(cookie => /Max-Age=0/.test(cookie)).length, 2);
  } finally { await f.close(); }
});

test('a logout committed before refresh prevents the old refresh from rotating', async () => {
  const f = await fixture();
  try {
    const tokens = (await (await f.login()).json()).data.tokens;
    const path = '/api/v2/auth/tokens/current';
    assert.equal((await f.request(path, 'DELETE', {refresh_token: tokens.refresh_token})).status, 200);
    const refresh = await f.request(path, 'PATCH', {refresh_token: tokens.refresh_token});
    assert.equal(refresh.status, 401);
    assert.deepEqual(refresh.headers.getSetCookie(), []);
  } finally { await f.close(); }
});

test('logout identifies the selected refresh session, independent of another access session', async () => {
  const f = await fixture();
  try {
    const first = (await (await f.login()).json()).data.tokens;
    const second = (await (await f.login()).json()).data.tokens;
    assert.notEqual(first.session_id, second.session_id);
    const response = await f.request('/api/v2/auth/tokens/current', 'DELETE', {refresh_token: first.refresh_token}, {
      authorization: `Bearer ${second.access_token}`
    });
    assert.equal(response.status, 200);
    assert.equal(f.db.sessions.get(first.session_id).revoked, true);
    assert.equal(f.db.sessions.get(second.session_id).revoked, false);
  } finally { await f.close(); }
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
