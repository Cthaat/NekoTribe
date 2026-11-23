import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { loadNuxtConfig } from '@nuxt/kit';

const cwd = fileURLToPath(new URL('../', import.meta.url));
const files = ['test.vue', 'test-token-refresh.vue', 'ws/index.vue', 'account.vue'];

test('debug pages require both development mode and an explicit opt-in', async () => {
  const config = await loadNuxtConfig({ cwd, dotenv: false, globalRc: false });
  const installDebugPages = config.modules.find(module => module?.name === 'debugPages');
  assert.equal(typeof installDebugPages, 'function');
  const saved = process.env.NUXT_ENABLE_DEBUG_PAGES;
  try {
    for (const [dev, enabled, expected] of [
      [false, '1', ['account.vue']],
      [true, '0', ['account.vue']],
      [true, '1', files]
    ]) {
      process.env.NUXT_ENABLE_DEBUG_PAGES = enabled;
      const pages = files.map(name => ({ file: `${cwd}/app/pages/${name}` }));
      installDebugPages({}, {
        options: { dev },
        hook(name, filter) {
          assert.equal(name, 'pages:extend');
          filter(pages);
        }
      });
      assert.deepEqual(pages.map(page => page.file.split('/app/pages/').at(-1)), expected);
    }
  } finally {
    if (saved === undefined) delete process.env.NUXT_ENABLE_DEBUG_PAGES;
    else process.env.NUXT_ENABLE_DEBUG_PAGES = saved;
  }
});
