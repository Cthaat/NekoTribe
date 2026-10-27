import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import { test } from 'node:test';
import { build } from 'esbuild';

const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(import.meta.url);
const compiled = await build({
  entryPoints: [path.join(root, 'server/storage/index.ts')],
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{name: 'external-dependencies', setup(builder) {
    builder.onResolve({filter: /.*/}, args => {
      if (args.path.startsWith('node:')) return {path: args.path, external: true};
      if (!args.path.startsWith('.') && !path.isAbsolute(args.path)) return {path: pathToFileURL(require.resolve(args.path)).href, external: true};
    });
  }}]
});
const {normalizeAvatarPublicUrl} = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);
const vectors = JSON.parse(readFileSync(path.join(root, 'specifications/scenarios/storage-public-urls.json'), 'utf8'));
const keys = ['STORAGE_PUBLIC_BASE', 'BASE_URL', 'STORAGE_CDN_BASE_URL'];

for (const vector of vectors.cases) test(`Nuxt public storage URL: ${vector.id}`, () => {
  const original = Object.fromEntries(keys.map(key => [key, process.env[key]]));
  try {
    for (const key of keys) delete process.env[key];
    for (const [key, value] of Object.entries(vector.env)) process.env[key] = value;
    if (vector.error) assert.throws(() => normalizeAvatarPublicUrl(vector.input), error => {
      assert.doesNotMatch(String(error), /synthetic-password/);
      return true;
    });
    else assert.equal(normalizeAvatarPublicUrl(vector.input), vector.expected);
  } finally {
    for (const key of keys) original[key] === undefined ? delete process.env[key] : process.env[key] = original[key];
  }
});
