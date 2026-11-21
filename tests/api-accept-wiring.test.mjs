import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

// Exercise the real composables with only Nuxt/Vue context and HTTP boundaries
// replaced. No application, browser, socket or network request is started.
const root = fileURLToPath(new URL('../', import.meta.url));
const compiled = await build({
  stdin: {
    contents: `
      export { apiFetch } from './app/composables/useApi.ts';
      export { useApiFetch } from './app/composables/useApiFetch.ts';
    `,
    resolveDir: root,
    loader: 'ts'
  },
  bundle: true,
  write: false,
  platform: 'node',
  format: 'esm',
  banner: { js: `
    const tryUseNuxtApp = () => null;
    const useRuntimeConfig = () => ({public: {apiBase: ''}});
    const useRoute = () => undefined;
    const useRequestHeaders = () => ({cookie: 'fixture=1', authorization: 'Bearer fixture'});
    const $fetch = async (path, options) => ({path, options});
    const console = {info() {}, error() {}};
  ` },
  plugins: [{
    name: 'offline-context',
    setup(builder) {
      builder.onResolve({ filter: /^~\/utils\/apiHeaders$/ }, () => ({
        path: fileURLToPath(new URL('../app/utils/apiHeaders.ts', import.meta.url))
      }));
      builder.onResolve({ filter: /^(vue|#app|~\/stores\/user)$/ }, args => ({
        path: args.path,
        namespace: 'offline-context'
      }));
      builder.onLoad({ filter: /.*/, namespace: 'offline-context' }, args => ({
        contents: args.path === 'vue'
          ? 'export const getCurrentInstance = () => null; export const watch = () => {};'
          : args.path === '#app'
            ? 'export const useNuxtApp = () => ({$config: {public: {apiBase: ""}}, runWithContext: fn => fn()}); export const useFetch = (path, options) => options.$fetch ? options.$fetch(path, options) : ({path, options});'
            : 'export const usePreferenceStore = () => { throw new Error("Unexpected auth refresh"); };'
      }));
    }
  }]
});
const composables = await import(
  `data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`
);

test('web sends the same device fingerprint across both login steps without local storage', async t => {
  globalThis.window = {get localStorage() { throw new Error('storage blocked'); }};
  t.after(() => { delete globalThis.window; });
  const first = await composables.apiFetch('/api/v2/auth/tokens', {method:'POST'});
  const second = await composables.apiFetch('/api/v2/auth/two-factor/challenges/fixture', {method:'POST'});
  const fingerprint = new Headers(first.options.headers).get('x-device-fingerprint');
  assert.match(fingerprint, /^fp_/);
  assert.equal(new Headers(second.options.headers).get('x-device-fingerprint'), fingerprint);
});

for (const entry of ['apiFetch', 'useApiFetch']) {
  test(`${entry} defaults to JSON and preserves credentials/auth headers`, async () => {
    const result = await composables[entry]('/api/v2/posts', {
      headers: { Authorization: 'Bearer caller' }
    });
    assert.equal(result.options.headers.Accept, 'application/json');
    assert.equal(result.options.headers.Authorization, 'Bearer caller');
    assert.equal(result.options.credentials, 'include');
    if (entry === 'apiFetch') {
      assert.equal(result.options.headers.cookie, 'fixture=1');
    }
  });

  for (const headers of [
    { aCcEpT: 'text/event-stream' },
    [['accept', 'application/problem+json']],
    new Headers({ ACCEPT: 'text/plain' })
  ]) {
    test(`${entry} preserves explicitly negotiated header input ${JSON.stringify(headers)}`, async () => {
      const result = await composables[entry]('/api/v2/posts', { headers });
      const expected = new Headers(headers).get('accept');
      const actual = new Headers(result.options.headers);
      assert.equal(actual.get('accept'), expected);
      assert.equal(result.options.credentials, 'include');
    });
  }
}
