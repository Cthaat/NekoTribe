import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { parse } from '@vue/compiler-sfc';
import { transform } from 'esbuild';
import { ref, computed } from 'vue';

const page = readFileSync(new URL('../app/pages/account/statements.vue', import.meta.url), 'utf8');
const source = parse(page).descriptor.scriptSetup.content.replace(/^import[\s\S]*? from ['"][^'"]+[''];\r?\n/gm, '');
const { code } = await transform(source, { loader:'ts' });
const fixture = new Function('ref', 'computed', 'v2ListAccountStatements', 'v2CreateStatementAppeal', `
  const useAppLocale = () => ({t: key => key});
  const useNuxtApp = () => ({});
  const messages = [];
  const toast = {success: value => messages.push(value), error: value => messages.push(value)};
  let observe;
  const authQueueFor = () => fakeQueue;
  const fakeQueue = {revision:0,isIdentityChanging:false,subscribe: listener => {observe=listener;return () => {}}};
  const onMounted = () => {};
  const onUnmounted = () => {};
  ${code}
  return { load, items, expired, showAppeal, appealMsg, submitCurrentAppeal, messages, changeOwner() {fakeQueue.revision++; observe();} };
`);

test('account change clears a draft and suppresses pending records of the outgoing account', async () => {
  let finish;
  let writes = 0;
  const pending = new Promise(resolve => { finish = resolve; });
  const view = fixture(ref, computed, () => pending, () => { writes++; });
  const load = view.load();
  view.showAppeal.value = '9';
  view.appealMsg.value = 'Please review';
  view.changeOwner();
  finish({items:[{id:9}],total:1});
  await load;
  await view.submitCurrentAppeal();
  assert.deepEqual(view.items.value, []);
  assert.equal(view.showAppeal.value, null);
  assert.equal(view.appealMsg.value, '');
  assert.equal(view.expired.value, true);
  assert.equal(writes, 0);
});

test('a conflict identifies the pending appeal and preserves the draft', async () => {
  const view = fixture(ref, computed, async () => ({items:[],total:0}), async (id, payload) => {
    assert.equal(id, 9);
    assert.deepEqual(payload, {appealMessage:'Please review'});
    throw Object.assign(new Error('Conflict'), {statusCode:409});
  });
  view.showAppeal.value = '9';
  view.appealMsg.value = '  Please review  ';
  await view.submitCurrentAppeal();
  assert.deepEqual(view.messages, ['account.statements.appealPending']);
  assert.equal(view.appealMsg.value, '  Please review  ');
});
