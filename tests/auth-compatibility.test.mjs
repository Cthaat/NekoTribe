// Runs real H3 middleware/routes, auth service, SQL helpers, JWT and bcrypt.
// Only Oracle, Redis/cache, logging, mail and profile/notification boundaries are isolated.
import assert from 'node:assert/strict';
import { before, test } from 'node:test';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { mkdtemp, readFile, readdir, rmdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
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
const moderationAppealListSql = JSON.parse(readFileSync(path.join(root, 'specifications/requirements/moderation-appeals.json'), 'utf8')).sql.list.replace(/\s+/g, ' ').trim();
const moderationReportListSql = JSON.parse(readFileSync(path.join(root, 'specifications/requirements/moderation-reports.json'), 'utf8')).sql.list.replace(/\s+/g, ' ').trim();
const banExpirySql = JSON.parse(readFileSync(path.join(root, 'specifications/requirements/moderation-ban-expiry.json'))).sql;
const require = createRequire(import.meta.url);
const runtime = { accessSecret: 'isolated-test-access-secret', refreshSecret: 'isolated-test-refresh-secret', accessExpiresIn: 900, refreshExpiresIn: 3600 };
const stubs = {
  '#imports': `export const useRuntimeConfig = () => (${JSON.stringify(runtime)});`,
  '~/server/database/schema-definition.mjs': 'export const moderationSettings = [];',
  '~/server/models/v2': 'export const v2RequireSelfUser = async (_, id) => { globalThis.__selfProfileCalls?.push(id); if (globalThis.__loginProfileError) throw globalThis.__loginProfileError; return globalThis.__registrationProfile ?? {user_id: id, username: "test"}; }; export const v2MapPublicUser = () => ({}); export const v2GetPostMedia = async (db, post) => db.contentQueueFixture?.item?.post_id === post ? db.contentQueueFixture.item.media_ids.map(media_id=>({media_id})) : []; export const v2RequirePublicUser = async (_, viewer, id) => { globalThis.__publicCalls?.push([viewer,id]); if (globalThis.__publicError) throw globalThis.__publicError; return globalThis.__publicProfile; };',
  '~/server/storage': 'export const normalizeAvatarPublicUrl=value=>value; export const deleteStorageReference=async(input)=>globalThis.__avatarStorage?.remove(input); export const ensureStorageTempDir=async()=>globalThis.__avatarStorage?.tempDir(); export const storeValidatedAvatarFile=async(...args)=>globalThis.__avatarStorage.save(...args);',
  './presence': 'export const v2PublishUserPresence=async()=>{};',
  './notifications': 'export const v2CreateNotification = async (_, input) => { if (input.type === "follow") globalThis.__followNotices?.push(input); if (globalThis.__loginAlertError) throw globalThis.__loginAlertError; };',
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
    export {default as getMe} from './server/api/v2/users/me.get';
    export {default as patchMe} from './server/api/v2/users/me.patch';
    export {default as changeEmail} from './server/api/v2/users/me/email.patch';
    export {default as deleteMe} from './server/api/v2/users/me.delete';
    export {default as uploadAvatar} from './server/api/v2/users/me/avatar.put';
    export {default as legacyUploadAvatar} from './server/api/v1/users/me/avatar.post';
    export {default as statements} from './server/api/v2/users/me/account-statements/index.get';
    export {default as updateStatement} from './server/api/v2/users/me/account-statements/[id].patch';
    export {default as submitAppeal} from './server/api/v2/users/me/account-statements/[id]/appeals.post';
    export {default as moderationAppeals} from './server/api/v2/moderation/appeals/index.get';
    export {default as decideAppeal} from './server/api/v2/moderation/appeals/[appeal_id].patch';
    export {default as moderationReports} from './server/api/v2/moderation/reports/index.get';
    export {default as updateReport} from './server/api/v2/moderation/reports/[report_id].patch';
    export {default as submitReport} from './server/api/v2/reports/index.post';
    export {default as moderationStats} from './server/api/v2/moderation/stats.get';
    export {default as moderationSettings} from './server/api/v2/moderation/settings/index.get';
    export {default as saveModerationSettings} from './server/api/v2/moderation/settings/index.patch';
    export {default as moderationUsers} from './server/api/v2/moderation/users/index.get';
    export {default as moderationContent} from './server/api/v2/moderation/content/index.get';
    export {default as moderatePost} from './server/api/v2/moderation/content/[post_id]/actions.post';
    export {default as moderatePosts} from './server/api/v2/moderation/content/bulk-actions.post';
    export {default as moderateUser} from './server/api/v2/moderation/users/[user_id]/actions.post';
    export {default as factorSetup} from './server/api/v2/users/me/two-factor/setup.post';
    export {default as factorConfirm} from './server/api/v2/users/me/two-factor/confirm.post';
    export {default as factorDisable} from './server/api/v2/users/me/two-factor.delete';
    export {default as publicProfile} from './server/api/v2/users/[id].get';
    export {default as searchUsers} from './server/api/v2/users/index.get';
    export {default as recommendUsers} from './server/api/v2/users/recommendations.get';
    export {default as listBlocks} from './server/api/v2/users/me/blocks.get';
    export {default as addBlock} from './server/api/v2/users/me/blocks/[target_id].post';
    export {default as removeBlock} from './server/api/v2/users/me/blocks/[target_id].delete';
    export {default as listMutes} from './server/api/v2/users/me/mutes.get';
    export {default as addMute} from './server/api/v2/users/me/mutes/[target_id].post';
    export {default as removeMute} from './server/api/v2/users/me/mutes/[target_id].delete';
    export {default as follow} from './server/api/v2/users/[id]/followers.post';
    export {default as unfollow} from './server/api/v2/users/[id]/followers.delete';
    export {default as followers} from './server/api/v2/users/[id]/followers.get';
    export {default as following} from './server/api/v2/users/[id]/following.get';
    export {default as mutualFollowing} from './server/api/v2/users/[id]/mutual-following.get';
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
    return {rows: [{TOTAL:3,SESSION_ID:'fixture-session-42',DEVICE_INFO:null,IP_ADDRESS:'127.0.0.1',LAST_ACCESSED_AT:new Date('2026-01-01T00:00:00Z'),CREATED_AT:null}]};
  }};
  const result = await routes.v2ListSessions({path:'/api/v2/auth/sessions?page=2&page_size=1',context:{auth:{userId:42,sessionId:'fixture-session-42'}}}, connection);
  assert.deepEqual(result,{code:200,message:'success',data:[{session_id:'fixture-session-42',device_info:'',ip_address:'127.0.0.1',last_accessed_at:'2026-01-01T00:00:00.000Z',created_at:'',is_current:true}],meta:{page:2,page_size:1,total:3,has_next:true}});
  assert.equal(calls.length,1);
  assert.match(calls[0].sql,/user_id = :user_id AND revoked_at IS NULL/);
  assert.match(calls[0].sql,/ROW_NUMBER\(\) OVER \(ORDER BY last_accessed_at DESC, session_id ASC\)/);
  assert.match(calls[0].sql,/LEFT JOIN eligible e ON e.rn BETWEEN :start_row AND :end_row ORDER BY e.rn$/);
  assert.deepEqual(calls[0].binds,{user_id:42,start_row:2,end_row:2});
  const empty = await routes.v2ListSessions({path:'/api/v2/auth/sessions?page=10&page_size=1',context:{auth:{userId:42,sessionId:'fixture-session-42'}}}, {
    async execute() { return {rows:[{TOTAL:3,SESSION_ID:null}]}; },
  });
  assert.deepEqual(empty.data,[]);
  assert.deepEqual(empty.meta,{page:10,page_size:1,total:3,has_next:false});
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
  const trustedDevices = new Map();
  let reads = [];
  let recoveryReads = 0;
  let recoveryUsed = false;
  const calls = [];
  const secret = 'JBSWY3DPEHPK3PXP';
  const cipher = crypto.createCipheriv('aes-256-gcm', crypto.createHash('sha256').update(runtime.refreshSecret).digest(), Buffer.alloc(12));
  const encrypted = Buffer.concat([cipher.update(secret), cipher.final()]);
  const db = {
    sessions, calls, challenges, trustedDevices, close: async () => {},
    async commit() {
      if (db.factorLoginUndo) db.factorLoginUndo.length = 0;
      if (db.banExpiry?.pending) {
        db.banExpiry.pending = false;
        db.banExpiry.status = 'active';
        db.banExpiry.expired = true;
      }
      if (db.userActionFixture) {
        const flow=db.userActionFixture;
        flow.commits.push([...flow.pending]);
        flow.pending=[];
        return;
      }
      if (db.postActionFixture) {
        const flow=db.postActionFixture;
        flow.commits.push([...flow.pending]);
        flow.pending=[];
        return;
      }
      if (db.dashboardFixture) {
        const dashboard = db.dashboardFixture;
        Object.assign(dashboard.values, dashboard.pending);
        dashboard.pending = {};
        dashboard.commits++;
        return;
      }
      if (db.moderationFixture) {
        const flow = db.moderationFixture;
        if (flow.pendingReport) {
          flow.records.set(flow.pendingReport.REPORT_ID, flow.pendingReport);
          flow.pendingReport = null;
        }
        if (flow.change) Object.assign(flow.records.get(flow.change.id), flow.change.fields);
        if (flow.audit) flow.audits.push(flow.audit);
        flow.change = flow.audit = null;
        return;
      }
      if (db.statementFixture) {
        const flow = db.statementFixture;
        if (flow.inserted) flow.pending = flow.inserted;
        if (flow.changed) flow.status = flow.changed;
        flow.inserted = flow.changed = null;
        return;
      }
      if (db.avatarCase) {
        db.avatarCalls.push('commit');
        if (db.avatarCase.fault === 'commit') throw new Error('private commit failure');
        return;
      }
      if(db.factorCase){if(db.factorCase.fault==='commit')throw Error('factor-private-fixture');db.factorWrites=db.factorPending.length?1:0;db.factorPending=[];if(db.factorCase.fault==='commit_applied')throw Error('factor-private-fixture');return;}
      if(db.deletionCase){if(db.deletionCase.fault==='commit')throw Error('deletion-private-fixture');db.deletionWrites=db.deletionPending.length===4?1:0;db.deletionPending=[];if(db.deletionCase.fault==='commit_applied')throw Error('deletion-private-fixture');return;}
      if (db.emailChangeMode) {
        if (db.emailCase.fault === 'commit' && !db.emailCase.commit_applied) throw new Error('email-private-fixture');
        if (db.pendingEmail) { db.emailMarks++; db.emailWrites++; db.otp.expired=true; db.otp.hash='!consumed!'; db.pendingEmail=null; }
        if (db.emailCase.fault === 'commit') throw new Error('email-private-fixture');
        return;
      }
      if (db.resetCommitFail) throw new Error('reset-private-fixture');
      if (db.pendingReset) {
        if (db.pendingReset.invalidateChallenges) {
          for (const challenge of challenges.values())
            if (challenge.user_id === 1 && !challenge.consumed) challenge.consumed = true;
        }
        if (db.pendingReset.revokeDevices) {
          for (const device of trustedDevices.values())
            if (device.user_id === 1 && !device.revoked) device.revoked = true;
        }
        db.otpUpdates++; db.resetPasswordWrites++; db.resetPasswordHash = db.pendingReset.hash;
        db.loginPasswordHash = db.pendingReset.hash;
        db.otp.expired = true; db.otp.verified = true; db.otp.hash = '!consumed!'; db.resetRevoked = true; db.pendingReset = null;
      }
    },
    async rollback() {
      db.factorLoginUndo?.splice(0).reverse().forEach(undo => undo());
      if(db.moderationFixture){db.moderationFixture.pendingReport=db.moderationFixture.change=db.moderationFixture.audit=null;db.moderationFixture.rollbacks++;}if(db.statementFixture){db.statementFixture.inserted=db.statementFixture.changed=null;db.statementFixture.rollbacks++;}if(db.avatarCase) db.avatarCalls.push('rollback');db.factorPending=[]; db.deletionPending=[];db.pendingReset = null; db.pendingEmail=null; if(db.emailChangeMode&&db.emailCase.fault==='rollback')throw new Error('email-private-fixture');
    },
    async execute(raw, binds = {}, options = {}) {
      const sql = raw.replace(/\s+/g, ' ').trim();
      calls.push({sql, binds, options});
      const rows = values => ({rows: values});
      if (db.banExpiry) {
        const ban = db.banExpiry;
        if (sql === banExpirySql.lock) return rows([{USER_ID: 1}]);
        if (sql === banExpirySql.restore) {
          assert.equal(options.autoCommit, false);
          assert.deepEqual(binds, {user_id: 1});
          ban.pending = ban.eligible;
          return {rowsAffected: ban.eligible ? 1 : 0};
        }
        if (sql === banExpirySql.expire) {
          assert.equal(options.autoCommit, false);
          assert.ok(ban.pending);
          return {rowsAffected: 1};
        }
        if (sql.includes('WHERE email = :account')) {
          return rows([{USER_ID: 1, USERNAME: 'test', PASSWORD_HASH: passwordHash, STATUS: ban.status, IS_ACTIVE: Number(ban.status === 'active')}]);
        }
      }
      const dashboard = db.dashboardFixture;
      if (db.userActionFixture) {
        const flow=db.userActionFixture, v=flow.vector;
        if (sql.startsWith('SELECT username, email FROM n_users WHERE user_id')) {
          return rows([{USERNAME:v.denied ? 'member' : 'REVIEWER',EMAIL:'fixture@example.test'}]);
        }
        const query=Object.keys(flow.sql).find(key=>flow.sql[key]===sql);
        if (query==='lock') {
          flow.locked=binds.user_id;
          const state=v.targetState ?? 'active';
          return rows(binds.user_id===99 ? [] : [{USER_ID:binds.user_id,STATUS:state,IS_ACTIVE:state==='active' ? 1 : 0}]);
        }
        if (query==='case') return rows(v.missingCase&&!flow.pending.includes('create') ? [] : [{CASE_ID:15}]);
        if (query==='defaultMute') return rows(v.setting ? [{SETTING_VALUE:v.setting}] : []);
        if (query==='banHistory') return rows(v.history ? [{FOUND:1}] : []);
        if (query) {
          assert.equal(options.autoCommit,false);
          assert.equal(binds.user_id,flow.locked);
          flow.attempted.push(query);
          if (query==='audit') {
            assert.equal(binds.viewer_id,42);
            assert.equal(binds.hours,v.hours ?? (v.auditFail ? 4 : null));
            assert.equal(binds.note,v.body.note?.trim() || null);
            if (v.auditFail) throw new Error('private user action audit failure');
          }
          if (query==='addRestriction') assert.equal(binds.hours,v.hours ?? 4);
          flow.pending.push(query);
          return {rowsAffected:1};
        }
        if (sql.startsWith('WITH filtered_users AS (')) {
          assert.equal(flow.commits.length,0);
          assert.deepEqual(binds,{user_id:flow.locked,status:null,q:null,sort:'newest',start_row:1,end_row:1});
          return rows([{...Object.fromEntries(Object.entries(v.item).map(([key,value])=>[key.toUpperCase(),value])),TOTAL:1}]);
        }
      }
      if (db.postActionFixture) {
        const flow=db.postActionFixture, v=flow.vector;
        if (sql.startsWith('SELECT username, email FROM n_users WHERE user_id')) {
          return rows([{USERNAME:v.denied ? 'member' : 'REVIEWER',EMAIL:'fixture@example.test'}]);
        }
        if (sql.startsWith('SELECT setting_key, setting_value FROM n_moderation_settings')) {
          return rows(v.setting==='disabled' ? [{SETTING_KEY:'allow_moderator_claim',SETTING_VALUE:'false'}] : []);
        }
        if (sql.startsWith('SELECT post_id FROM n_posts WHERE post_id = :post_id FOR UPDATE')) {
          flow.locks.push(binds.post_id);
          return rows(binds.post_id===99 ? [] : [{POST_ID:binds.post_id}]);
        }
        if (sql.startsWith('SELECT case_id, assigned_to FROM n_moderation_cases')) {
          return rows([{CASE_ID:binds.post_id-64,ASSIGNED_TO:v.assigned ?? null}]);
        }
        if (sql.startsWith('UPDATE n_posts') || sql.startsWith('UPDATE n_moderation_cases') ||
            sql.startsWith('UPDATE n_moderation_reports') || sql.startsWith('INSERT INTO n_moderation_actions')) {
          assert.equal(options.autoCommit,false);
          if (sql.startsWith('INSERT INTO n_moderation_actions') && binds.post_id===v.auditFail) {
            throw new Error('private audit failure');
          }
          flow.pending.push({sql,binds});
          return {rowsAffected:1};
        }
        if (sql.startsWith('WITH filtered_content AS (')) {
          assert.equal(flow.commits.length,0);
          assert.equal(binds.post_id,v.item.post_id);
          assert.equal(binds.start_row,1);
          assert.equal(binds.end_row,1);
          const update=flow.pending.find(write=>write.sql.startsWith('UPDATE n_moderation_cases'));
          return rows([{CASE_ID:update.binds.case_id,POST_ID:binds.post_id,STATUS:update.binds.status,PRIORITY:'high',TOTAL:1}]);
        }
        if (sql.endsWith('ORDER BY r.created_at DESC, r.report_id DESC')) return rows([]);
      }
      if (db.contentQueueFixture) {
        const v = db.contentQueueFixture;
        if (sql.startsWith('SELECT username, email FROM n_users WHERE user_id')) {
          return rows([{USERNAME:v.denied ? 'member' : 'REVIEWER',EMAIL:'fixture@example.test'}]);
        }
        if (sql.startsWith('WITH filtered_content AS (')) {
          assert.deepEqual(binds,{post_id:null,viewer_id:42,...v.query});
          return rows([v.item ? {CASE_ID:v.item.case_id,POST_ID:v.item.post_id,STATUS:'pending',PRIORITY:'high',TOTAL:v.meta.total} : {CASE_ID:null,TOTAL:v.meta.total}]);
        }
        if (sql.endsWith('ORDER BY r.created_at DESC, r.report_id DESC')) {
          assert.deepEqual(binds,{target_type:'post',target_id:v.item.post_id});
          return rows(v.item.report_ids.map((REPORT_ID,i)=>({
            REPORT_ID,REASON:i===1 ? 'hate' : 'spam',TARGET_TYPE:'post',TARGET_ID:v.item.post_id
          })));
        }
        if (v.verifyAction) {
          if (sql.startsWith('SELECT setting_key, setting_value FROM n_moderation_settings')) return rows([]);
          if (sql.startsWith('SELECT post_id FROM n_posts WHERE post_id = :post_id FOR UPDATE')) return rows([{POST_ID:binds.post_id}]);
          if (sql.startsWith('SELECT case_id, assigned_to FROM n_moderation_cases')) return rows([{CASE_ID:v.item.case_id,ASSIGNED_TO:null}]);
          if (sql.startsWith('UPDATE n_moderation_cases') || sql.startsWith('UPDATE n_moderation_reports') ||
              sql.startsWith('INSERT INTO n_moderation_actions')) return {rowsAffected:1};
        }
      }
      if (dashboard) {
        if (sql.startsWith('SELECT username, email FROM n_users WHERE user_id')) {
          return rows([{USERNAME:dashboard.denied ? 'member' : 'REVIEWER',EMAIL:'fixture@example.test'}]);
        }
        if (sql.includes('AS appeal_success_rate') && sql.endsWith('FROM dual')) {
          return rows([Object.fromEntries(Object.entries(dashboard.stats).map(([key,value]) => [key.toUpperCase(),value]))]);
        }
        if (sql.startsWith('SELECT setting_key, setting_value,')) {
          return rows(Object.entries({...dashboard.values,...dashboard.pending}).sort(([a],[b]) => a.localeCompare(b))
            .map(([SETTING_KEY,SETTING_VALUE],index) => ({
              SETTING_KEY,SETTING_VALUE,VALUE_TYPE:index === 0 ? 'number' : 'boolean',
              UPDATED_AT:'2026-11-16T00:00:00.000Z'
            })));
        }
        if (sql.startsWith('UPDATE n_moderation_settings')) {
          assert.equal(options.autoCommit,false);
          assert.equal(binds.updated_by,42);
          const { setting_key, setting_value, value_type } = binds;
          assert.equal(value_type,setting_key === 'default_mute_hours' ? 'number' : 'boolean');
          dashboard.writes.push([setting_key,setting_value]);
          if (setting_key === 'require_note_on_reject' && dashboard.pending.default_mute_hours === '77') {
            throw new Error('isolated private dashboard update failure');
          }
          dashboard.pending[setting_key] = setting_value;
          return {rowsAffected:1};
        }
      }
      if (db.userQueueFixture) {
        const vector = db.userQueueFixture;
        if (sql.startsWith('SELECT username, email FROM n_users WHERE user_id')) {
          return rows([{USERNAME:vector.denied ? 'member' : 'REVIEWER',EMAIL:'fixture@example.test'}]);
        }
        if (sql.startsWith('WITH filtered_users AS (')) {
          assert.deepEqual(binds,{user_id:null,...vector.query});
          if (!vector.data.length) return rows([{USER_ID:null,TOTAL:vector.meta.total}]);
          return rows(vector.data.map(item => ({
            ...Object.fromEntries(Object.entries(item).map(([key,value]) => [key.toUpperCase(),value])),
            TOTAL:vector.meta.total,
          })));
        }
        if (vector.verifyAction) {
          if (sql.startsWith('SELECT user_id, status, is_active FROM n_users')) return rows([{USER_ID:7,STATUS:'active',IS_ACTIVE:1}]);
          if (sql.startsWith('SELECT case_id FROM n_moderation_cases')) return rows([{CASE_ID:15}]);
          if (sql.startsWith('INSERT INTO n_moderation_actions')) {
            assert.equal(binds.user_id,7);
            assert.equal(binds.action,'note');
            return {rowsAffected:1};
          }
        }
      }
      const mod = db.moderationFixture;
      if (mod) {
        if (sql.startsWith('SELECT p.post_id AS target_id FROM n_posts')) {
          assert.equal(binds.viewer_id,42);
          assert.match(sql,/fn_can_view_post.*FOR UPDATE$/);
          return rows(binds.target_id === 99 ? [] : [{TARGET_ID:binds.target_id}]);
        }
        if (sql.startsWith('SELECT report_id, reason, description, evidence_url, priority FROM (')) {
          return rows([...mod.records.values()].filter(report => report.TARGET_ID === binds.target_id && report.STATUS === 'pending'));
        }
        if (sql.startsWith('SELECT seq_moderation_report_id.NEXTVAL')) return rows([{REPORT_ID:mod.nextReport++}]);
        if (sql.startsWith('INSERT INTO n_moderation_reports')) {
          assert.equal(options.autoCommit,false);
          mod.inserts++;
          mod.pendingReport = {
            REPORT_ID:binds.report_id,TARGET_TYPE:binds.target_type,TARGET_ID:binds.target_id,
            REASON:binds.reason,DESCRIPTION:binds.description,EVIDENCE_URL:binds.evidence_url,
            PRIORITY:binds.priority,STATUS:'pending'
          };
          return {rowsAffected:1};
        }
        if (sql.startsWith('MERGE INTO n_moderation_cases')) {
          assert.equal(options.autoCommit,false);
          assert.equal(mod.pendingReport.TARGET_ID,binds.target_id);
          if (binds.target_id === 13) throw new Error('private isolated case failure');
          mod.caseWrites++;
          return {rowsAffected:1};
        }
        if (sql.startsWith('SELECT username, email FROM n_users WHERE user_id')) {
          assert.equal(binds.user_id,42);
          return rows([{USERNAME:mod.denied ? 'member' : 'REVIEWER',EMAIL:'fixture@example.test'}]);
        }
        if (sql === moderationReportListSql) {
          assert.deepEqual(binds,{status:'pending',reason:'spam',target_type:'group_post',start_row:3,end_row:4});
          return rows([{REPORT_ID:null,TOTAL:2}]);
        }
        if (sql.startsWith('SELECT status, handled_by,') && sql.includes('FROM n_moderation_reports')) {
          const report = mod.records.get(binds.report_id);
          return rows(report ? [{...report, IS_RESOLVED: Number(Boolean(report.RESOLVED_AT))}] : []);
        }
        if (sql.startsWith('UPDATE n_moderation_reports')) {
          assert.equal(options.autoCommit,false);
          mod.writes++;
          mod.change = {id:binds.report_id,fields:{
            STATUS:binds.status,HANDLED_BY:binds.handled_by,
            RESOLVED_AT:['resolved','dismissed'].includes(binds.status) ? '2026-11-16T01:00:00.000Z' : null
          }};
          return {rowsAffected:1};
        }
        if (sql.startsWith('SELECT r.report_id,') && sql.endsWith('WHERE r.report_id = :report_id')) {
          if (binds.report_id === 13) throw new Error('private report readback failure');
          const committed = mod.records.get(binds.report_id) ?? mod.pendingReport;
          return rows([{...committed, ...(mod.change?.fields ?? {})}]);
        }
        if (sql === moderationAppealListSql) {
          assert.deepEqual(binds,{viewer_id:42,status:'pending',start_row:3,end_row:4});
          return rows([{APPEAL_ID:0,TOTAL:2}]);
        }
        if (sql === 'SELECT user_id, appeal_status, admin_response FROM n_statement_appeals WHERE appeal_id = :appeal_id FOR UPDATE') {
          const item=mod.records.get(binds.appeal_id);
          return rows(item ? [item] : []);
        }
        if (sql.startsWith('UPDATE n_statement_appeals SET appeal_status')) {
          assert.equal(options.autoCommit,false);
          mod.change={id:binds.appeal_id,fields:{APPEAL_STATUS:binds.status,ADMIN_RESPONSE:binds.response}};
          return {rowsAffected:1};
        }
        if (sql.startsWith('INSERT INTO n_moderation_actions')) {
          assert.equal(options.autoCommit,false);
          assert.deepEqual(binds, {target_id:7,viewer_id:42,action:'appeal_'+mod.change.fields.APPEAL_STATUS,reason:'appeal:'+mod.change.id,response:mod.change.fields.ADMIN_RESPONSE});
          if (mod.change.id === 13) throw new Error('private audit storage details');
          mod.audit=binds;
          return {rowsAffected:1};
        }
        if (sql.startsWith('SELECT COALESCE(u.user_id') && sql.endsWith('WHERE a.appeal_id = :appeal_id')) {
          assert.equal(binds.viewer_id,42);
          const committed=mod.records.get(binds.appeal_id);
          return rows([{...committed,...(mod.change?.fields ?? {})}]);
        }
      }
      const flow = db.statementFixture;
      if (flow && sql.startsWith('WITH visible AS (') && sql.includes('FROM n_account_statements')) {
        assert.deepEqual(binds, {user_id:42,status:'unread',statement_type:'warning',start_row:3,end_row:4});
        return rows([{STATEMENT_ID:0,TOTAL:2}]);
      }
      if (flow && (sql.includes('n_account_statements') || sql.includes('n_statement_appeals') || sql.includes('seq_statement_appeal_id'))) {
        if (sql.startsWith('SELECT seq_statement_appeal_id')) return rows([{ID:12}]);
        assert.equal(binds.user_id,42);
        if (sql.startsWith('SELECT status FROM n_account_statements')) {
          assert.match(sql,/FOR UPDATE$/);
          return rows(binds.statement_id === 8 ? [] : [{STATUS:flow.status}]);
        }
        if (sql.startsWith('SELECT appeal_id')) {
          return rows(binds.statement_id === 9 && flow.pending ? [flow.pending] : []);
        }
        if (sql.startsWith('INSERT INTO n_statement_appeals')) {
          assert.equal(options.autoCommit,false);
          flow.inserts++;
          flow.inserted = {APPEAL_ID:binds.appeal_id,APPEAL_MESSAGE:binds.appeal_message};
          return {rowsAffected:1};
        }
        if (sql.startsWith('UPDATE n_account_statements')) {
          assert.equal(options.autoCommit,false);
          if (binds.statement_id === 10) throw new Error('private workflow database failure');
          if (binds.statement_id === 8) return {rowsAffected:0};
          flow.changed = binds.status;
          return {rowsAffected:1};
        }
        if (sql.startsWith('SELECT statement_id, status')) {
          assert.equal(flow.changed,'read');
          return rows([{STATEMENT_ID:binds.statement_id,STATUS:flow.changed,UPDATED_AT:'2026-11-16T08:00:00.000Z'}]);
        }
      }
      if (db.avatarCase && sql.startsWith('UPDATE n_user_sessions')) {
        assert.equal(binds.userId, 42);
        return {rowsAffected:1};
      }
      if (db.avatarCase && (sql.endsWith('is_active = 1 FOR UPDATE') || sql.includes('seq_media_id.NEXTVAL') ||
          sql.startsWith('INSERT INTO n_media_assets') || sql.startsWith('UPDATE n_users SET avatar_url ='))) {
        if (sql.includes('seq_media_id.NEXTVAL')) {
          db.avatarCalls.push('next');
          return rows([{ID:12}]);
        }
        assert.equal(binds.user_id, 42);
        if (sql.endsWith('FOR UPDATE')) {
          db.avatarCalls.push('lock');
          return rows([{USER_ID:42}]);
        }
        assert.equal(options.autoCommit, false);
        const step = sql.startsWith('INSERT') ? 'insert' : 'update';
        db.avatarCalls.push(step);
        if (step === 'insert') assert.equal(binds.mime_type, db.avatarCase.mime);
        if (db.avatarCase.fault === 'rollback' && step === 'update') throw new Error('private update failure');
        return {rowsAffected:1};
      }
      if(db.factorCase?.fault==='schema' && sql.toUpperCase().includes('FROM USER_TABLES'))return rows([]);
      const metadata = schema.query(sql, binds);
      if (metadata !== undefined) return rows(metadata);
      const discovery = db.discoveryCase;
      if (discovery && /:sort_mode|:row_limit/.test(sql)) {
        const meta = discovery.meta;
        if ('limit' in meta) {
          assert.deepEqual(binds, {viewer_id:42,row_limit:meta.limit});
        } else {
          assert.deepEqual(binds, {viewer_id:42,pattern:discovery.pattern,sort_mode:discovery.sort,verified_only:discovery.verified,
            start_row:(meta.page - 1) * meta.page_size + 1,end_row:meta.page * meta.page_size});
        }
        return rows([{USER_ID:discovery.empty ? 0 : 7,TOTAL:meta.total ?? 0}]);
      }
      if (db.visibilityFixture || db.followFixture) {
        if (sql === 'SELECT user_id FROM n_users WHERE user_id = :user_id FOR UPDATE') {
          return rows(binds.user_id === 81 ? [] : [{USER_ID: binds.user_id}]);
        }
        if (sql === 'SELECT user_id FROM v_user_profile_public WHERE user_id = :target_id AND is_active = 1') {
          return rows([{USER_ID: binds.target_id}]);
        }
        if (sql.startsWith('WITH visible AS (')) {
          assert.deepEqual(binds, {...(db.followFixture ? {target_id:9} : {}),viewer_id:42,start_row:3,end_row:4});
          return rows([{USER_ID:0,TOTAL:2}]);
        }
        if (db.followFixture) {
          if (sql.startsWith('SELECT COUNT(*) AS total FROM n_user_blocks')) {
            return rows([{TOTAL: Number(binds.target_id === 7)}]);
          }
          if (sql.startsWith('MERGE INTO n_user_follows') || sql.startsWith("UPDATE n_user_follows SET status = 'cancelled'")) {
            assert.equal(options.autoCommit, false);
            const following = sql.startsWith('MERGE');
            const changed = Number(Boolean(db.following) !== following);
            db.following = following;
            return {rowsAffected: changed};
          }
          if (sql.startsWith('SELECT followers_count FROM n_user_stats')) {
            return rows([{FOLLOWERS_COUNT: Number(Boolean(db.following))}]);
          }
          if (sql.startsWith('SELECT COALESCE(display_name, username) AS name FROM n_users')) {
            return rows([{NAME:'Example'}]);
          }
        }
        if (/^(MERGE INTO|DELETE FROM) n_user_(blocks|mutes)/.test(sql) ||
            sql.startsWith("UPDATE n_user_follows SET status = 'cancelled'")) {
          return {rowsAffected: 1};
        }
      }
      if (sql === 'SELECT user_id FROM n_users WHERE user_id = :user_id FOR UPDATE') {
        return rows([{USER_ID: binds.user_id}]);
      }
      if (sql.startsWith('SELECT password_hash FROM n_users WHERE user_id')) {
        return rows([{PASSWORD_HASH: db.passwordChangedBeforeIssue ? 'different-hash' : db.loginPasswordHash ?? passwordHash}]);
      }
      if(db.factorCase){const c=db.factorCase;
        if(sql.startsWith('SELECT password_hash, status, is_active')){if(c.fault==='credential')throw Error('factor-private-fixture');return rows(c.fault==='missing'?[]:[{PASSWORD_HASH:passwordHash,STATUS:c.fault==='inactive'?'disabled':'active',IS_ACTIVE:c.fault==='inactive'?0:1}]);}
        if(sql.includes('FROM n_user_two_factor_secrets')){if(c.fault==='secret')throw Error('factor-private-fixture');return rows(c.secret==='absent'?[]:[{...db.factorSecret,ENABLED_AT:(c.secret??(c.action==='disable'?'enabled':'disabled'))==='enabled'?new Date():null}]);}
        if(sql.includes('FROM n_user_two_factor_recovery_codes')){if(c.fault==='recovery')throw Error('factor-private-fixture');return rows([{RECOVERY_CODE_ID:1,CODE_HASH:db.factorRecoveryHash}]);}
        if(sql.startsWith('SELECT seq_2fa_recovery_code_id.NEXTVAL'))return rows([{ID:++db.factorSequence}]);
        if(/^(MERGE INTO|UPDATE|DELETE FROM|INSERT INTO) n_(user_two_factor_|user_settings)/.test(sql)){
          assert.equal(options.autoCommit,false);if(c.fault==='write')throw Error('factor-private-fixture');
          if(sql.includes('n_user_two_factor_secrets')&&c.fault==='changed')return{rowsAffected:0};
          if(sql.startsWith('UPDATE n_user_two_factor_recovery_codes')&&c.fault==='consume')return{rowsAffected:0};
          db.factorPending.push({sql,binds});return{rowsAffected:1};
        }
      }
      if(db.deletionCase){
        const fault=db.deletionCase.fault;
        if(sql.startsWith('SELECT password_hash, status, is_active')){if(fault==='credential')throw Error('deletion-private-fixture');return rows([{PASSWORD_HASH:passwordHash,STATUS:fault==='inactive'?'disabled':'active',IS_ACTIVE:fault==='inactive'?0:1}]);}
        const step=sql.startsWith('UPDATE n_posts SET is_deleted')?'posts':sql.startsWith('UPDATE n_comments SET is_deleted')?'comments':sql.startsWith('UPDATE n_auth_sessions SET revoked_at')?'sessions':sql.startsWith('UPDATE n_users SET email')?'user':null;
        if(step){assert.equal(options.autoCommit,false);assert.equal(binds.user_id,42);if(fault===step)throw Error('deletion-private-fixture');if(step==='user'){assert.equal(binds.email,'deleted_42@deleted.local');assert.equal(binds.username,'deleted_42');assert.equal(binds.old_hash,passwordHash);if(fault==='changed')return{rowsAffected:0};assert(await bcrypt.compare('test-password',binds.password_hash)===false);}
        db.deletionPending.push(step);return{rowsAffected:1};}
      }
      if (db.emailChangeMode) {
        const c=db.emailCase;
        if(sql.startsWith('SELECT COUNT(*) AS total FROM n_users WHERE email')){
          assert.equal(binds.user_id,42);if(c.fault==='duplicate')throw new Error('email-private-fixture');return rows([{TOTAL:c.duplicate?1:0}]);
        }
        if(sql.startsWith('UPDATE n_auth_otp_events')&&sql.includes("otp_type = 'change_email'")){
          assert.equal(options.autoCommit,false);assert.equal(binds.account,'new@example.test');assert.equal(binds.verification_id,'email_fixture');assert.equal(binds.code_hash,db.otp.hash);
          if(c.fault==='claim')throw new Error('email-private-fixture');
          if(c.lost_race)return{rowsAffected:0};if(c.claim_count)return{rowsAffected:c.claim_count};db.pendingEmail={};return{rowsAffected:1};
        }
        if(sql.startsWith('UPDATE n_users SET email')){
          assert.equal(options.autoCommit,false);assert.equal(binds.user_id,42);assert.equal(binds.email,'new@example.test');
          if(c.unique_race)throw Object.assign(new Error('email-private-fixture'),{errorNum:1});
          if(['write','rollback'].includes(c.fault))throw new Error('email-private-fixture');
          if(c.missing_user)return{rowsAffected:0};if(c.write_count)return{rowsAffected:c.write_count};return{rowsAffected:1};
        }
        if(sql.startsWith('SELECT email, TO_CHAR(FROM_TZ(email_verified_at')){
          if(c.fault==='read')throw new Error('email-private-fixture');assert.equal(binds.user_id,42);return rows([{EMAIL:'new@example.test',EMAIL_VERIFIED_AT:new Date('2026-01-02T03:04:05Z')}]);
        }
      }
      if (sql.startsWith('SELECT verified_at FROM n_auth_otp_events WHERE account')) {
        if (db.registrationFault === 'otp') throw new Error('registration-internal-fixture');
        assert.match(sql, /otp_type = 'register'/);
        if (db.registrationFromOTP) {const otp=db.otp;return rows(otp?.verified && !otp.expired && otp.account===binds.account && otp.type==='register' && otp.verification_id===binds.verification_id ? [{VERIFIED_AT:new Date('2026-01-02T03:04:05Z')}] : []);}
        const r=db.registrationState;
        return rows(r && !r.otp && binds.account===(r.account??'new@example.test') && binds.verification_id==='otp_fixture' ? [{VERIFIED_AT:new Date('2026-01-02T03:04:05Z')}] : []);
      }
      if (sql.startsWith('UPDATE n_auth_otp_events SET expires_at = created_at')) {
        assert.match(sql, /otp_type = 'register'/);
        assert.equal(options.autoCommit, false);
        return {rowsAffected: db.registrationFault === 'consumed' ? 0 : 1};
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
      if (sql.startsWith('UPDATE n_auth_otp_events SET verified_at') && sql.includes('expires_at = CURRENT_TIMESTAMP')) {
        if (db.otpFault === 'update') throw new Error('otp-internal-sensitive-fixture');
        assert.match(sql, /verification_code_hash = '!consumed!'/);
        assert.match(sql, /verification_code_hash = :code_hash/);
        assert.match(sql, /otp_type = 'password_reset'/);
        assert.equal(binds.account, 'fake@example.test'); assert.equal(binds.verification_id, 'otp_fixture');
        if (db.resetLostRace || db.otp.expired || db.otp.hash !== binds.code_hash) return {rowsAffected:0};
        assert.equal(options.autoCommit, false);
        db.pendingReset = {};
        return {rowsAffected:1};
      }
      if (sql.startsWith('UPDATE n_auth_otp_events SET verified_at')) {
        if (db.otpFault === 'update') throw new Error('otp-internal-sensitive-fixture');
        db.otpUpdates = (db.otpUpdates ?? 0) + 1;
        if (db.otp) db.otp.verified=true;
        return {rowsAffected: 1};
      }
      if (sql.startsWith('SELECT verified_at FROM n_auth_otp_events')) {
        if (db.otpFault === 'readback') throw new Error('otp-internal-sensitive-fixture');
        return rows([{VERIFIED_AT: new Date(db.otp.verified_at)}]);
      }
      if (sql.startsWith('UPDATE n_users SET password_hash')) {
        if (db.resetPasswordFault === 'write') throw new Error('reset-private-fixture');
        if (db.resetMissingUser) return {rowsAffected: 0};
        assert.equal(options.autoCommit, false);
        db.pendingReset.hash = binds.password_hash;
        assert.equal(binds.email, 'fake@example.test');
        return {rowsAffected: 1};
      }
      if (sql.startsWith('UPDATE n_auth_sessions SET revoked_at') && sql.includes('SELECT user_id FROM n_users WHERE email')) {
        if (db.resetPasswordFault === 'revoke') throw new Error('reset-private-fixture');
        assert.equal(options.autoCommit, false); assert.equal(binds.email, 'fake@example.test');
        return {rowsAffected: 2};
      }
      if (sql.includes('SELECT user_id FROM n_users WHERE email') && sql.startsWith('UPDATE n_auth_two_factor_challenges')) {
        assert.equal(options.autoCommit, false);
        if (db.resetPasswordFault === 'invalidate_challenges') throw new Error('reset-private-fixture');
        db.pendingReset.invalidateChallenges = true;
        return {rowsAffected: 1};
      }
      if (sql.includes('SELECT user_id FROM n_users WHERE email') && sql.startsWith('UPDATE n_user_two_factor_trusted_devices')) {
        assert.equal(options.autoCommit, false);
        if (db.resetPasswordFault === 'revoke_devices') throw new Error('reset-private-fixture');
        db.pendingReset.revokeDevices = true;
        return {rowsAffected: 1};
      }
      if (sql.startsWith('UPDATE n_user_two_factor_trusted_devices SET last_used_at')) {
        assert.equal(options.autoCommit, false);
        assert.match(sql, /expires_at > CURRENT_TIMESTAMP AND revoked_at IS NULL/);
        const device = trustedDevices.get(binds.device_fingerprint);
        return {rowsAffected: device?.user_id === binds.user_id && !device.revoked ? 1 : 0};
      }
      if (sql.startsWith('SELECT seq_2fa_trusted_device_id.NEXTVAL')) {
        await db.beforeTrust?.();
        return rows([{ID: 1}]);
      }
      if (sql.startsWith('INSERT INTO n_user_two_factor_trusted_devices')) {
        assert.equal(options.autoCommit, false);
        trustedDevices.set(binds.device_fingerprint, {...binds, revoked: false});
        db.factorLoginUndo?.push(() => trustedDevices.delete(binds.device_fingerprint));
        return {rowsAffected: 1};
      }
      if (sql.includes('WHERE email = :account')) return rows([{USER_ID: 1, USERNAME: 'test', PASSWORD_HASH: db.loginPasswordHash ?? passwordHash, STATUS: 'active', IS_ACTIVE: 1}]);
      if (sql.includes('AS two_factor_enabled')) return rows([{TWO_FACTOR_ENABLED: Number(twoFactor), ENABLED_AT: twoFactor ? new Date() : null}]);
      if (sql.startsWith('SELECT COUNT')) return rows([{TOTAL: newDevice ? 0 : 1}]);
      if (sql.includes('AS login_alerts')) return rows([{EMAIL: 'fixture@example.test', LOGIN_ALERTS: 1, EMAIL_NOTIFICATION_ENABLED: 1}]);
      if (sql.startsWith('INSERT INTO n_auth_sessions')) {
        if (db.failFactorSession) throw Error('session-insert-fixture');
        sessions.set(binds.session_id, {...binds, revoked: false});
        return {rowsAffected: 1};
      }
      if (db.profilePatchMode && sql.startsWith('UPDATE n_users SET ')) { db.profileWrites.push({sql, binds, options}); if (db.profileUpdateFail) throw new Error('private-update-fixture'); return {rowsAffected: 1}; }
      if (sql.startsWith('UPDATE n_users')) return {rowsAffected: 1};
      if (sql.startsWith('INSERT INTO n_auth_two_factor_challenges')) {challenges.set(binds.challenge_id, {...binds}); return {rowsAffected: 1};}
      if (sql.includes('FROM n_auth_two_factor_challenges c')) {
        const row = challenges.get(binds.challenge_id);
        const result = rows(row && !row.consumed ? [{
          USER_ID: 1, USERNAME: 'test', PASSWORD_HASH: db.loginPasswordHash ?? passwordHash,
          REMEMBER_ME: row.remember_me, DEVICE_FINGERPRINT: row.device_fingerprint
        }] : []);
        if (concurrentChallenge) await new Promise(resolve => {reads.push(resolve); if (reads.length === 2) {reads.forEach(done => done()); reads = [];}});
        return result;
      }
      if (sql === 'SELECT user_id FROM n_user_two_factor_secrets WHERE user_id = :user_id FOR UPDATE')
        return rows([{USER_ID:binds.user_id}]);
      if (sql.startsWith('SELECT user_id FROM n_user_two_factor_secrets WHERE user_id = :user_id AND enabled_at IS NOT NULL')) {
        assert.equal(binds.old_encrypted, encrypted.toString('base64'));
        assert.equal(binds.old_iv, Buffer.alloc(12).toString('base64'));
        assert.equal(binds.old_tag, cipher.getAuthTag().toString('base64'));
        return rows(db.factorChangedDuringLogin ? [] : [{USER_ID:binds.user_id}]);
      }
      if (sql.includes('FROM n_user_two_factor_secrets')) return rows([{ENABLED_AT: new Date(), SECRET_ENCRYPTED: encrypted.toString('base64'), SECRET_IV: Buffer.alloc(12).toString('base64'), SECRET_AUTH_TAG: cipher.getAuthTag().toString('base64')}]);
      if (sql.includes('FROM n_user_two_factor_recovery_codes')) {
        const result = rows((concurrentRecovery || db.factorLoginUndo) && !recoveryUsed ? [{RECOVERY_CODE_ID: 1, CODE_HASH: recoveryHash}] : []);
        if (concurrentRecovery && ++recoveryReads <= 2) await new Promise(resolve => {reads.push(resolve); if (reads.length === 2) {reads.forEach(done => done()); reads = [];}});
        return result;
      }
      if (sql.startsWith('UPDATE n_user_two_factor_recovery_codes')) {
        if (sql.includes('AND used_at IS NULL') && recoveryUsed) return {rowsAffected: 0};
        db.factorLoginUndo?.push(() => { recoveryUsed = false; });
        recoveryUsed = true; return {rowsAffected: 1};
      }
      if (sql.startsWith('UPDATE n_auth_two_factor_challenges')) {
        const row = challenges.get(binds.challenge_id);
        if (!row || (sql.includes('AND consumed_at IS NULL') && row.consumed)) return {rowsAffected: 0};
        if (sql.includes('AND expires_at > CURRENT_TIMESTAMP') && row.expires_at <= new Date()) return {rowsAffected: 0};
        db.factorLoginUndo?.push(() => { row.consumed = false; });
        row.consumed = true; return {rowsAffected: 1};
      }
      if (sql.startsWith('SELECT session_id, user_id')) {
        const row = sessions.get(binds.session_id);
        const accountAllowed = !db.sessionAccountDisabled || !sql.includes("u.status = 'active'");
        const result = rows(accountAllowed && row && row.user_id === binds.user_id && !row.revoked && row.refresh_token_hash === binds.refresh_token_hash && row.refresh_token_expires_at > new Date() ? [{SESSION_ID: row.session_id, USER_ID: row.user_id}] : []);
        if (db.disableAccountAfterRefreshRead) db.sessionAccountDisabled = true;
        if (concurrentRefresh) {
          await new Promise(resolve => {reads.push(resolve); if (reads.length === 2) {reads.forEach(done => done()); reads = [];}});
        }
        return result;
      }
      if (sql.startsWith('UPDATE n_auth_sessions')) {
        if (sql.includes('SET last_accessed_at')) { db.profileTouches = (db.profileTouches ?? 0) + 1; if (db.profileTouchFail) throw new Error('private-profile-fixture'); }
        const row = sessions.get(binds.session_id ?? binds.sessionId);
        if (!row || row.revoked) return {rowsAffected: 0};
        if (db.sessionAccountDisabled && sql.includes("u.status = 'active'")) return {rowsAffected: 0};
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
    event.context.redis = { eval: async (_script, keys) => {
      if (keys === 2) {
        if (db.otpCreateFault === 'limited') return 42;
        if (db.otpCreateFault === 'unavailable') throw new Error('isolated Redis failure');
        return 0;
      }
      if (db.otpAttemptFault) throw new Error('isolated Redis failure');
      if (db.otpAttempts === undefined) return 1;
      if (db.otpAttempts >= 5) return 0;
      db.otpAttempts = (db.otpAttempts ?? 0) + 1;
      return 1;
    } };
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
  router.get('/api/v2/users/me', routes.getMe);
  router.patch('/api/v2/users/me', routes.patchMe);
  router.patch('/api/v2/users/me/email', routes.changeEmail);
  router.get('/api/v2/users/me/blocks', routes.listBlocks);
  router.post('/api/v2/users/me/blocks/:target_id', routes.addBlock);
  router.delete('/api/v2/users/me/blocks/:target_id', routes.removeBlock);
  router.get('/api/v2/users/me/mutes', routes.listMutes);
  router.post('/api/v2/users/me/mutes/:target_id', routes.addMute);
  router.delete('/api/v2/users/me/mutes/:target_id', routes.removeMute);
  router.post('/api/v2/users/:id/followers', routes.follow);
  router.delete('/api/v2/users/:id/followers', routes.unfollow);
  router.get('/api/v2/users/:id/followers', routes.followers);
  router.get('/api/v2/users/:id/following', routes.following);
  router.get('/api/v2/users/:id/mutual-following', routes.mutualFollowing);
  router.delete('/api/v2/users/me',routes.deleteMe);
  router.put('/api/v2/users/me/avatar', routes.uploadAvatar);
  router.post('/api/v1/users/me/avatar', routes.legacyUploadAvatar);
  router.get('/api/v2/users/me/account-statements', routes.statements);
  router.patch('/api/v2/users/me/account-statements/:id', routes.updateStatement);
  router.post('/api/v2/users/me/account-statements/:id/appeals', routes.submitAppeal);
  router.get('/api/v2/moderation/appeals', routes.moderationAppeals);
  router.patch('/api/v2/moderation/appeals/:appeal_id', routes.decideAppeal);
  router.get('/api/v2/moderation/reports', routes.moderationReports);
  router.patch('/api/v2/moderation/reports/:report_id', routes.updateReport);
  router.post('/api/v2/reports', routes.submitReport);
  router.get('/api/v2/moderation/stats', routes.moderationStats);
  router.get('/api/v2/moderation/settings', routes.moderationSettings);
  router.patch('/api/v2/moderation/settings', routes.saveModerationSettings);
  router.get('/api/v2/moderation/users', routes.moderationUsers);
  router.get('/api/v2/moderation/content', routes.moderationContent);
  router.post('/api/v2/moderation/content/:post_id/actions', routes.moderatePost);
  router.post('/api/v2/moderation/content/bulk-actions', routes.moderatePosts);
  router.post('/api/v2/moderation/users/:user_id/actions', routes.moderateUser);
  router.post('/api/v2/users/me/two-factor/setup',routes.factorSetup);router.post('/api/v2/users/me/two-factor/confirm',routes.factorConfirm);router.delete('/api/v2/users/me/two-factor',routes.factorDisable);
  router.get('/api/v2/users/:id', routes.publicProfile);
  router.get('/api/v2/users', routes.searchUsers);
  router.get('/api/v2/users/recommendations', routes.recommendUsers);
  router.get('/api/v2/private', defineEventHandler(() => ({ok: true})));
  app.use(router);
  const server = createServer(toNodeListener(app));
  const base = await listenForFetch(server);
  return {
    db,
    close: () => new Promise(resolve => server.close(resolve)),
    request: (url, method, body, headers = {}) => fetch(base + url, {method, headers: {...(body === undefined ? {} : {'content-type': 'application/json'}), ...headers}, body: body === undefined ? undefined : JSON.stringify(body)}),
    requestRaw: (url, method, body, headers, options = {}) => fetch(base + url, {method,body,headers,...options}),
    refreshForm: token => fetch(base + '/api/v2/auth/tokens/current', {method: 'PATCH', headers: {'content-type': 'application/x-www-form-urlencoded', cookie: 'access_token=expired'}, body: new URLSearchParams({refresh_token: token})}),
    logoutForm: token => fetch(base + '/api/v2/auth/tokens/current', {method: 'DELETE', headers: {'content-type': 'application/x-www-form-urlencoded'}, body: new URLSearchParams({refresh_token: token})}),
    login: () => fetch(base + '/api/v2/auth/tokens', {method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify({account: 'test', password: 'test-password'})})
  };
}

test('shared self-profile scenarios enforce session identity and safe errors', async () => {
  const vectors=JSON.parse(readFileSync(path.join(root,'specifications/scenarios/user-self-profile.json'),'utf8'));
  const f=await fixture();const oldError=console.error;const errors=[];console.error=(...args)=>errors.push(args.map(String).join(' '));
  globalThis.__authCompatErrors=[];globalThis.__registrationProfile=vectors.profile;
  const payload={userId:42,userName:'selfuser',sessionId:'fixture-session-42',jti:'fixture-access-jti-42',type:'access'};
  const token=jwt.sign(payload,runtime.accessSecret,{expiresIn:900});
  const expired=jwt.sign(payload,runtime.accessSecret,{expiresIn:-1});
  try {
    for(const vector of vectors.cases){
      f.db.sessions.set('fixture-session-42',{user_id:42,session_id:'fixture-session-42',access_jti:'fixture-access-jti-42',access_token_expires_at:new Date(Date.now()+900000),revoked:!!vector.revoked});
      f.db.profileTouches=0;f.db.profileTouchFail=!!vector.touch_fail;globalThis.__selfProfileCalls=[];
      globalThis.__loginProfileError=vector.missing ? createError({statusCode:404,message:'用户不存在',data:{code:40401,message:'用户不存在',data:null,meta:null}}) : vector.fault ? new Error('private-profile-fixture') : null;
      const headers={};if(vector.auth==='valid')headers.authorization=`Bearer ${token}`;if(vector.auth==='cookie')headers.cookie=`access_token=${token}`;if(vector.auth==='bad-cookie'){headers.authorization=`Bearer ${token}`;headers.cookie='access_token=bad';}if(vector.auth==='expired')headers.authorization=`Bearer ${expired}`;
      const response=await f.request('/api/v2/users/me'+(vector.query??''),'GET',undefined,headers);const text=await response.text();
      assert.equal(response.status,vector.status,vector.id);assert.equal(f.db.profileTouches,vector.touches,vector.id);assert.equal(globalThis.__selfProfileCalls.length,vector.profiles,vector.id);assert.equal(response.headers.getSetCookie().length,0,vector.id);
      assert.doesNotMatch(text,/private-profile-fixture/,vector.id);
      if(vector.status===200){assert.equal(response.headers.get('cache-control'),'private, no-store',vector.id);assert.deepEqual(JSON.parse(text),{code:200,message:'success',data:vectors.profile,meta:null},vector.id);assert.deepEqual(globalThis.__selfProfileCalls,[42],vector.id);}
    }
    assert.doesNotMatch(JSON.stringify(globalThis.__authCompatErrors),/private-profile-fixture/);assert.doesNotMatch(errors.join('\n'),/private-profile-fixture/);
  } finally {console.error=oldError;delete globalThis.__authCompatErrors;delete globalThis.__selfProfileCalls;delete globalThis.__loginProfileError;delete globalThis.__registrationProfile;await f.close();}
});

test('shared moderator appeal scenarios preserve authorization, audit writes and idempotence', async () => {
  const f = await fixture();
  const previous = {accounts:process.env.MODERATION_ADMIN_ACCOUNTS,allow:process.env.MODERATION_ALLOW_ALL};
  process.env.MODERATION_ADMIN_ACCOUNTS=' Reviewer ';
  process.env.MODERATION_ALLOW_ALL='false';
  try {
    const {cases} = JSON.parse(readFileSync(path.join(root,'specifications/scenarios/moderation-appeals.json'),'utf8'));
    const token = jwt.sign({userId:42,userName:'staff',sessionId:'mod-appeal',jti:'mod-appeal-jti',type:'access'},runtime.accessSecret,{expiresIn:900});
    f.db.sessions.set('mod-appeal',{user_id:42,session_id:'mod-appeal',access_jti:'mod-appeal-jti',access_token_expires_at:new Date(Date.now()+900000),revoked:false});
    const records = new Map([12,13].map(id => [id,{APPEAL_ID:id,STATEMENT_ID:9,USER_ID:7,APPEAL_STATUS:'pending',ADMIN_RESPONSE:null}]));
    const flow = {records,change:null,audit:null,audits:[],rollbacks:0,denied:false};
    f.db.moderationFixture = flow;
    for (const vector of cases) {
      flow.denied = Boolean(vector.denied);
      const response = await f.request(vector.path,vector.method,vector.body,vector.status === 401 ? {} : {authorization:`Bearer ${token}`});
      assert.equal(response.status,vector.status,vector.id);
      assert.equal(response.headers.get('cache-control'),'private, no-store');
      const payload = await response.json();
      assert.doesNotMatch(JSON.stringify(payload),/private audit storage details/);
      if (vector.meta) {
        assert.deepEqual(payload.data,[]);
        assert.deepEqual(payload.meta,vector.meta);
      }
      if (vector.decision) {
        assert.equal(payload.data.appeal_id,12);
        assert.equal(payload.data.appeal_status,vector.decision);
        assert.equal(payload.data.admin_response,vector.reply);
      }
    }
    assert.equal(flow.audits.length,1);
    assert.equal(records.get(13).APPEAL_STATUS,'pending');
    assert.equal(flow.change,null);
    assert.equal(flow.rollbacks,4);
  } finally {
    for (const [name,value] of [['MODERATION_ADMIN_ACCOUNTS',previous.accounts],['MODERATION_ALLOW_ALL',previous.allow]]) {
      if (value === undefined) delete process.env[name]; else process.env[name] = value;
    }
    await f.close();
  }
});

test('shared moderator report scenarios enforce review permission and transactional updates', async () => {
  const f = await fixture();
  const previous = process.env.MODERATION_ADMIN_ACCOUNTS;
  process.env.MODERATION_ADMIN_ACCOUNTS = ' Reviewer ';
  try {
    const {cases} = JSON.parse(readFileSync(path.join(root,'specifications/scenarios/moderation-reports.json'),'utf8'));
    const token = jwt.sign({userId:42,userName:'staff',sessionId:'mod-report',jti:'report-jti',type:'access'},runtime.accessSecret,{expiresIn:900});
    f.db.sessions.set('mod-report',{user_id:42,session_id:'mod-report',access_jti:'report-jti',access_token_expires_at:new Date(Date.now()+900000),revoked:false});
    const records = new Map([12,13].map(id => [id,{
      REPORT_ID:id, TARGET_TYPE:'group_post', TARGET_ID:65, REASON:'spam', STATUS:'pending', PRIORITY:'normal', RESOLVED_AT:null
    }]));
    const flow = {records,change:null,audit:null,rollbacks:0,writes:0,denied:false};
    f.db.moderationFixture = flow;
    for (const vector of cases.filter(item => item.method !== 'POST')) {
      flow.denied = Boolean(vector.denied);
      const response = await f.request(vector.path,vector.method,vector.body,vector.status === 401 ? {} : {authorization:`Bearer ${token}`});
      const payload = await response.json();
      assert.equal(response.status,vector.status,vector.id);
      assert.equal(response.headers.get('cache-control'),'private, no-store');
      assert.doesNotMatch(JSON.stringify(payload),/private report readback failure/);
      if (vector.meta) {
        assert.deepEqual(payload.data,[]);
        assert.deepEqual(payload.meta,vector.meta);
      }
      if (vector.expectStatus) {
        assert.equal(payload.data.report_id,12);
        assert.equal(payload.data.status,vector.expectStatus);
        assert.equal(payload.data.resolved_at,vector.expectStatus === 'resolved' ? '2026-11-16T01:00:00.000Z' : null);
      }
    }
    assert.equal(flow.writes,3);
    assert.equal(flow.rollbacks,2);
    assert.equal(records.get(13).STATUS,'pending');
  } finally {
    if (previous === undefined) delete process.env.MODERATION_ADMIN_ACCOUNTS;
    else process.env.MODERATION_ADMIN_ACCOUNTS = previous;
    await f.close();
  }
});

test('shared report submission scenarios enforce visible targets, retries and case rollback', async () => {
  const f = await fixture();
  try {
    const {cases} = JSON.parse(readFileSync(path.join(root,'specifications/scenarios/moderation-reports.json'),'utf8'));
    const token = jwt.sign({userId:42,userName:'member',sessionId:'submit-report',jti:'report-jti',type:'access'},runtime.accessSecret,{expiresIn:900});
    f.db.sessions.set('submit-report',{user_id:42,session_id:'submit-report',access_jti:'report-jti',access_token_expires_at:new Date(Date.now()+900000),revoked:false});
    const flow = {records:new Map(), nextReport:15, inserts:0, caseWrites:0, rollbacks:0};
    f.db.moderationFixture = flow;
    for (const vector of cases.filter(item => item.method === 'POST')) {
      const response = await f.request(vector.path,vector.method,vector.body,vector.status === 401 ? {} : {authorization:`Bearer ${token}`});
      const payload = await response.json();
      assert.equal(response.status,vector.status,vector.id);
      assert.equal(response.headers.get('cache-control'),'private, no-store');
      assert.doesNotMatch(JSON.stringify(payload),/private isolated case failure/);
      if (vector.reportId) {
        assert.equal(payload.data.report_id,vector.reportId);
        assert.equal(payload.data.description,'Detail');
        assert.equal(payload.data.evidence_url,'/tweet/30');
      }
    }
    assert.equal(flow.inserts,2);
    assert.equal(flow.caseWrites,1);
    assert.equal(flow.rollbacks,3);
    assert.deepEqual([...flow.records.keys()],[15]);
  } finally {
    await f.close();
  }
});

test('shared moderation dashboard scenarios validate a batch before writing and roll back failed updates', async () => {
  const f = await fixture();
  const previous = process.env.MODERATION_ADMIN_ACCOUNTS;
  process.env.MODERATION_ADMIN_ACCOUNTS = ' Reviewer ';
  try {
    const {cases} = JSON.parse(readFileSync(path.join(root,'specifications/scenarios/moderation-dashboard.json'),'utf8'));
    const token = jwt.sign({userId:42,userName:'staff',sessionId:'dashboard',jti:'dashboard-jti',type:'access'},runtime.accessSecret,{expiresIn:900});
    f.db.sessions.set('dashboard',{user_id:42,access_jti:'dashboard-jti',access_token_expires_at:new Date(Date.now()+900000),revoked:false});
    const flow = {stats:cases.find(item => item.stats).stats,values:{default_mute_hours:'24',require_note_on_reject:'true'},pending:{},writes:[],commits:0,rollbacks:0};
    f.db.dashboardFixture = flow;
    f.db.rollback = async () => { flow.pending={}; flow.rollbacks++; };
    for (const vector of cases) {
      flow.denied = Boolean(vector.denied);
      const response = await f.request(vector.path,vector.method,vector.body,vector.status === 401 ? {} : {authorization:`Bearer ${token}`});
      const payload = await response.json();
      assert.equal(response.status,vector.status,vector.id);
      assert.equal(response.headers.get('cache-control'),'private, no-store');
      assert.doesNotMatch(JSON.stringify(payload),/isolated private dashboard update failure/);
      if (vector.stats) assert.deepEqual(payload.data,vector.stats);
      if (vector.values) {
        assert.deepEqual(Object.fromEntries(payload.data.map(({key,value}) => [key,value])),vector.values);
        assert.deepEqual(payload.data.map(item => item.key),Object.keys(vector.values).sort());
      }
    }
    assert.deepEqual(flow.writes,[
      ['default_mute_hours','36'],['require_note_on_reject','false'],
      ['default_mute_hours','77'],['require_note_on_reject','true']
    ]);
    assert.equal(flow.commits,1);
    assert.equal(flow.rollbacks,1);
  } finally {
    if (previous === undefined) delete process.env.MODERATION_ADMIN_ACCOUNTS;
    else process.env.MODERATION_ADMIN_ACCOUNTS = previous;
    await f.close();
  }
});

test('shared moderation user queue scenarios verify scoped access and paging', async () => {
  const f = await fixture();
  const previous = process.env.MODERATION_ADMIN_ACCOUNTS;
  process.env.MODERATION_ADMIN_ACCOUNTS = ' Reviewer ';
  try {
    const {cases} = JSON.parse(readFileSync(path.join(root,'specifications/scenarios/moderation-user-queue.json'),'utf8'));
    const token = jwt.sign({userId:42,userName:'staff',sessionId:'user-queue',jti:'queue-jti',type:'access'},runtime.accessSecret,{expiresIn:900});
    f.db.sessions.set('user-queue',{user_id:42,access_jti:'queue-jti',access_token_expires_at:new Date(Date.now()+900000),revoked:false});
    for (const vector of cases) {
      f.db.userQueueFixture = vector;
      const response = await f.request(vector.path,vector.method,undefined,vector.status === 401 ? {} : {authorization:`Bearer ${token}`});
      const payload = await response.json();
      assert.equal(response.status,vector.status,vector.id);
      assert.equal(response.headers.get('cache-control'),'private, no-store');
      if (vector.data) {
        assert.deepEqual(payload.data,vector.data);
        assert.deepEqual(payload.meta,vector.meta);
      }
    }
    const vector = cases.find(item => item.id === 'filtered');
    f.db.userQueueFixture = {
      ...vector,verifyAction:true,
      query:{user_id:7,status:null,q:null,sort:'newest',start_row:1,end_row:1}
    };
    const action = await f.request('/api/v2/moderation/users/7/actions?status=disabled&page=2','POST',
      {action:'note',note:'Reviewed'}, {authorization:`Bearer ${token}`});
    assert.equal(action.status,200);
    assert.deepEqual((await action.json()).data,vector.data[0]);
  } finally {
    if (previous === undefined) delete process.env.MODERATION_ADMIN_ACCOUNTS;
    else process.env.MODERATION_ADMIN_ACCOUNTS = previous;
    await f.close();
  }
});

test('shared moderation content queue scenarios preserve filters, attachments, and report order', async () => {
  const f=await fixture();
  const previous=process.env.MODERATION_ADMIN_ACCOUNTS;
  process.env.MODERATION_ADMIN_ACCOUNTS=' Reviewer ';
  try {
    const {cases}=JSON.parse(readFileSync(path.join(root,'specifications/scenarios/moderation-content-queue.json'),'utf8'));
    const token=jwt.sign({userId:42,userName:'staff',sessionId:'case-queue',jti:'queue-jti',type:'access'},runtime.accessSecret,{expiresIn:900});
    f.db.sessions.set('case-queue',{user_id:42,access_jti:'queue-jti',access_token_expires_at:new Date(Date.now()+900000),revoked:false});
    for (const vector of cases) {
      f.db.contentQueueFixture=vector;
      const resp=await f.request(vector.path,vector.method,undefined,vector.status===401 ? {} : {authorization:`Bearer ${token}`});
      const payload=await resp.json();
      assert.equal(resp.status,vector.status,vector.id);
      assert.equal(resp.headers.get('cache-control'),'private, no-store');
      if (vector.meta) {
        assert.deepEqual(payload.meta,vector.meta);
        if (!vector.item) assert.deepEqual(payload.data,[]);
        else {
          const [item]=payload.data;
          assert.deepEqual({
            case_id:item.case_id,post_id:item.post_id,report_reasons:item.report_reasons,
            report_ids:item.reports.map(r=>r.report_id), media_ids:item.media.map(m=>m.media_id)
          },vector.item);
        }
      }
    }
    const v=cases.find(item=>item.id==='full-row');
    f.db.contentQueueFixture={
      ...v,verifyAction:true,
      query:{post_id:v.item.post_id,status:null,priority:null,reason:null,q:null,sort:'newest',date_range:'all',start_row:1,end_row:1}
    };
    const action=await f.request('/api/v2/moderation/content/81/actions?priority=low&page=9','POST',
      {action:'claim'}, {authorization:`Bearer ${token}`});
    assert.equal(action.status,200);
    assert.equal((await action.json()).data.post_id,81);
  } finally {
    if (previous===undefined) delete process.env.MODERATION_ADMIN_ACCOUNTS;
    else process.env.MODERATION_ADMIN_ACCOUNTS=previous;
    await f.close();
  }
});

test('shared post moderation action cases enforce policy and roll back the whole batch', async () => {
  const f=await fixture();
  const previous=process.env.MODERATION_ADMIN_ACCOUNTS;
  process.env.MODERATION_ADMIN_ACCOUNTS=' Reviewer ';
  try {
    const {cases}=JSON.parse(readFileSync(path.join(root,'specifications/scenarios/moderation-post-actions.json'),'utf8'));
    const token=jwt.sign({userId:42,userName:'staff',sessionId:'post-actions',jti:'post-jti',type:'access'},runtime.accessSecret,{expiresIn:900});
    f.db.sessions.set('post-actions',{user_id:42,access_jti:'post-jti',access_token_expires_at:new Date(Date.now()+900000),revoked:false});
    for (const vector of cases) {
      const flow={vector,pending:[],commits:[],locks:[],rollbacks:0};
      f.db.postActionFixture=flow;
      f.db.rollback=async()=>{flow.pending=[];flow.rollbacks++;};
      const resp=await f.request(vector.path,vector.method,vector.body,vector.status===401 ? {} : {authorization:`Bearer ${token}`});
      const payload=await resp.json();
      assert.equal(resp.status,vector.status,vector.id);
      assert.equal(resp.headers.get('cache-control'),'private, no-store');
      if (vector.error) assert.equal(payload.data.message,vector.error);
      assert.doesNotMatch(JSON.stringify(payload),/private audit failure/);
      assert.equal(flow.commits.length,vector.status===200 ? 1 : 0);
      if (vector.auditFail) {
        assert.deepEqual(flow.locks,[81,82]);
        assert.equal(flow.rollbacks,1);
        assert.deepEqual(flow.pending,[]);
      }
      if (vector.item) {
        for (const [key,value] of Object.entries(vector.item)) assert.equal(payload.data[key],value);
      }
      if (vector.processed) {
        assert.equal(payload.data.processed_count,vector.processed);
        assert.deepEqual(flow.locks,[81,82]);
        assert.deepEqual(flow.commits[0].filter(write=>write.sql.startsWith('INSERT INTO n_moderation_actions')).map(write=>write.binds.post_id),[81,82]);
      }
      if (vector.id==='note-trimmed') {
        const audit=flow.commits[0].find(write=>write.sql.startsWith('INSERT INTO n_moderation_actions'));
        assert.equal(audit.binds.note,'Reviewed');
        assert.equal(audit.binds.reason,'duplicate');
      }
    }
  } finally {
    if (previous===undefined) delete process.env.MODERATION_ADMIN_ACCOUNTS;
    else process.env.MODERATION_ADMIN_ACCOUNTS=previous;
    await f.close();
  }
});

test('shared user moderation action scenarios keep suspension, sessions and audit atomic', async () => {
  const f=await fixture();
  const previous=process.env.MODERATION_ADMIN_ACCOUNTS;
  process.env.MODERATION_ADMIN_ACCOUNTS=' Reviewer ';
  try {
    const load=p=>JSON.parse(readFileSync(path.join(root,p),'utf8'));
    const {cases}=load('specifications/scenarios/moderation-user-actions.json');
    const {sql}=load('specifications/requirements/moderation-user-actions.json');
    const token=jwt.sign({userId:42,userName:'staff',sessionId:'user-actions',jti:'user-jti',type:'access'},runtime.accessSecret,{expiresIn:900});
    f.db.sessions.set('user-actions',{user_id:42,access_jti:'user-jti',access_token_expires_at:new Date(Date.now()+900000),revoked:false});
    for (const vector of cases) {
      const flow={vector,sql,attempted:[],pending:[],commits:[],rollbacks:0};
      f.db.userActionFixture=flow;
      f.db.rollback=async()=>{flow.pending=[];flow.rollbacks++;};
      const resp=await f.request(vector.path,vector.method,vector.body,vector.status===401 ? {} : {authorization:`Bearer ${token}`});
      const payload=await resp.json();
      assert.equal(resp.status,vector.status,vector.id);
      assert.equal(resp.headers.get('cache-control'),'private, no-store');
      assert.doesNotMatch(JSON.stringify(payload),/private user action audit failure/);
      if (vector.error) assert.equal(payload.data.message,vector.error);
      assert.equal(flow.commits.length,vector.status===200 ? 1 : 0);
      assert.deepEqual(flow.attempted,vector.writes ?? []);
      if (vector.item) for (const [key,value] of Object.entries(vector.item)) assert.equal(payload.data[key],value);
      if (vector.auditFail) {
        assert.equal(flow.rollbacks,1);
        assert.deepEqual(flow.pending,[]);
      }
    }
  } finally {
    if (previous===undefined) delete process.env.MODERATION_ADMIN_ACCOUNTS;
    else process.env.MODERATION_ADMIN_ACCOUNTS=previous;
    await f.close();
  }
});

test('shared statement scenarios exercise scoped records, repeat appeals and rollback', async () => {
  const f = await fixture();
  try {
    const {cases} = JSON.parse(readFileSync(path.join(root,'specifications/scenarios/account-statements.json'),'utf8'));
    const token = jwt.sign({userId:42,userName:'me',sessionId:'statements',jti:'statement-jti',type:'access'},runtime.accessSecret,{expiresIn:900});
    f.db.sessions.set('statements',{user_id:42,session_id:'statements',access_jti:'statement-jti',access_token_expires_at:new Date(Date.now()+900000),revoked:false});
    const flow = {pending:null,inserted:null,changed:null,status:'unread',inserts:0,rollbacks:0};
    f.db.statementFixture = flow;
    for (const vector of cases) {
      const response = await f.request(vector.path,vector.method,vector.body,vector.status === 401 ? {} : {authorization:`Bearer ${token}`});
      const payload = await response.json();
      assert.equal(response.status, vector.status, vector.id);
      assert.equal(response.headers.get('cache-control'), 'private, no-store');
      assert.doesNotMatch(JSON.stringify(payload), /private workflow database failure/);
      if (vector.meta) {
        assert.deepEqual(payload.data, []);
        assert.deepEqual(payload.meta, vector.meta);
      } else if (vector.data) {
        assert.deepEqual(payload.data, vector.data, vector.id);
      }
    }
    assert.equal(flow.inserts,2);
    assert.equal(flow.pending.APPEAL_MESSAGE,'Check rule application');
    assert.equal(flow.inserted,null);
    assert.equal(flow.rollbacks,4);
  } finally { await f.close(); }
});

for (const version of ['v2', 'v1']) test(`avatar ${version} route preserves old objects and cleans temporary uploads`, async () => {
  const f = await fixture();
  const temp = await mkdtemp(path.join(tmpdir(), 'neko-avatar-'));
  const legacy = version === 'v1';
  const previousLegacyFlag = process.env.ENABLE_V1_API;
  if (legacy) process.env.ENABLE_V1_API = 'true';
  try {
    const {cases} = JSON.parse(readFileSync(path.join(root,'specifications/scenarios/user-avatar.json'),'utf8'));
    const token = jwt.sign({userId:42,userName:'me',sessionId:'avatar',jti:'avatar-jti',type:'access'},runtime.accessSecret,{expiresIn:900});
    f.db.sessions.set('avatar',{user_id:42,session_id:'avatar',access_jti:'avatar-jti',access_token_expires_at:new Date(Date.now()+900000),revoked:false});
    for (const original of cases) {
      const vector = legacy && original.id === 'file-wins-over-avatar'
        ? {...original, extension:'.png', mime:'image/png'}
        : original;
      const oldKey = 'avatars/42/old.png';
      const objects = new Map([[oldKey, Buffer.from('existing')]]);
      const key = 'avatars/42/new' + vector.extension;
      let tempRequests = 0;
      globalThis.__avatarStorage = {
        tempDir() { tempRequests++; return temp; },
        async save(user, file, validated) {
          assert.equal(user, 42);
          assert.equal(validated.extension, vector.extension);
          objects.set(key, await readFile(file));
          return {key,url:'/storage/'+key,size:validated.size,originalName:validated.originalName,contentType:validated.mimeType};
        },
        remove({storageKey}) { assert.equal(storageKey, key); objects.delete(storageKey); }
      };
      f.db.avatarCase = vector;
      f.db.avatarCalls = [];
      const boundary = 'neko-avatar-fixture';
      const body = [];
      for (const part of vector.parts) {
        const bytes = Buffer.alloc(part.size ?? part.hex.length / 2);
        bytes.write(part.hex,'hex');
        const filename = part.name === undefined ? '' : `; filename="${part.name}"`;
        const type = part.contentType ?? 'image/png';
        const typeHeader = type ? `Content-Type: ${type}\r\n` : '';
        body.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="${part.field}"${filename}\r\n${typeHeader}\r\n`),
          bytes, Buffer.from('\r\n'));
      }
      body.push(Buffer.from(`--${boundary}--\r\n`));
      const invalidStorage = vector.fault === 'storage-config';
      const env = {STORAGE_TYPE:process.env.STORAGE_TYPE, STORAGE_S3_ENDPOINT:process.env.STORAGE_S3_ENDPOINT};
      process.env.STORAGE_TYPE = invalidStorage ? 's3' : 'local';
      if (invalidStorage) process.env.STORAGE_S3_ENDPOINT = '';
      const headers = {'content-type':`multipart/form-data; boundary=${boundary}`};
      if (vector.status !== 401) headers.authorization = `Bearer ${token}`;
      const response = await f.requestRaw(`/api/${version}/users/me/avatar?user_id=99`, legacy ? 'POST' : 'PUT',
        Buffer.concat(body), headers).finally(() => {
          for (const [key, value] of Object.entries(env)) {
            if (value === undefined) delete process.env[key];
            else process.env[key] = value;
          }
        });
      const payload = await response.json();
      const expectedStatus = legacy ? vector.legacyStatus ?? vector.status : vector.status;
      assert.equal(response.status, expectedStatus, vector.id);
      if (invalidStorage) {
        assert.equal(tempRequests, 0, vector.id);
        if (!legacy) assert.deepEqual(payload.data, {
          code:50301, message:'媒体存储暂不可用', data:null, meta:null,
        });
      }
      assert.doesNotMatch(JSON.stringify(payload), /private (?:update|commit) failure/);
      if (vector.status !== 401) assert.equal(response.headers.get('cache-control'), 'private, no-store');
      if (vector.status === 200) {
        assert.deepEqual(payload.data, legacy ? {url:'/storage/'+key} : {avatar_url:'/storage/'+key, avatar_media_id:12});
        if (legacy) {
          assert.equal(payload.success,true);
          assert.equal(payload.message,'头像上传成功');
          assert.ok(Number.isFinite(Date.parse(payload.timestamp)));
        }
      }
      if (legacy && vector.status !== 200) {
        assert.equal(payload.data.success,false);
        assert.equal(payload.data.code,expectedStatus);
      }
      assert.deepEqual(f.db.avatarCalls, vector.extension ? ['lock','next','insert','update',vector.fault === 'rollback' ? 'rollback' : 'commit'] : []);
      assert.equal(objects.has(oldKey), true);
      assert.equal(objects.has(key), vector.status === 200 || vector.fault === 'commit');
      assert.deepEqual(await readdir(temp), [], vector.id);
    }
  } finally {
    if (legacy) {
      if (previousLegacyFlag === undefined) delete process.env.ENABLE_V1_API;
      else process.env.ENABLE_V1_API = previousLegacyFlag;
    }
    delete globalThis.__avatarStorage;
    await f.close();
    await rmdir(temp);
  }
});

test('shared block and mute vectors exercise the real Nuxt routes', async () => {
  const f = await fixture();
  try {
    const vectors = JSON.parse(readFileSync(path.join(root,'specifications/scenarios/user-visibility.json'),'utf8'));
    f.db.visibilityFixture = true;
    const token = jwt.sign({userId:42,userName:'me',sessionId:'visible-fixture',jti:'visible-jti',type:'access'},runtime.accessSecret,{expiresIn:900});
    f.db.sessions.set('visible-fixture',{user_id:42,session_id:'visible-fixture',access_jti:'visible-jti',access_token_expires_at:new Date(Date.now()+900000),revoked:false});
    assert.equal((await f.request('/api/v2/users/me/blocks','GET')).status,401);
    for (const vector of vectors.cases) {
      const first = f.db.calls.length;
      const response = await f.request(vector.path,vector.method,vector.body,{authorization:`Bearer ${token}`});
      const payload = await response.json();
      assert.equal(response.status,vector.status,vector.id);
      if (vector.method === 'GET') {
        assert.equal(response.headers.get('cache-control'),'private, no-store');
        assert.deepEqual(payload.data, []);
        assert.deepEqual(payload.meta,{page:2,page_size:2,total:2,has_next:false});
      } else if (vector.status === 200) {
        assert.equal(payload.data.relationship,vector.relationship,vector.id);
        assert.equal(payload.data.expires_at,vector.expires_at,vector.id);
      }
      if (vector.id === 'block') {
        const writes = f.db.calls.slice(first).filter(call => /^(MERGE INTO n_user_blocks|UPDATE n_user_follows)/.test(call.sql));
        assert.equal(writes.length,2);
        assert(writes.every(call => call.options.autoCommit === false));
      }
    }
  } finally { await f.close(); }
});

test('shared follow vectors use committed changes for notification deduplication', async () => {
  const f = await fixture();
  const notices = [];
  globalThis.__followNotices = notices;
  try {
    const vectors = JSON.parse(readFileSync(path.join(root,'specifications/scenarios/user-follow.json'),'utf8'));
    f.db.followFixture = true;
    const token = jwt.sign({userId:42,userName:'me',sessionId:'follow-fixture',jti:'follow-jti',type:'access'},runtime.accessSecret,{expiresIn:900});
    f.db.sessions.set('follow-fixture',{user_id:42,session_id:'follow-fixture',access_jti:'follow-jti',access_token_expires_at:new Date(Date.now()+900000),revoked:false});
    for (const vector of vectors.cases) {
      const from = notices.length;
      const response = await f.request(vector.path, vector.method, undefined, vector.id === 'anonymous' ? {} : {authorization:`Bearer ${token}`});
      const payload = await response.json();
      assert.equal(response.status, vector.status, vector.id);
      assert.equal(notices.length - from, Number(Boolean(vector.notify)), vector.id);
      if (vector.relationship) {
        assert.equal(payload.data.relationship, vector.relationship, vector.id);
        assert.equal(payload.data.followers_count, vector.count, vector.id);
      } else if (vector.status === 200) {
        assert.equal(response.headers.get('cache-control'),'private, no-store');
        assert.deepEqual(payload.meta,{page:2,page_size:2,total:2,has_next:false});
      }
    }
    assert.deepEqual(notices.map(n => [n.userId,n.actorId,n.type,n.metadata.event]), [[9,42,'follow','user_follow'],[9,42,'follow','user_follow']]);
  } finally { delete globalThis.__followNotices; await f.close(); }
});

test('shared discovery cases use the actual Nuxt routes and owner-bound binds', async () => {
  const f = await fixture();
  try {
    const { cases } = JSON.parse(readFileSync(path.join(root,'specifications/scenarios/user-discovery.json'),'utf8'));
    const token = jwt.sign({userId:42,userName:'me',sessionId:'discovery',jti:'discovery-jti',type:'access'},runtime.accessSecret,{expiresIn:900});
    f.db.sessions.set('discovery',{user_id:42,session_id:'discovery',access_jti:'discovery-jti',access_token_expires_at:new Date(Date.now()+900000),revoked:false});
    for (const vector of cases) {
      f.db.discoveryCase = vector;
      const response = await f.request(vector.path, 'GET', undefined, vector.status === 401 ? {} : {authorization:`Bearer ${token}`});
      assert.equal(response.status, vector.status, vector.id);
      if (vector.status !== 200) continue;
      const payload = await response.json();
      assert.equal(response.headers.get('cache-control'), 'private, no-store');
      assert.equal(payload.data.length, vector.empty ? 0 : 1);
      assert.deepEqual(payload.meta, vector.meta);
    }
  } finally { await f.close(); }
});

test('shared public profiles enforce identity, public fields and bounded IDs', async () => {
  const vectors=JSON.parse(readFileSync(path.join(root,'specifications/scenarios/user-public-profile.json'),'utf8'));
  const f=await fixture();const oldError=console.error;const errors=[];console.error=(...args)=>errors.push(args.map(String).join(' '));globalThis.__authCompatErrors=[];
  const payload={userId:42,userName:'selfuser',sessionId:'fixture-session-42',jti:'fixture-access-jti-42',type:'access'};
  const token=jwt.sign(payload,runtime.accessSecret,{expiresIn:900});const expired=jwt.sign(payload,runtime.accessSecret,{expiresIn:-1});
  try {for(const vector of vectors.cases){
    f.db.sessions.set('fixture-session-42',{user_id:42,session_id:'fixture-session-42',access_jti:'fixture-access-jti-42',access_token_expires_at:new Date(Date.now()+900000),revoked:!!vector.revoked});f.db.profileTouchFail=!!vector.touch_fail;globalThis.__publicCalls=[];
    const profile=structuredClone(vectors.profile);if(vector.hidden){profile.online_status='hidden';profile.last_seen_at=null}if(vector.offline)profile.online_status='offline';globalThis.__publicProfile=profile;
    globalThis.__publicError=vector.missing?createError({statusCode:404,message:'用户不存在',data:{code:40401,message:'用户不存在',data:null,meta:null}}):vector.fault?new Error('private-public-profile-error'):null;
    const headers={};if(vector.auth==='valid')headers.authorization=`Bearer ${token}`;if(vector.auth==='cookie')headers.cookie=`access_token=${token}`;if(vector.auth==='bad-cookie'){headers.authorization=`Bearer ${token}`;headers.cookie='access_token=bad';}if(vector.auth==='expired')headers.authorization=`Bearer ${expired}`;
    const response=await f.request(`/api/v2/users/${vector.target}?viewer_id=99`,'GET',undefined,headers);const text=await response.text();assert.equal(response.status,vector.status,vector.id);assert.equal(globalThis.__publicCalls.length,vector.profiles,vector.id);assert.doesNotMatch(text,/private-public-profile-error/,vector.id);
    if(vector.status===200){assert.deepEqual(globalThis.__publicCalls,[[42,7]],vector.id);assert.equal(response.headers.get('cache-control'),'private, no-store',vector.id);assert.deepEqual(JSON.parse(text).data,profile,vector.id);}
  }assert.doesNotMatch(JSON.stringify(globalThis.__authCompatErrors),/private-public-profile-error/);assert.doesNotMatch(errors.join('\n'),/private-public-profile-error/);
  }finally{console.error=oldError;delete globalThis.__authCompatErrors;delete globalThis.__publicCalls;delete globalThis.__publicProfile;delete globalThis.__publicError;await f.close()}
});

test('shared self-profile updates preserve identity, fields and safe errors', async () => {
  const vectors=JSON.parse(readFileSync(path.join(root,'specifications/scenarios/user-self-profile-update.json'),'utf8'));
  const profiles=JSON.parse(readFileSync(path.join(root,'specifications/scenarios/user-self-profile.json'),'utf8'));
  const f=await fixture();const oldError=console.error;const errors=[];console.error=(...args)=>errors.push(args.map(String).join(' '));
  globalThis.__authCompatErrors=[];globalThis.__registrationProfile=profiles.profile;f.db.profilePatchMode=true;
  const payload={userId:42,userName:'selfuser',sessionId:'fixture-session-42',jti:'fixture-access-jti-42',type:'access'};
  const token=jwt.sign(payload,runtime.accessSecret,{expiresIn:900});const expired=jwt.sign(payload,runtime.accessSecret,{expiresIn:-1});
  try { for(const vector of vectors.cases) {
    f.db.sessions.set('fixture-session-42',{user_id:42,session_id:'fixture-session-42',access_jti:'fixture-access-jti-42',access_token_expires_at:new Date(Date.now()+900000),revoked:!!vector.revoked});
    f.db.profileTouchFail=!!vector.touch_fail; f.db.profileUpdateFail=!!vector.update_fail; f.db.profileWrites=[];globalThis.__selfProfileCalls=[];
    globalThis.__loginProfileError=vector.missing ? createError({statusCode:404,message:'用户不存在',data:{code:40401,message:'用户不存在',data:null,meta:null}}) : vector.profile_fail ? new Error('private-profile-fixture') : null;
    const headers={};if(vector.auth==='valid')headers.authorization=`Bearer ${token}`;if(vector.auth==='cookie')headers.cookie=`access_token=${token}`;if(vector.auth==='bad-cookie'){headers.authorization=`Bearer ${token}`;headers.cookie='access_token=bad';}if(vector.auth==='expired')headers.authorization=`Bearer ${expired}`;
    const response=await f.request('/api/v2/users/me?user_id=99','PATCH',vector.body,headers);const text=await response.text();
    assert.equal(response.status,vector.status,vector.id);assert.equal(f.db.profileWrites.length,vector.updates,vector.id);assert.equal(globalThis.__selfProfileCalls.length,vector.profiles,vector.id);assert.doesNotMatch(text,/private-(update|profile)-fixture/,vector.id);
    if(vector.updates){const w=f.db.profileWrites[0]; const expected={user_id:42,...vector.fields};if(expected.birth_date==='')expected.birth_date=null;assert.deepEqual(w.binds,expected,vector.id);assert.equal(w.options.autoCommit,true,vector.id);}
    if(vector.status===200){assert.equal(response.headers.get('cache-control'),'private, no-store',vector.id);assert.equal(response.headers.getSetCookie().length,0,vector.id);}
  }
    f.db.profileTouchFail=false;f.db.profileUpdateFail=false;
    f.db.sessions.set('fixture-session-42',{user_id:42,session_id:'fixture-session-42',access_jti:'fixture-access-jti-42',access_token_expires_at:new Date(Date.now()+900000),revoked:false});
    globalThis.__loginProfileError=null;
    const limit=1024*1024;
    const headers={authorization:`Bearer ${token}`,'content-type':'application/x-www-form-urlencoded'};
    const prefix='birth_date=2000-02-29&ignored=';
    for (const [bytes,status] of [[limit,200],[limit+1,400]]) {
      f.db.profileWrites=[];globalThis.__selfProfileCalls=[];
      const response=await f.requestRaw('/api/v2/users/me','PATCH',prefix+'x'.repeat(bytes-prefix.length),headers);
      const result=await response.json();
      assert.equal(response.status,status);
      assert.equal(response.headers.get('cache-control'),'private, no-store');
      assert.equal(f.db.profileWrites.length,status===200?1:0);
      assert.equal(globalThis.__selfProfileCalls.length,status===200?1:0);
      if(status===200) assert.equal(f.db.profileWrites[0].binds.birth_date,'2000-02-29');
      else assert.equal(result.data.code,40001);
    }
    assert.doesNotMatch(JSON.stringify(globalThis.__authCompatErrors),/private-(update|profile)-fixture/);assert.doesNotMatch(errors.join('\n'),/private-(update|profile)-fixture/);
  } finally {console.error=oldError;delete globalThis.__authCompatErrors;delete globalThis.__selfProfileCalls;delete globalThis.__loginProfileError;delete globalThis.__registrationProfile;await f.close();}
});

test('shared email change routes preserve auth, new-email binding and atomic side effects', async () => {
  const vectors=JSON.parse(readFileSync(path.join(root,'specifications/scenarios/auth-email-change.json'),'utf8'));
  assert.equal(vectors.cases.length,25);
  const f=await fixture(),hash=await bcrypt.hash('123456',4);
  const payload={userId:42,userName:'selfuser',sessionId:'fixture-session-42',jti:'fixture-access-jti-42',type:'access'};
  const token=jwt.sign(payload,runtime.accessSecret,{expiresIn:900});
  f.db.sessions.set('fixture-session-42',{user_id:42,session_id:'fixture-session-42',access_jti:'fixture-access-jti-42',access_token_expires_at:new Date(Date.now()+900000),revoked:false});
  globalThis.__authCompatErrors=[];
  try {
    for(const c of vectors.cases){
      f.db.emailChangeMode=true;f.db.emailCase=c;f.db.emailMarks=0;f.db.emailWrites=0;f.db.pendingEmail=null;
      f.db.otp={account:'new@example.test',type:'change_email',verification_id:'email_fixture',hash,expired:!!c.expired};
      f.db.otpFault=c.fault==='lookup'?'lookup':undefined;
      for(const session of f.db.sessions.values())session.revoked=c.auth==='revoked';
      const response=await f.request('/api/v2/users/me/email','PATCH',{...vectors.base,...c.patch},c.auth==='none'?{}:{authorization:'Bearer '+token});
      const text=await response.text(),body=JSON.parse(text);
      assert.equal(response.status,c.status,c.id);assert.equal(response.status===200?body.message:body.data?.message,c.message,c.id);
      assert.equal(f.db.emailMarks,c.marks,c.id);assert.equal(f.db.emailWrites,c.writes,c.id);assert.equal(f.db.pendingEmail,null,c.id);
      assert.equal(response.headers.getSetCookie().length,0);assert.doesNotMatch(text,/email-private-fixture|otp-internal-sensitive-fixture|\$2[aby]\$|123456/);
      if(c.status===200){assert.deepEqual(body.data,{email:'new@example.test',email_verified_at:vectors.verified_at});assert.equal(f.db.otp.hash,'!consumed!');}
    }
    assert.doesNotMatch(JSON.stringify(globalThis.__authCompatErrors),/email-private-fixture|otp-internal-sensitive-fixture/);
  } finally {await f.close();delete globalThis.__authCompatErrors;}
});

test('email change supports authenticated form data and rejects OTP replay',async()=>{
  const f=await fixture();f.db.emailChangeMode=true;f.db.emailCase={};f.db.emailMarks=0;f.db.emailWrites=0;f.db.pendingEmail=null;
  f.db.otp={account:'new@example.test',type:'change_email',verification_id:'email_fixture',hash:await bcrypt.hash('123456',4)};
  const payload={userId:42,userName:'selfuser',sessionId:'fixture-session-42',jti:'fixture-access-jti-42',type:'access'};
  const token=jwt.sign(payload,runtime.accessSecret,{expiresIn:900});
  f.db.sessions.set('fixture-session-42',{user_id:42,session_id:'fixture-session-42',access_jti:'fixture-access-jti-42',access_token_expires_at:new Date(Date.now()+900000),revoked:false});
  const body=()=>new URLSearchParams({new_email:'new@example.test',verification_id:'email_fixture',code:'123456'});
  try{
    const first=await f.requestRaw('/api/v2/users/me/email','PATCH',body(),{'content-type':'application/x-www-form-urlencoded',cookie:'access_token='+token});
    assert.equal(first.status,200);assert.equal(f.db.emailWrites,1);assert.equal(f.db.emailMarks,1);
    const second=await f.requestRaw('/api/v2/users/me/email','PATCH',body(),{'content-type':'application/x-www-form-urlencoded',cookie:'access_token='+token});
    assert.equal(second.status,400);assert.equal(f.db.emailWrites,1);assert.equal(f.db.emailMarks,1);
  }finally{await f.close();}
});

test('email change close failure returns a safe error after the committed write',async()=>{
  const f=await fixture();f.db.emailChangeMode=true;f.db.emailCase={};f.db.emailMarks=0;f.db.emailWrites=0;f.db.pendingEmail=null;
  f.db.otp={account:'new@example.test',type:'change_email',verification_id:'email_fixture',hash:await bcrypt.hash('123456',4)};
  const payload={userId:42,userName:'selfuser',sessionId:'fixture-session-42',jti:'fixture-access-jti-42',type:'access'};
  const token=jwt.sign(payload,runtime.accessSecret,{expiresIn:900});
  f.db.sessions.set('fixture-session-42',{user_id:42,session_id:'fixture-session-42',access_jti:'fixture-access-jti-42',access_token_expires_at:new Date(Date.now()+900000),revoked:false});
  f.db.close=async()=>{if(f.db.emailWrites>0)throw new Error('email-private-fixture')};
  try{
    const response=await f.request('/api/v2/users/me/email','PATCH',{new_email:'new@example.test',verification_id:'email_fixture',code:'123456'},{authorization:'Bearer '+token});
    assert.equal(response.status,500);assert.equal(f.db.emailWrites,1);assert.equal(f.db.emailMarks,1);assert.equal(f.db.otp.hash,'!consumed!');assert.doesNotMatch(await response.text(),/email-private-fixture/);
  }finally{await f.close();}
});

test('shared native factor management has guarded atomic writes and interoperable secrets',async()=>{
 for(const action of ['setup','confirm','disable']){
  const canonical=JSON.parse(readFileSync(path.join(root,'specifications/scenarios/auth-two-factor-management.json'),'utf8'));
  const view=JSON.parse(readFileSync(path.join(root,'specifications/scenarios/auth-factor-'+action+'.json'),'utf8'));
  assert.deepEqual(view.cases,canonical.cases.filter(c=>c.action===action));
 }
 const vectors=JSON.parse(readFileSync(path.join(root,'specifications/scenarios/auth-two-factor-management.json'),'utf8')),f=await fixture();const oldError=console.error;console.error=()=>{};globalThis.__registrationProfile={user_id:42,username:'tester',email:'fake@example.test'};
 const token=jwt.sign({userId:42,userName:'tester',sessionId:'fixture-session-42',jti:'fixture-access-jti-42',type:'access'},runtime.accessSecret,{expiresIn:900});const key=crypto.createHash('sha256').update(runtime.refreshSecret).digest();
 f.db.factorRecoveryHash=await bcrypt.hash('ABCDEFGHIJKLMNO',4);
 try{for(const c of vectors.cases){f.db.factorCase=c;f.db.factorPending=[];f.db.factorWrites=0;f.db.factorSequence=0;
  const iv=Buffer.alloc(12),cipher=crypto.createCipheriv('aes-256-gcm',key,iv),encrypted=Buffer.concat([cipher.update(c.fault==='base32'?'INVALID!':vectors.secret),cipher.final()]);f.db.factorSecret={SECRET_ENCRYPTED:encrypted.toString('base64'),SECRET_IV:iv.toString('base64'),SECRET_AUTH_TAG:c.fault==='cipher'?'bad':cipher.getAuthTag().toString('base64')};
  globalThis.__loginProfileError=c.fault==='profile'?Error('factor-private-fixture'):null;f.db.sessions.set('fixture-session-42',{user_id:42,session_id:'fixture-session-42',access_jti:'fixture-access-jti-42',access_token_expires_at:new Date(Date.now()+900000),revoked:c.auth==='revoked'});
  const body={...vectors.base,...c.patch};if(body.code==='@totp')body.code=f.db.totp();if(body.code==='@recovery')body.code=vectors.recoveryCode;
  const res=await f.request('/api/v2/users/me/two-factor'+(c.action==='disable'?'':'/'+c.action),c.action==='disable'?'DELETE':'POST',body,c.auth==='none'?{}:{authorization:'Bearer '+token});const text=await res.text(),out=JSON.parse(text);assert.equal(res.status,c.status,c.id);assert.equal(f.db.factorWrites,c.writes,c.id);assert.equal(f.db.factorPending.length,0,c.id);assert.equal(res.headers.getSetCookie().length,0);assert.doesNotMatch(text,/factor-private-fixture|test-password|\$2[aby]\$|secret_encrypted|secret_iv|secret_auth_tag/);
  if(c.message)assert.equal(c.status===200?out.message:out.data.message,c.message,c.id);if(c.status===200)assert.equal(res.headers.get('cache-control'),'private, no-store');if(c.status===200&&c.action==='setup'){assert.match(out.data.secret,/^[A-Z2-7]{32}$/);assert.equal(new URL(out.data.otpauth_url).searchParams.get('secret'),out.data.secret);}if(c.status===200&&c.action==='confirm'){assert.equal(out.data.enabled,true);assert.equal(out.data.recovery_codes.length,10);for(const code of out.data.recovery_codes)assert.match(code,/^[A-Z2-7]{5}-[A-Z2-7]{5}-[A-Z2-7]{5}$/);}
 }}finally{console.error=oldError;delete globalThis.__registrationProfile;delete globalThis.__loginProfileError;await f.close();}
});
test('shared account deletion is authenticated, atomic and never leaks credentials',async()=>{
 const vectors=JSON.parse(readFileSync(path.join(root,'specifications/scenarios/auth-account-deletion.json'),'utf8'));const f=await fixture();
 const token=jwt.sign({userId:42,userName:'tester',sessionId:'fixture-session-42',jti:'fixture-access-jti-42',type:'access'},runtime.accessSecret,{expiresIn:900});
 const oldError=console.error;console.error=()=>{};
 try{for(const c of vectors.cases){f.db.deletionCase=c;f.db.deletionPending=[];f.db.deletionWrites=0;
  globalThis.__registrationProfile={user_id:42,username:'tester'};
  globalThis.__loginProfileError=c.fault==='profile'?Error('deletion-private-fixture'):c.fault==='missing'?createError({statusCode:404,message:'用户不存在',data:{code:40401,message:'用户不存在',data:null,meta:null}}):null;
  f.db.sessions.set('fixture-session-42',{user_id:42,session_id:'fixture-session-42',access_jti:'fixture-access-jti-42',access_token_expires_at:new Date(Date.now()+900000),revoked:c.auth==='revoked'});
  const res=await f.request('/api/v2/users/me','DELETE',{...vectors.base,...c.patch},c.auth==='none'?{}:{authorization:'Bearer '+token});const text=await res.text();assert.equal(res.status,c.status,c.id);assert.equal(f.db.deletionWrites,c.writes,c.id);assert.equal(f.db.deletionPending.length,0,c.id);assert.equal(res.headers.getSetCookie().length,c.status===200?2:0,c.id);assert.doesNotMatch(text,/deletion-private-fixture|test-password|\$2[aby]\$/);
  const out=JSON.parse(text);if(c.message)assert.equal(c.status===200?out.message:out.data.message,c.message,c.id);if(c.status===200)assert.deepEqual(out.data,{deleted:true,user_id:42});
 }}finally{console.error=oldError;delete globalThis.__registrationProfile;delete globalThis.__loginProfileError;await f.close();}
});
test('new account input policy rejects invalid registration before OTP queries and writes',async()=>{
 const rules=JSON.parse(readFileSync(path.join(root,'specifications/scenarios/auth-account-input.json'),'utf8')),base=JSON.parse(readFileSync(path.join(root,'specifications/scenarios/auth-registration.json'),'utf8')),f=await fixture();globalThis.__registrationProfile=base.profile;
 try{for(const c of rules.cases){f.db.registrationState={account:c.field==='email'?c.normalized:base.base.email};f.db.registrationInserts=0;f.db.registrationInserted=null;
  const before=f.db.calls.length,response=await f.request('/api/v2/auth/registration','POST',{...base.base,[c.field]:c.raw});
  assert.equal(response.status,c.valid?200:400,c.id);assert.equal(f.db.registrationInserts,c.valid?1:0,c.id);
  if(c.valid)assert.equal(f.db.registrationInserted[c.field],c.normalized,c.id);
  else assert(!f.db.calls.slice(before).some(call=>String(call.sql??call).includes('n_auth_otp_events')),c.id);
 }}finally{await f.close();delete globalThis.__registrationProfile;}
});
test('invalid new email is refused by OTP and protected email mutation before side effects',async()=>{
 const rules=JSON.parse(readFileSync(path.join(root,'specifications/scenarios/auth-account-input.json'),'utf8')),f=await fixture();
 const token=jwt.sign({userId:42,userName:'selfuser',sessionId:'fixture-session-42',jti:'fixture-access-jti-42',type:'access'},runtime.accessSecret,{expiresIn:900});
 f.db.sessions.set('fixture-session-42',{user_id:42,session_id:'fixture-session-42',access_jti:'fixture-access-jti-42',access_token_expires_at:new Date(Date.now()+900000),revoked:false});
 let sends=0;globalThis.__otpTestMail=async()=>{sends++;};
 try{for(const c of rules.emailCases.filter(c=>!c.valid&&c.normalized)){for(const kind of ['register','change_email']){
  const response=await f.request('/api/v2/auth/otp','POST',{account:c.raw,type:kind});assert.equal(response.status,400,c.id+' '+kind);
  assert.equal((await response.json()).data.message,'邮箱格式错误');
 }
 const response=await f.request('/api/v2/users/me/email','PATCH',{new_email:c.raw,verification_id:'email_fixture',code:'123456'},{authorization:'Bearer '+token});assert.equal(response.status,400,c.id);assert.equal((await response.json()).data.message,'邮箱格式错误');
 }assert.equal(sends,0);
 const legacy=await f.request('/api/v2/auth/otp','POST',{account:'old-account',type:'password_reset'});
 assert.equal(legacy.status,200);assert.equal((await legacy.json()).data.account,'old-account');assert.equal(sends,1);
 }finally{delete globalThis.__otpTestMail;await f.close();}
});
test('new password policy does not reject a valid historical short login',async()=>{
 const f=await fixture();f.db.loginPasswordHash=await bcrypt.hash('x',4);
 try{const response=await f.request('/api/v2/auth/tokens','POST',{account:'test',password:' x '});assert.equal(response.status,200);assert.equal(f.db.sessions.size,1);assert(response.headers.getSetCookie().length>0);}finally{await f.close();}
});
test('new password policy applies before reset OTP consumption and hashes canonical input',async()=>{
 const rules=JSON.parse(readFileSync(path.join(root,'specifications/scenarios/auth-password-input.json'),'utf8')),f=await fixture(),otpHash=await bcrypt.hash('123456',4);
 try{for(const c of [...rules.cases,...rules.apiCases]){
  f.db.otp={account:'fake@example.test',type:'password_reset',verification_id:'otp_fixture',hash:otpHash};f.db.otpUpdates=0;f.db.resetPasswordWrites=0;f.db.pendingReset=null;
  const response=await f.request('/api/v2/auth/password-reset','POST',{email:'fake@example.test',verification_id:'otp_fixture',code:'123456',new_password:c.raw});
  assert.equal(response.status,c.validNewPassword?200:400,c.id);assert.equal(f.db.resetPasswordWrites,c.validNewPassword?1:0,c.id);assert.equal(f.db.otpUpdates,c.validNewPassword?1:0,c.id);
  if(c.validNewPassword)assert(await bcrypt.compare(c.normalized,f.db.resetPasswordHash),c.id);
 }}finally{await f.close();}
});
test('registration uses canonical confirmation and new-password policy before insert',async()=>{
 const rules=JSON.parse(readFileSync(path.join(root,'specifications/scenarios/auth-password-input.json'),'utf8')),base=JSON.parse(readFileSync(path.join(root,'specifications/scenarios/auth-registration.json'),'utf8')),f=await fixture();globalThis.__registrationProfile=base.profile;
 try{for(const c of [...rules.cases,...rules.apiCases]){f.db.registrationState={};f.db.registrationInserts=0;f.db.registrationInserted=null;
  const valid=c.validNewPassword&&c.matches,response=await f.request('/api/v2/auth/registration','POST',{...base.base,password:c.raw,confirm_password:c.confirm});
  assert.equal(response.status,valid?200:400,c.id);assert.equal(f.db.registrationInserts,valid?1:0,c.id);
  if(valid)assert(await bcrypt.compare(c.normalized,f.db.registrationInserted.password_hash),c.id);
 }}finally{await f.close();delete globalThis.__registrationProfile;}
});

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
      f.db.resetLostRace = !!vector.lost_race;
      f.db.resetRevoked = false;
      f.db.pendingReset = null;
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
        assert.equal(f.db.otp.expired, true, vector.id);
        assert.equal(f.db.otp.hash, '!consumed!', vector.id);
        assert.equal(f.db.resetRevoked, true, vector.id);
      } else if (vector.marks === 0) {
        assert.equal(f.db.pendingReset, null, vector.id);
      }
    }
    const replay = await f.request('/api/v2/auth/password-reset', 'POST', vectors.base);
    assert.equal(replay.status, 400, 'the committed OTP cannot be replayed');
    assert.equal(f.db.resetPasswordWrites, 1);
    assert.doesNotMatch(JSON.stringify(globalThis.__authCompatErrors), /reset-private-fixture|otp-internal-sensitive-fixture/);
  } finally { await f.close(); delete globalThis.__authCompatErrors; }
});

test('password reset commit failure does not report success and attempts rollback', async () => {
  const f = await fixture();
  f.db.otp = {account:'fake@example.test',type:'password_reset',verification_id:'otp_fixture',hash:await bcrypt.hash('123456',4),verified_at:'2026-01-02T03:04:05.000Z'};
  f.db.otpUpdates = 0; f.db.resetPasswordWrites = 0; f.db.resetCommitFail = true;
  try {
    const response = await f.request('/api/v2/auth/password-reset', 'POST', {email:'fake@example.test',verification_id:'otp_fixture',code:'123456',new_password:'synthetic'});
    assert.equal(response.status, 500);
    assert.equal(f.db.pendingReset, null);
    assert.equal(f.db.otpUpdates, 0);
    assert.equal(f.db.resetPasswordWrites, 0);
    assert.notEqual(f.db.otp.hash, '!consumed!');
    assert.doesNotMatch(await response.text(), /reset-private-fixture/);
  } finally { await f.close(); }
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
      if(vector.status===200){assert.deepEqual(JSON.parse(text).data.user,vectors.profile,vector.id);assert.ok(await bcrypt.compare(body.password.trim(),f.db.registrationInserted.password_hash));assert.equal(f.db.registrationInserted.user_id,123);const calls=f.db.calls.slice(startCalls);assert.match(calls[0].sql,/expires_at > CURRENT_TIMESTAMP AND expires_at > created_at AND verified_at IS NOT NULL/);assert.deepEqual(calls[0].binds,{account:'new@example.test',verification_id:'otp_fixture'});assert.match(calls[1].sql,/email = :email OR username = :username/);assert.match(calls.find(call => call.sql.startsWith('INSERT INTO n_users')).sql,/TO_DATE\(:birth_date, 'YYYY-MM-DD'\)/);if(vector.expected_phone!==undefined)assert.equal(f.db.registrationInserted.phone,vector.expected_phone,vector.id);if(vector.id==='REG-19'){assert.equal(f.db.registrationInserted.bio,'  retained  ');assert.equal(f.db.registrationInserted.location,'false');assert.equal(f.db.registrationInserted.phone,'123');}}
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
  assert.equal(vectors.cases.length, 18);
  const f = await fixture();
  const oldConsoleError = console.error; const consoleErrors = []; globalThis.__authCompatErrors = [];
  console.error = (...args) => consoleErrors.push(args.map(String).join(' '));
  try {
    for (const vector of vectors.cases) {
      f.db.otp = {...vectors.fixture, expired: !!vector.expired}; f.db.otpFault = vector.fault; f.db.otpUpdates = 0; f.db.otpAttempts = vector.fault === 'exhausted' ? 5 : 0; f.db.otpAttemptFault = vector.fault === 'unavailable';
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

test('OTP verification and direct password reset share a code comparison budget', async () => {
  const vectors = JSON.parse(readFileSync(path.join(root, 'specifications/scenarios/auth-otp-verification.json'), 'utf8'));
  const f = await fixture();
  try {
    f.db.otp = {...vectors.fixture, type: 'password_reset'};
    f.db.otpUpdates = 0;
    f.db.otpAttempts = 0;
    const body = {...vectors.cases[0].body, type: 'password_reset'};
    const verify = code => f.request('/api/v2/auth/otp/verification', 'POST', {...body, code});
    for (let i = 0; i < 5; i++) assert.equal((await verify('wrong')).status, 401);
    const reset = () => f.request('/api/v2/auth/password-reset', 'POST', {
      email: body.account, verification_id: body.verification_id, code: body.code, new_password: 'synthetic'
    });
    assert.equal((await reset()).status, 429);
    assert.equal((await verify(body.code)).status, 429);
    f.db.otpAttemptFault = true;
    assert.equal((await reset()).status, 503);
    assert.equal(f.db.otpUpdates, 0);
  } finally { await f.close(); }
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

test('disabled accounts cannot use a live access session or refresh it', async () => {
  const f = await fixture();
  try {
    const tokens = (await (await f.login()).json()).data.tokens;
    const session = f.db.sessions.get(tokens.session_id);
    const storedHash = session.refresh_token_hash;
    f.db.disableAccountAfterRefreshRead = true;
    for (let attempt = 0; attempt < 2; attempt++) {
      const response = await f.request('/api/v2/auth/tokens/current','PATCH',{refresh_token:tokens.refresh_token});
      assert.equal(response.status,401);
      assert.deepEqual(response.headers.getSetCookie(),[]);
      assert.equal(session.refresh_token_hash,storedHash);
    }
    assert.equal(session.revoked,false);
    assert.equal((await f.request('/api/v2/private','GET',undefined,{authorization:`Bearer ${tokens.access_token}`})).status,401);
  } finally { await f.close(); }
});

test('refresh credential body matches the common request rules', async () => {
  const fixtureUrl = new URL('../specifications/scenarios/auth-refresh.json', import.meta.url);
  const {requestBodyCases} = JSON.parse(readFileSync(fixtureUrl,'utf8'));
  const f = await fixture();
  try {
    for (const item of requestBodyCases) {
      const {data:{tokens}} = await (await f.login()).json();
      const template = item.body.replaceAll('TOKEN',tokens.refresh_token);
      const text = item.bytes ? template.padEnd(item.bytes,' ') : template;
      const headers = {'content-type':item.contentType};
      if (item.cookie) headers.cookie = 'refresh_token=' + item.cookie.replaceAll('TOKEN',tokens.refresh_token);
      const chunked = item.id === 'json-over-limit';
      const stream = chunked ? new ReadableStream({
        start(controller) {
          const bytes = Buffer.from(text);
          controller.enqueue(bytes.subarray(0, 512 * 1024));
          controller.enqueue(bytes.subarray(512 * 1024));
          controller.close();
        },
      }) : null;
      const response = await f.requestRaw('/api/v2/auth/tokens/current','PATCH',stream ?? text,headers,
        chunked ? {duplex:'half'} : {});
      assert.equal(response.status,item.accepted ? 200 : 401,item.id);
      assert.equal(response.headers.getSetCookie().length,item.accepted ? 2 : 0,item.id);
    }
  } finally { await f.close(); }
});

test('refresh requires the refresh type and accepts legacy refresh credentials without jti', async () => {
  const f = await fixture();
  try {
    const tokens = (await (await f.login()).json()).data.tokens;
    const session = f.db.sessions.get(tokens.session_id);
    const claims = {userId:session.user_id,userName:'fixture',sessionId:tokens.session_id};
    for (const [type,status] of [['access',401],['refresh',200]]) {
      const token = jwt.sign({...claims,type},runtime.refreshSecret,{expiresIn:900});
      const storedHash = crypto.createHash('sha256').update(token).digest('hex');
      session.refresh_token_hash = storedHash;
      const response = await f.request('/api/v2/auth/tokens/current','PATCH',{refresh_token:token});
      assert.equal(response.status,status);
      if (status === 401) {
        assert.deepEqual(response.headers.getSetCookie(),[]);
        assert.equal(session.refresh_token_hash,storedHash);
      } else {
        assertTokens(response,(await response.json()).data);
        assert.notEqual(session.refresh_token_hash,storedHash);
      }
    }
  } finally { await f.close(); }
});

test('expired moderation ban allows a new login while keeping old sessions revoked', async () => {
  const f = await fixture();
  try {
    const old = (await (await f.login()).json()).data.tokens;
    for (const session of f.db.sessions.values()) session.revoked = true;
    f.db.banExpiry = {eligible: false, status: 'suspended'};
    const beforeExpiry = await f.login();
    assert.equal(beforeExpiry.status, 403);
    assert.deepEqual(beforeExpiry.headers.getSetCookie(), []);
    f.db.banExpiry.eligible = true;
    const wrongPassword = await f.request('/api/v2/auth/tokens', 'POST', {account: 'test', password: 'wrong'});
    assert.equal(wrongPassword.status, 401);
    assert.deepEqual(wrongPassword.headers.getSetCookie(), []);
    assert.equal(f.db.banExpiry.expired, true);
    const recovered = await f.login();
    assert.equal(recovered.status, 200);
    assertTokens(recovered, (await recovered.json()).data.tokens);
    assert.equal((await f.request('/api/v2/private', 'GET', undefined, {authorization: `Bearer ${old.access_token}`})).status, 401);
    assert.equal((await f.request('/api/v2/auth/tokens/current', 'PATCH', {refresh_token: old.refresh_token})).status, 401);
  } finally { await f.close(); }
});

test('login cannot issue cookies when password changed after bcrypt', async () => {
  const f = await fixture();
  try {
    f.db.passwordChangedBeforeIssue = true;
    const response = await f.login();
    assert.equal(response.status, 401);
    assert.deepEqual(response.headers.getSetCookie(), []);
    assert.equal(f.db.sessions.size, 0);
  } finally { await f.close(); }
});

test('login cannot issue a new factor challenge when password changed after bcrypt', async () => {
  const f = await fixture({twoFactor: true});
  try {
    f.db.passwordChangedBeforeIssue = true;
    const response = await f.login();
    assert.equal(response.status, 401);
    assert.deepEqual(response.headers.getSetCookie(), []);
    assert.equal(f.db.calls.filter(call => call.sql.startsWith('INSERT INTO n_auth_two_factor_challenges')).length, 0);
  } finally { await f.close(); }
});

test('password reset invalidates a previously issued two-factor challenge', async () => {
  const f = await fixture({twoFactor: true});
  try {
    const issued = await f.login();
    assert.equal(issued.status, 200);
    const challenge = (await issued.json()).data.challenge_id;
    assert.ok(challenge);
    f.db.trustedDevices.set('old-device', {id: 1, user_id: 1, revoked: false});
    f.db.trustedDevices.set('other-user-device', {user_id: 2, revoked: false});
    const vectors = JSON.parse(readFileSync(path.join(root, 'specifications/scenarios/auth-password-reset.json'), 'utf8'));
    f.db.otp = {account: vectors.base.email, type: 'password_reset',
      verification_id: vectors.base.verification_id, hash: await bcrypt.hash(vectors.base.code, 4)};
    f.db.otpUpdates = 0;
    f.db.resetPasswordWrites = 0;
    const reset = await f.request('/api/v2/auth/password-reset', 'POST', vectors.base);
    assert.equal(reset.status, 200);
    assert.equal(f.db.trustedDevices.get('old-device').revoked, true);
    assert.equal(f.db.trustedDevices.get('other-user-device').revoked, false);
    const completed = await f.request('/api/v2/auth/two-factor/challenges', 'POST', {
      challenge_id: challenge, code: f.db.totp()
    });
    assert.equal(completed.status, 401);
    assert.deepEqual(completed.headers.getSetCookie(), []);
    const login = await f.request('/api/v2/auth/tokens', 'POST', {
      account: 'test', password: vectors.base.new_password
    }, {'x-device-fingerprint': 'old-device'});
    assert.equal(login.status, 200);
    assert.equal((await login.json()).data.two_factor_required, true);
    assert.equal(f.db.sessions.size, 0);
  } finally { await f.close(); }
});

test('reset before the factor login transaction rejects the in-flight completion', async () => {
  const f = await fixture({twoFactor: true});
  try {
    const issued = await f.request('/api/v2/auth/tokens', 'POST', {
      account: 'test', password: 'test-password', remember_me: true
    }, {'x-device-fingerprint': 'pending-device'});
    assert.equal(issued.status, 200);
    const challenge = (await issued.json()).data.challenge_id;
    assert.ok(challenge);
    const email = 'fake@example.test', verificationId = 'otp_fixture', code = '123456';
    f.db.otp = {account: email, type: 'password_reset', verification_id: verificationId,
      hash: await bcrypt.hash(code, 4)};
    f.db.otpUpdates = 0;
    f.db.resetPasswordWrites = 0;
    f.db.beforeTrust = async () => {
      const reset = await f.request('/api/v2/auth/password-reset', 'POST', {
        email, verification_id: verificationId, code, new_password: 'new-test-password'
      });
      assert.equal(reset.status, 200);
    };
    const completed = await f.request('/api/v2/auth/two-factor/challenges', 'POST', {
      challenge_id: challenge, code: f.db.totp()
    }, {'x-device-fingerprint': 'pending-device'});
    assert.equal(completed.status, 401);
    assert.deepEqual(completed.headers.getSetCookie(), []);
    assert.equal(f.db.sessions.size, 0);
    assert.equal(f.db.trustedDevices.size, 0);
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
    const device = {'x-device-fingerprint': 'fixture-device'};
    const login = await f.request('/api/v2/auth/tokens', 'POST', {
      account:'test', password:'test-password',
    }, device);
    const challenge = (await login.json()).data;
    assert.equal(challenge.two_factor_required, true); assert.equal(challenge.tokens, undefined); assert.deepEqual(login.headers.getSetCookie(), []);
    const body = {challenge_id: challenge.challenge_id, code: f.db.totp()};
    const wrongDevice = await f.request('/api/v2/auth/two-factor/challenges', 'POST', body, {'x-device-fingerprint': 'other-device'});
    assert.equal(wrongDevice.status, 401);
    assert.deepEqual(wrongDevice.headers.getSetCookie(), []);
    const failure = (await wrongDevice.json()).data;
    assert.equal(failure.code, 40101);
    assert.equal(failure.message, '双因素验证已过期，请重新登录');
    assert.equal((await f.request('/api/v2/auth/two-factor/challenges', 'POST', {...body, code: 'invalid'}, device)).status, 401);
    assert.equal(f.db.sessions.size, 0);
    const completed = await f.request('/api/v2/auth/two-factor/challenges', 'POST', body, device);
    assert.equal(completed.status, 200); assertTokens(completed, (await completed.json()).data.tokens);
    assert.equal((await f.request('/api/v2/auth/two-factor/challenges', 'POST', body, device)).status, 401);
  } finally {await f.close();}
});

test('remembered devices require the server proof and store only its digest', async () => {
  const f = await fixture({twoFactor: true});
  const requestLogin = (headers) => f.request('/api/v2/auth/tokens', 'POST', {
    account:'test', password:'test-password', remember_me:true,
  }, headers);
  try {
    const headers = {'x-device-fingerprint':'fixture-device'};
    f.db.trustedDevices.set('fixture-device', {id:90,user_id:1,revoked:false});
    const challenge = (await (await requestLogin(headers)).json()).data;
    assert.equal(challenge.two_factor_required,true);
    const finished = await f.request('/api/v2/auth/two-factor/challenges', 'POST', {
      challenge_id:challenge.challenge_id, code:f.db.totp(),
    }, headers);
    assert.equal(finished.status,200);
    const cookie = finished.headers.getSetCookie().find(value => value.startsWith('nekotribe_trusted_device='));
    assert.match(cookie,/^nekotribe_trusted_device=td1_[0-9a-f]{64};/);
    assert.match(cookie,/HttpOnly/i);
    assert.match(cookie,/SameSite=Lax/i);
    const cookiePair = cookie.split(';')[0];
    const proof = cookiePair.split('=')[1];
    const key = 'td1_' + crypto.createHash('sha256').update(proof).digest('hex');
    assert.ok(f.db.trustedDevices.has(key));
    assert.equal(f.db.trustedDevices.has(proof),false);
    assert.doesNotMatch(await finished.text(),new RegExp(proof));
    const login = await requestLogin({...headers,cookie:cookiePair});
    assert.equal((await login.json()).data.two_factor_required,false);
    f.db.trustedDevices.get(key).revoked = true;
    const revoked = await requestLogin({...headers,cookie:cookiePair});
    assert.deepEqual(revoked.headers.getSetCookie(), []);
    assert.equal((await revoked.json()).data.two_factor_required,true);
    assert.equal(f.db.sessions.size, 2);
  } finally { await f.close(); }
});

test('session insert failure rolls back the challenge, recovery code and device enrollment', async () => {
  const f = await fixture({twoFactor:true});
  try {
    const headers = {'x-device-fingerprint':'fixture-device'};
    const login = await f.request('/api/v2/auth/tokens','POST',{
      account:'test', password:'test-password', remember_me:true,
    },headers);
    const id = (await login.json()).data.challenge_id;
    f.db.factorLoginUndo = [];
    f.db.failFactorSession = true;
    const complete = () => f.request('/api/v2/auth/two-factor/challenges','POST',{
      challenge_id:id,code:'ABCDE-FGHIJ-KLMNO',
    },headers);
    const failed = await complete();
    assert.equal(failed.status,500);
    assert.deepEqual(failed.headers.getSetCookie(),[]);
    assert.equal(f.db.sessions.size,0);
    assert.equal(f.db.trustedDevices.size,0);
    assert.ok(!f.db.challenges.get(id).consumed);
    f.db.failFactorSession = false;
    assert.equal((await complete()).status,200);
    assert.equal(f.db.sessions.size,1);
    assert.equal(f.db.trustedDevices.size,1);
  } finally { await f.close(); }
});

test('a changed factor rejects a code verified with the previous secret', async () => {
  const f = await fixture({twoFactor:true});
  try {
    const issued = await f.login();
    const id = (await issued.json()).data.challenge_id;
    f.db.factorChangedDuringLogin = true;
    const completed = await f.request('/api/v2/auth/two-factor/challenges','POST',{
      challenge_id:id,code:f.db.totp(),
    });
    assert.equal(completed.status,401);
    assert.equal((await completed.json()).data.message,'双因素验证已过期，请重新登录');
    assert.deepEqual(completed.headers.getSetCookie(),[]);
    assert.ok(!f.db.challenges.get(id).consumed);
    assert.equal(f.db.sessions.size,0);
  } finally { await f.close(); }
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
