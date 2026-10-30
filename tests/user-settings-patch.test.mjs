import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { ServerResponse } from 'node:http';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import { build } from 'esbuild';
import { createEvent } from 'h3';

const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(import.meta.url);
const vectors = JSON.parse(readFileSync(new URL('../specifications/scenarios/user-settings-patch.json', import.meta.url), 'utf8'));
const stubs = {
  '~/server/database/readiness': 'export const requireFeatureSchema=async()=>{};',
  '~/server/storage': 'export const deleteStorageReference=()=>{},ensureStorageTempDir=()=>{},STORAGE_AVATAR_MAX_SIZE=0,storeAvatarFile=()=>{};',
  '~/server/models/v2': 'export const v2MapPublicUser=()=>{},v2RequirePublicUser=()=>{},v2RequireSelfUser=()=>{};',
  './auth': 'export const v2ClearAuthCookies=()=>{},v2VerifyOtpCode=()=>{},v2VerifyUserPassword=()=>{};',
  './notifications': 'export const v2CreateNotification=()=>{};',
  './presence': 'export const v2PublishUserPresence=async c=>{c.presence++};',
  './api-cache': 'export const invalidateApiResponseCache=()=>{},readApiResponseCache=()=>{},shouldInvalidateApiResponseCache=()=>{},writeApiResponseCache=()=>{};',
  './logging': 'export const getRequestLogContext=()=>{},logError=()=>{},logInfo=()=>{},serializeLogError=()=>{};',
  './client-ip': 'export const getClientIp=()=>"";',
  'oracledb': 'export default {OUT_FORMAT_OBJECT:4002};',
  'bcrypt': 'export default {};',
  'formidable': 'export default {};'
};
const compiled = await build({
  stdin: { contents: `export {v2PatchSettings} from './server/services/v2/users';`, resolveDir: root, loader: 'ts' },
  bundle: true, write: false, platform: 'node', format: 'esm', plugins: [{ name: 'settings-test', setup(builder) {
    builder.onResolve({ filter: /.*/ }, args => {
      if (Object.hasOwn(stubs, args.path)) return { path: args.path, namespace: 'stub' };
      if (args.path.startsWith('~/')) return { path: path.join(root, `${args.path.slice(2)}.ts`) };
      if (args.path.startsWith('node:')) return { path: args.path, external: true };
      if (!args.path.startsWith('.') && !path.isAbsolute(args.path)) return { path: pathToFileURL(require.resolve(args.path)).href, external: true };
    });
    builder.onLoad({ filter: /.*/, namespace: 'stub' }, args => ({ contents: stubs[args.path], loader: 'js' }));
  }}]
});
const { v2PatchSettings } = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);

for (const vector of vectors.cases) test(`Nuxt settings ${vector.id}`, async () => {
  const request = { method: 'PATCH', url: '/api/v2/users/me/settings', headers: { 'content-type': 'application/json' }, body: JSON.stringify(vector.body) };
  const response = new ServerResponse(request);
  const event = createEvent(request, response);
  event.context.auth = { userId: 42 };
  const db = { presence: 0, update: null, calls: [], async execute(sql, binds, options) {
    this.calls.push({ sql, binds, options });
    if (sql.includes('FOR UPDATE')) return { rows: [{ USER_ID: 42 }] };
    if (sql.includes('UPDATE n_user_settings')) this.update = Object.fromEntries(Object.entries(binds).filter(([key]) => key !== 'user_id'));
    if (sql.includes('SELECT * FROM n_user_settings')) return { rows: [{ USER_ID: 42 }] };
    return { rowsAffected: 1 };
  }};
  try {
    if (vector.error) await assert.rejects(() => v2PatchSettings(event, db), error => error.statusCode === 400 && error.message === vector.error);
    else {
      await v2PatchSettings(event, db);
      assert.deepEqual(db.update ?? {}, vector.fields);
      assert.equal(db.presence, Number(vector.presence));
    }
    for (let index = 0; index < db.calls.length; index++) {
      if (!db.calls[index].sql.includes('MERGE INTO n_user_settings')) continue;
      assert.match(db.calls[index - 1].sql, /n_users.*FOR UPDATE/s);
      assert.equal(db.calls[index - 1].binds.user_id, 42);
      assert.equal(db.calls[index].options.autoCommit, true);
    }
  } finally { response.destroy(); }
});

test('Nuxt settings do not create a row for a missing user', async () => {
  const request = { method: 'PATCH', url: '/api/v2/users/me/settings', headers: { 'content-type': 'application/json' }, body: '{}' };
  const response = new ServerResponse(request);
  const event = createEvent(request, response);
  event.context.auth = { userId: 42 };
  const calls = [];
  const db = { async execute(sql) { calls.push(sql); return { rows: [] }; } };
  try {
    await assert.rejects(() => v2PatchSettings(event, db), error => error.statusCode === 404);
    assert.equal(calls.length, 1);
    assert.match(calls[0], /FOR UPDATE/);
  } finally { response.destroy(); }
});
