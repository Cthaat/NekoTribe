import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const root = fileURLToPath(new URL('../', import.meta.url));
const code = await build({
  stdin: { contents: 'export {v2ListSessions, v2RevokeOtherSessions} from "@/services/account";', loader: 'ts', resolveDir: root },
  bundle: true, write: false, platform: 'node', format: 'esm', alias: { '@': root + 'app' },
  plugins: [{ name: 'fixture-api', setup(plugin) {
    plugin.onResolve({ filter: /^#app$/ }, args => ({ path: args.path, namespace: 'nuxt-fixture' }));
    plugin.onLoad({ filter: /.*/, namespace: 'nuxt-fixture' }, () => ({ contents: 'export const useNuxtApp=()=>({});' }));
    plugin.onResolve({ filter: /^@\/composables\/useApi$/ }, args => ({ path: args.path, namespace: 'fixture' }));
    plugin.onLoad({ filter: /.*/, namespace: 'fixture' }, () => ({ contents: 'export const apiFetch=(...args)=>globalThis.__sessionFixture(...args);' }));
  } }]
});
const { v2ListSessions, v2RevokeOtherSessions } = await import(`data:text/javascript;base64,${Buffer.from(code.outputFiles[0].text).toString('base64')}`);

test('session management uses the shared array, metadata, and dedicated bulk route', async () => {
  const calls = [];
  globalThis.__sessionFixture = async (path, options) => {
    calls.push({ path, method: options.method, query: options.query });
    if (options.method === 'DELETE') return { data: { revoked_count: 2 } };
    return { data: [{ session_id: 'secondary', is_current: false, device_info: 'Fixture' }],
      meta: {page: 2, page_size: 20, total: 42, has_next: true} };
  };
  const result = await v2ListSessions(2);
  assert.equal(result.items[0].id, 'secondary');
  assert.equal(result.items[0].current, false);
  assert.equal(result.page, 2);
  assert.equal(result.total, 42);
  assert.equal(result.hasNext, true);
  assert.deepEqual(await v2RevokeOtherSessions(), { revokedCount: 2 });
  assert.deepEqual(calls, [{ path: '/api/v2/auth/sessions', method: 'GET', query: {page: 2, page_size: 20} },
    { path: '/api/v2/auth/sessions/others', method: 'DELETE', query: undefined }]);
});
