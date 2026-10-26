// Compile the real HTTP readiness adapter, but invoke it directly with Oracle
// dictionary fixtures. No HTTP listener, app, driver connection or service runs.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';
import { schemaFixture } from './helpers/schema-fixture.mjs';

const require = createRequire(import.meta.url);
const compiled = await build({
  entryPoints: [fileURLToPath(new URL('../server/database/readiness.ts', import.meta.url))],
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{ name: 'readiness-test-boundaries', setup(builder) {
    builder.onResolve({ filter: /.*/ }, args => {
      if (args.path === 'oracledb' || args.path === '~/server/utils/logging') return { path: args.path, namespace: 'readiness-stub' };
      if (args.path.startsWith('node:')) return { path: args.path, external: true };
      if (!args.path.startsWith('.') && !args.path.match(/^(?:[A-Za-z]:|\/)/)) return { path: pathToFileURL(require.resolve(args.path)).href, external: true };
    });
    builder.onLoad({ filter: /.*/, namespace: 'readiness-stub' }, args => ({ contents: args.path === 'oracledb'
      ? 'export default {OUT_FORMAT_OBJECT:4002};'
      : 'export const logError = () => {};', loader: 'js' }));
  } }]
});
const { requireFeatureSchema } = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);
function connection(fixture = schemaFixture({ baseline: true })) {
  const calls = [];
  return {
    fixture, calls,
    async execute(sql, binds, options) {
      calls.push(sql);
      assert.match(sql, /^SELECT\b/);
      assert.equal(options.outFormat, 4002);
      const rows = fixture.query(sql, binds);
      assert(Array.isArray(rows), sql);
      await Promise.resolve();
      return { rows };
    }
  };
}
const ownerChecks = db => db.calls.filter(sql => sql.startsWith('SELECT USER AS')).length;
test('real readonly adapter shares one complete inspection across 20 concurrent same-connection checks', async () => {
  const db = connection();
  await Promise.all(Array.from({ length: 20 }, () => requireFeatureSchema(db, 'media')));
  assert.equal(ownerChecks(db), 1);
  assert(db.calls.length > 1, 'one complete inspection still requires multiple SELECTs');
  const count = db.calls.length;
  await requireFeatureSchema(db, 'media');
  assert.equal(ownerChecks(db), 2);
  assert.equal(db.calls.length, count * 2);
});
test('real readonly adapter isolates connections/features and discards failed checks for retry', async () => {
  const first = connection(); const second = connection();
  await Promise.all([requireFeatureSchema(first, 'media'), requireFeatureSchema(first, 'groups'), requireFeatureSchema(second, 'media')]);
  assert.equal(ownerChecks(first), 2); assert.equal(ownerChecks(second), 1);
  const column = first.fixture.state.tables.get('N_MEDIA_ASSETS').columns.find(c => c.COLUMN_NAME === 'DESCRIPTION');
  column.CHAR_LENGTH = 999;
  const results = await Promise.allSettled(Array.from({ length: 20 }, () => requireFeatureSchema(first, 'media')));
  assert(results.every(r => r.status === 'rejected' && r.reason.statusCode === 503));
  assert.equal(ownerChecks(first), 3);
  for (const r of results) {
    assert.equal(r.reason.data.message, '服务暂不可用，请稍后重试。');
    assert(!/N_MEDIA|Oracle|migration|schema|SELECT/i.test(r.reason.data.message));
  }
  column.CHAR_LENGTH = 1000;
  await requireFeatureSchema(first, 'media');
  assert.equal(ownerChecks(first), 4);
});
