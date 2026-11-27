import assert from 'node:assert/strict';
import { test } from 'node:test';
import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';
import * as pinia from 'pinia';
import * as vue from 'vue';

globalThis.__testPinia = pinia;
globalThis.__testVue = vue;
const root = fileURLToPath(new URL('../', import.meta.url));
const built = await build({
  stdin: {
    contents: "export { usePreferenceStore } from './app/stores/user';",
    resolveDir: root,
    loader: 'ts'
  },
  alias: { '@': `${root}app` },
  bundle: true,
  write: false,
  platform: 'node',
  format: 'esm',
  plugins: [
    {
      name: 'glass-pref-boundaries',
      setup(b) {
        for (const name of ['pinia', 'vue', '@/services', '@/utils/assets', '#app']) {
          b.onResolve(
            { filter: new RegExp(`^${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`) },
            () => ({ path: name, namespace: 'stub' })
          );
        }
        b.onLoad({ filter: /.*/, namespace: 'stub' }, ({ path }) => ({
          loader: 'js',
          contents:
            path === 'pinia'
              ? 'export const defineStore = globalThis.__testPinia.defineStore;'
              : path === 'vue'
                ? 'export const computed = globalThis.__testVue.computed;'
                : path === '#app'
                  ? 'export const useNuxtApp = () => globalThis.__stateOwner;'
                  : path === '@/services'
                    ? 'export const v2RefreshCurrentToken = () => Promise.resolve({}); export const v2LogoutCurrent = () => Promise.resolve();'
                    : 'export const normalizeAvatarUrl = x => x;'
        }));
      }
    }
  ]
});
const module = await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);

async function fixture(run) {
  const instance = pinia.createPinia();
  pinia.setActivePinia(instance);
  globalThis.ref = vue.ref;
  globalThis.useNuxtApp = () => globalThis.__stateOwner;
  globalThis.useCookie = (_name, options) => vue.ref(options.default());
  globalThis.__stateOwner = { runWithContext: action => action() };
  const store = module.usePreferenceStore();
  try {
    await run({ store });
  } finally {
    const active = pinia.getActivePinia();
    if (active && active !== instance) pinia.disposePinia(active);
    pinia.disposePinia(instance);
    for (const key of ['ref', 'useCookie', 'useNuxtApp', '__stateOwner']) {
      delete globalThis[key];
    }
  }
}

test('glass_intensity defaults to standard, updates to subtle, and resets cleanly in isolation', () =>
  fixture(async ({ store }) => {
    assert.equal(store.preferences.glass_intensity, 'standard');

    store.updatePreference('glass_intensity', 'subtle');
    assert.equal(store.preferences.glass_intensity, 'subtle');

    const secondPinia = pinia.createPinia();
    pinia.setActivePinia(secondPinia);
    globalThis.__stateOwner = { runWithContext: fn => fn() };
    const second = module.usePreferenceStore();
    try {
      assert.equal(second.preferences.glass_intensity, 'standard');
      second.updatePreference('glass_intensity', 'subtle');
      assert.equal(second.preferences.glass_intensity, 'subtle');

      store.resetToDefaults();
      assert.equal(store.preferences.glass_intensity, 'standard');
      assert.equal(second.preferences.glass_intensity, 'subtle');
    } finally {
      pinia.disposePinia(secondPinia);
    }
  }));
