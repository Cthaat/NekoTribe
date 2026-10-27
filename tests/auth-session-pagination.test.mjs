import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { test } from 'node:test';
import { build } from 'esbuild';

const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(import.meta.url);
const stubs = {
  oracledb: 'export default {OUT_FORMAT_OBJECT: 4002};',
  './api-cache': 'export const readApiResponseCache = async () => ({status:"disabled"}); export const writeApiResponseCache = async () => {}; export const invalidateApiResponseCache = async () => {}; export const shouldInvalidateApiResponseCache = () => false;',
  './logging': 'export const getRequestLogContext = () => null; export const logError = () => {}; export const logInfo = () => {}; export const serializeLogError = () => ({});'
};
const compiled = await build({
  entryPoints: [path.join(root, 'server/utils/v2.ts')],
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{name: 'isolated-boundaries', setup(builder) {
    builder.onResolve({filter: /.*/}, args => {
      if (Object.hasOwn(stubs, args.path)) return {path: args.path, namespace: 'stub'};
      if (args.path.startsWith('node:')) return {path: args.path, external: true};
      if (!args.path.startsWith('.') && !path.isAbsolute(args.path)) return {path: pathToFileURL(require.resolve(args.path)).href, external: true};
    });
    builder.onLoad({filter: /.*/, namespace: 'stub'}, args => ({contents: stubs[args.path], loader: 'js'}));
  }}]
});
const {v2Page} = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);
const fixtures = JSON.parse(readFileSync(path.join(root, 'specifications/scenarios/auth-session-pagination.json'), 'utf8'));
for (const {id, query, ...expected} of fixtures.cases) {
  test(`Nuxt session pagination ${id}`, () => {
    assert.deepEqual(v2Page({path: `/api/v2/auth/sessions?${query}`}), expected);
  });
}
