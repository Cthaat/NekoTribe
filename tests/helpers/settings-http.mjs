// Exercise real H3/auth/routes/cache/error wrappers; only persistence is isolated.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';
import { createApp, createRouter, createError, defineEventHandler, toNodeListener } from 'h3';
import jwt from 'jsonwebtoken';
import { listenForFetch } from './loopback-listener.mjs';

const root = fileURLToPath(new URL('../../', import.meta.url));
const require = createRequire(import.meta.url);
export const vectors = JSON.parse(readFileSync(new URL('../../specifications/scenarios/user-settings-native.json', import.meta.url)));
const key = 'isolated-user-settings-http-key';
export const marker = 'synthetic-settings-driver-secret';
const stubs = {
  '#imports': 'export const useRuntimeConfig=()=>({accessSecret:' + JSON.stringify(key) + '});',
  oracledb: 'export default {OUT_FORMAT_OBJECT:4002};',
  bcrypt: 'export default {};',
  formidable: 'export default {};',
  '~/server/database/readiness': 'export const requireFeatureSchema=async c=>c.schema();',
  '~/server/storage': 'export const deleteStorageReference=()=>{},ensureStorageTempDir=()=>{},STORAGE_AVATAR_MAX_SIZE=0,storeAvatarFile=()=>{};',
  '~/server/models/v2': 'export const v2MapPublicUser=()=>{},v2RequirePublicUser=()=>{},v2RequireSelfUser=()=>{};',
  './auth': 'export const v2ClearAuthCookies=()=>{},v2VerifyUserPassword=()=>{};',
  './notifications': 'export const v2CreateNotification=()=>{};',
  '~/server/utils/redis': 'export const REDIS_CHANNELS={PRESENCE:"ws:presence"};export const publishMessage=async(channel,message)=>globalThis.__settingsPresence.redis(channel,message);',
  '~/server/utils/wsSession': 'export const WS_SERVER_ID="test-instance";export const sessionManager={isUserOnline:()=>false};export const sendWsToAll=message=>globalThis.__settingsPresence.local(message);',
  './logging': 'export const getRequestLogContext=()=>null, logInfo=()=>{},logWarn=()=>{},logError=()=>{},serializeLogError=()=>({});',
  './cache-mode': 'export const cacheProcessEpoch="isolated-settings",singleBackendCacheEnabled=true;'
};
const built = await build({
  stdin: { contents: "export {default as auth} from './server/middleware/auth';export {default as get} from './server/api/v2/users/me/settings.get';export {default as patch} from './server/api/v2/users/me/settings.patch';export * from './server/services/v2/presence';", resolveDir: root, loader: 'ts' },
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{ name: 'isolated-settings', setup(builder) {
    builder.onResolve({ filter: /.*/ }, args => {
      if (Object.hasOwn(stubs, args.path)) return { path: args.path, namespace: 'isolated' };
      if (args.path.startsWith('~/')) return { path: path.join(root, args.path.slice(2) + '.ts') };
      if (args.path.startsWith('node:')) return { path: args.path, external: true };
      if (!args.path.startsWith('.') && !path.isAbsolute(args.path)) return { path: pathToFileURL(require.resolve(args.path)).href, external: true };
    });
    builder.onLoad({ filter: /.*/, namespace: 'isolated' }, args => ({ contents: stubs[args.path], resolveDir: root, loader: 'js' }));
  } }]
});
export const routes = await import('data:text/javascript;base64,' + Buffer.from(built.outputFiles[0].text).toString('base64'));
const token = jwt.sign({ userId: 42, userName: 'fixture', type: 'access', sessionId: 'settings-session', jti: 'settings-jti' }, key, { expiresIn: 300 });

export async function request({ method = 'GET', mode = 'ok', credential = 'valid', mapping, body = {}, pathname = '/api/v2/users/me/settings' } = {}) {
  const state = { opens: 0, closes: 0, commits: 0, rollbacks: 0, cacheCalls: 0, calls: [], presence: 0, publishes: [], localMessages: [], errors: [] };
  globalThis.__settingsPresence = {
    local(message) { state.localMessages.push(message); if (mode === 'local-error') throw Error(marker); },
    redis(channel,message) { if(mode === 'publisher-absent') return; state.publishes.push({channel,message}); if(mode === 'publish-error') throw Error(marker); }
  };
  const app = createApp({ onError(error) { state.errors.push(error); } });
  app.use(defineEventHandler(event => {
    if (method === 'GET') event.context.redis = new Proxy({}, { get() { state.cacheCalls++; throw Error(marker); } });
    event.context.getOracleConnection = async () => {
      const index = ++state.opens;
      if (mode === 'open' && index === 2) throw Error(marker);
      return {
        async schema() {
          if (mode === 'schema') throw createError({ statusCode: 503, statusMessage: 'Service temporarily unavailable', data: { code: 50301, message: '服务暂不可用，请稍后重试。', data: null, meta: null } });
        },
        async execute(sql, binds, options) {
          if (index === 1) {
            assert.match(sql, /UPDATE n_auth_sessions/);
            if (mode === 'auth-error') throw Error(marker);
            return { rowsAffected: mode === 'revoked' ? 0 : 1 };
          }
          state.calls.push({ sql, binds, options });
          assert.equal(binds.user_id, 42);
          if (sql.includes('MAX(s.last_accessed_at)')) {
            state.presence++;
            assert.equal(state.commits, 1, 'presence must follow commit');
            assert.equal(binds.online_window_seconds, 90);
            if(mode === 'lookup-error') throw Error(marker);
            return {rows:[{SHOW_ONLINE_STATUS:mode === 'hidden' ? 0 : 1,ONLINE_STATUS:mode === 'hidden' ? 'hidden' : 'online',LAST_SEEN_AT:new Date('2026-01-01T00:00:00.000Z')}]};
          }
          if (mode === 'store-error' || mode === 'error' || (mode === 'rollback' && sql.includes('SELECT *')) || (mode === 'lock' && sql.includes('FOR UPDATE')) ||
              (mode === 'merge' && sql.includes('MERGE')) || (mode === 'read' && sql.includes('SELECT *')) ||
              (mode === 'update' && sql.includes('UPDATE n_user_settings'))) throw Error(marker);
          if (sql.includes('FOR UPDATE')) return { rows: mode === 'missing-user' ? [] : [{ USER_ID: mode === 'wrong-lock' ? 99 : 42 }] };
          if (sql.includes('SELECT *')) return { rows: mode === 'missing-settings' ? [] : [{
            USER_ID: mode === 'wrong-row' ? 99 : 42,
            TWO_FACTOR_ENABLED: mapping?.flag ?? 0, LOGIN_ALERTS: mapping?.flag ?? 0,
            PROFILE_VISIBILITY: 'public', SHOW_ONLINE_STATUS: 0, ALLOW_DM_FROM_STRANGERS: 0,
            PUSH_NOTIFICATION_ENABLED: 0, EMAIL_NOTIFICATION_ENABLED: 0, AI_SENTIMENT_ENABLED: 0,
            AI_SENTIMENT_MODEL_ID: null, AI_SENTIMENT_RETURN_PROBABILITIES: mapping ? mapping.flag : null,
            AI_SENTIMENT_INCLUDE_METADATA: 0, AI_SENTIMENT_TOP_K: mapping ? mapping.top : 3, UPDATED_AT: null
          }] };
          return { rowsAffected: 1 };
        },
        async commit() { state.commits++; if (mode === 'commit') throw Error(marker); },
        async rollback() { state.rollbacks++; if (mode === 'rollback') throw Error(marker); },
        async close() { state.closes++; if (mode === 'close' && index === 2) throw Error(marker); }
      };
    };
  }));
  app.use(routes.auth);
  const router = createRouter();
  router.get('/api/v2/users/me/settings', routes.get);
  router.patch('/api/v2/users/me/settings', routes.patch);
  app.use(router);
  const server = createServer(toNodeListener(app));
  const origin = await listenForFetch(server);
  try {
    const headers = { 'content-type': 'application/json' };
    if (credential !== 'absent') headers.Authorization = 'Bearer ' + (credential === 'invalid' ? 'invalid-token' : token);
    const response = await fetch(origin + pathname, { method, headers, ...(method === 'PATCH' ? { body: JSON.stringify(body) } : {}) });
    return { state, status: response.status, headers: response.headers, body: await response.json() };
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
}
