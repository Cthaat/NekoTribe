import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const compiled = await build({
  entryPoints: ['app/api/v2/groups.ts'],
  absWorkingDir: fileURLToPath(new URL('../', import.meta.url)),
  bundle: true,
  write: false,
  platform: 'node',
  format: 'esm',
  plugins: [{
    name: 'group-detail-transport',
    setup(builder) {
      builder.onResolve({ filter: /^\.\/client$/ }, () => ({ path: 'client', namespace: 'fixture' }));
      builder.onLoad({ filter: /.*/, namespace: 'fixture' }, () => ({ contents: `
        export const toV2PagedResult = response => response;
        export const v2Request = async () => ({});
        export const v2RequestData = (path, options) => globalThis.groupDetailTransport(path, options);
      ` }));
    }
  }]
});
const api = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);

test('group lookups encode the slug and confirm the requested identity', async () => {
  let result = { group_id: 42, slug: 'cat town%' };
  let called;
  globalThis.groupDetailTransport = (path, { method }) => { called = [path, method]; return result; };
  assert.deepEqual(await api.v2GetGroupBySlug('cat town%'), result);
  assert.deepEqual(called, ['/api/v2/groups/by-slug/cat%20town%25', 'GET']);
  assert.deepEqual(await api.v2GetGroupById(42), result);
  assert.deepEqual(called, ['/api/v2/groups/42', 'GET']);

  await assert.rejects(api.v2GetGroupBySlug('other'), /Invalid group detail response/);
  await assert.rejects(api.v2GetGroupById(7), /Invalid group detail response/);
  result = { ...result, group_id: 0 };
  await assert.rejects(api.v2GetGroupBySlug('cat town%'), /Invalid group detail response/);
});
