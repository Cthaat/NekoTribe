import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const stubs = {
  '~/server/database/readiness': 'export const requireFeatureSchema = () => {};',
  '~/server/models/v2': 'export const v2GetPostMedia = null, v2MapPublicUser = null, v2RequirePublicUser = null;',
  './moderation-user-queue': 'export const readModerationUsers = null;',
  h3: 'export const setResponseHeader = null;',
  '~/server/utils/v2': `
    export const v2Auth = event => event.auth;
    export const v2One = connection => connection.read();
    export const v2String = value => value ?? '';
    export const v2Forbidden = message => { throw Object.assign(new Error(message), {statusCode:403}); };
    export const v2Body = null, v2DateString = null, v2Number = null, v2Ok = null,
      v2Page = null, v2PageMeta = null, v2QueryString = null, v2Rows = null, v2StringOrNull = null;
  `,
};
const compiled = await build({
  stdin: { contents: `export {requireModerationAccess} from './server/services/v2/moderation';`,
    resolveDir: fileURLToPath(new URL('../', import.meta.url)), loader: 'ts' },
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{ name: 'moderation-boundaries', setup(builder) {
    builder.onResolve({ filter: /.*/ }, args => {
      if (Object.hasOwn(stubs, args.path)) return { path: args.path, namespace: 'stub' };
    });
    builder.onLoad({ filter: /.*/, namespace: 'stub' }, args => ({ contents: stubs[args.path], loader: 'js' }));
  }}],
});
const { requireModerationAccess } = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);

test('moderation requires an explicitly configured active account', async t => {
  const keys = ['MODERATION_ADMIN_ACCOUNTS', 'MODERATION_ALLOW_ALL'];
  const previous = keys.map(key => process.env[key]);
  t.after(() => keys.forEach((key, index) => {
    if (previous[index] === undefined) delete process.env[key];
    else process.env[key] = previous[index];
  }));
  delete process.env.MODERATION_ALLOW_ALL;
  delete process.env.MODERATION_ADMIN_ACCOUNTS;
  const request = {auth: {userId: 42}};
  const noQuery = {read: () => assert.fail('An empty allowlist must reject before a profile lookup')};
  await assert.rejects(() => requireModerationAccess(request, noQuery), {statusCode:403});
  process.env.MODERATION_ADMIN_ACCOUNTS = ' , ';
  await assert.rejects(() => requireModerationAccess(request, noQuery), {statusCode:403});
  process.env.MODERATION_ADMIN_ACCOUNTS = ' Review-Owner ';
  assert.deepEqual(await requireModerationAccess(request, {read: () => ({USERNAME:'REVIEW-OWNER'})}), request.auth);
  await assert.rejects(() => requireModerationAccess(request, {read: () => undefined}), {statusCode:403});
});
