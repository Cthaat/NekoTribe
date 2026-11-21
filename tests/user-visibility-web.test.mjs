import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { parse } from '@vue/compiler-sfc';
import { transform } from 'esbuild';
import { computed, ref } from 'vue';

const component = readFileSync(new URL('../app/components/AccountVisibilitySettings.vue', import.meta.url), 'utf8');
const source = parse(component).descriptor.scriptSetup.content.replace(/^import .*;\r?\n/gm, '');
const { code } = await transform(source, { loader: 'ts' });
const fixture = new Function('computed', 'ref', 'ownerQueue', 'listUserVisibility', 'setUserVisibility', `
  const useAppLocale = () => ({});
  const useLocalePath = () => {};
  const useNuxtApp = () => {};
  const authQueueFor = () => ownerQueue;
  const onMounted = () => {};
  const onUnmounted = () => {};
  ${code}
  return { load, selectKind, remove, users, page };
`);

test('removing the last account on a page returns to the preceding page', async () => {
  const calls = [];
  let total = 21;
  const queue = { revision: 0, isIdentityChanging: false };
  const view = fixture(computed, ref, queue, async (kind, page, size) => {
    calls.push([kind, page, size]);
    return { items: page === 1 ? [{ user_id: 1 }] : total === 21 ? [{ user_id: 21 }] : [], meta: { total } };
  }, async (kind, target, remove) => {
    assert.deepEqual([kind, target, remove], ['blocks', 21, true]);
    total--;
  });
  await view.load(2);
  assert.equal(view.users.value[0].user_id, 21);
  await view.remove(21);
  assert.equal(view.page.value, 1);
  assert.equal(view.users.value[0].user_id, 1);
  assert.deepEqual(calls, [['blocks', 2, 20], ['blocks', 2, 20], ['blocks', 1, 20]]);
});

test('an outgoing account cannot display late results or dispatch retained actions', async () => {
  const queue = { revision: 0, isIdentityChanging: false };
  let finish;
  const result = new Promise(resolve => { finish = resolve; });
  let writes = 0;
  const view = fixture(computed, ref, queue, () => result, () => { writes++; });
  const loading = view.load(1);
  queue.revision++;
  finish({ items: [{ user_id: 7 }], meta: { total: 1 } });
  await loading;
  await view.remove(7);
  assert.deepEqual(view.users.value, []);
  assert.equal(writes, 0);
});
