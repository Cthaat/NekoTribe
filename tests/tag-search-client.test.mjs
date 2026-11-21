import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

test('tag discovery requests the matching page and opens an exact tag feed', async () => {
  const compiled = await build({
    stdin: {
      contents: `export { v2SearchTags, v2ListTagPosts } from './app/api/v2/posts.ts';`,
      resolveDir: fileURLToPath(new URL('../', import.meta.url)),
    },
    bundle: true,
    write: false,
    platform: 'node',
    format: 'esm',
    plugins: [{ name: 'tag-request-recorder', setup(builder) {
      builder.onResolve({ filter: /^\.\/client$/ }, () => ({ path: 'client', namespace: 'fixture' }));
      builder.onLoad({ filter: /.*/, namespace: 'fixture' }, () => ({ contents: `
        export const toV2PagedResult = response => response;
        export function v2RequestData(path, options) { return {path, options}; }
        export function v2Request(path, options) { return {path, options}; }
      ` }));
    } }],
  });
  const api = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);
  const { signal } = new AbortController();
  assert.deepEqual(await api.v2SearchTags('Cats', signal), {
    path: '/api/v2/tags', options: { query: { q: 'Cats', page_size: 6 }, signal },
  });
  assert.deepEqual(await api.v2ListTagPosts('C# cats', { page: 2, page_size: 15 }), {
    path: '/api/v2/tags/C%23%20cats/posts', options: { query: { page: 2, page_size: 15 } },
  });
});
