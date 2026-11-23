import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { parse } from '@vue/compiler-sfc';
import { transformSync } from 'esbuild';
import { computed, ref, shallowRef } from 'vue';

const source = readFileSync(new URL('../app/components/AccountResources.vue', import.meta.url), 'utf8');
const { scriptSetup } = parse(source).descriptor;
const { code } = transformSync(scriptSetup.content.replace(/^import[\s\S]*? from ['"][^'"]+[''];\r?\n/gm, ''), { loader: 'ts' });
const fixture = new Function('ref', 'shallowRef', 'computed', 'v2GetAccountUsage', `
  const defineProps = () => ({});
  const useAppLocale = () => ({ t: (key, value) => value ?? key });
  const useNuxtApp = () => ({ runWithContext: fn => fn() });
  const usePreferenceStore = () => ({ isLoggedIn: true });
  const authQueueFor = () => ({ isIdentityChanging: false });
  const onMounted = () => {};
  const onBeforeUnmount = () => {};
  const watch = () => {};
  ${code}
  return { load, usage, quota, reset, failed };
`);

test('the resource panel displays returned usage and the quota window', async () => {
  const actual = {
    ai_quota: { used_units: 7, limit_units: 20, window_seconds: 60 },
    media: { bytes: 768, files: 2 },
    ai_history: { conversations: 3 }
  };
  const panel = fixture(ref, shallowRef, computed, async () => actual);
  await panel.load();
  assert.deepEqual(panel.usage.value, actual);
  assert.deepEqual(panel.quota.value, { used: 7, limit: 20, seconds: 60 });
});

test('an account change discards pending usage for the prior account', async () => {
  let finish;
  const panel = fixture(ref, shallowRef, computed, () => new Promise(resolve => { finish = resolve; }));
  const loading = panel.load();
  panel.reset();
  finish({ media: { bytes: 768 } });
  await loading;
  assert.equal(panel.usage.value, null);
});
