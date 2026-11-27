import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { parse } from '@vue/compiler-sfc';
import { transform } from 'esbuild';
import { computed, nextTick, ref, watch } from 'vue';

const component = readFileSync(new URL('../app/components/AppGlobalSearch.vue', import.meta.url), 'utf8');
const source = parse(component).descriptor.scriptSetup.content.replace(/^import[\s\S]*? from ['"][^'"]+[''];\r?\n/gm, '');
const { code } = await transform(source, { loader: 'ts' });
const fixture = new Function('computed', 'nextTick', 'ref', 'vueWatch', 'ownerQueue',
  'v2SearchUsers', 'v2RecommendedUsers', 'routeQuery', `
  const useRoute = () => ({path: '/feed', params: {}, query: routeQuery});
  const useAppLocale = () => ({t: key => key, locale: ref('en')});
  const useLocalePath = () => value => value;
  const useNuxtApp = () => ({});
  const usePreferenceStore = () => ({preferences: {user: {id: 42}}});
  const authQueueFor = () => ownerQueue;
  const cleanups = [];
  const watch = (...args) => cleanups.push(vueWatch(...args));
  const mountCallbacks = [];
  const onMounted = fn => mountCallbacks.push(fn);
  const onBeforeUnmount = fn => cleanups.push(fn);
  let timer;
  const setTimeout = fn => { timer = fn; return 1; };
  const clearTimeout = () => { timer = undefined; };
  ${code}
  mountCallbacks.forEach(fn => fn());
  return {close: () => cleanups.forEach(fn => fn()), searchQuery, users, showingRecommendations,
    showRecommendations, isSearchingUsers, isPopoverOpen, fireTimer: () => timer?.()};
`);

function open({ search, recommendations, people }) {
  let notify;
  const queue = {
    revision: 0,
    isIdentityChanging: false,
    subscribe(listener) {
      notify = listener;
      return () => { notify = undefined; };
    }
  };
  const view = fixture(computed, nextTick, ref, watch, queue, search, recommendations, { people });
  return { view, changeAccount() { queue.revision++; notify(); } };
}

test('a command palette people search opens the existing user results', async () => {
  const { view } = open({
    people: '  example  ',
    search: async query => { assert.equal(query.q, 'example'); return { items: [{ id: 8 }] }; }
  });
  try {
    assert.equal(view.searchQuery.value, 'example');
    assert.equal(view.isPopoverOpen.value, true);
    view.fireTimer();
    await nextTick();
    assert.deepEqual(view.users.value, [{ id: 8 }]);
  } finally { view.close(); }
});

test('typing switches from recommendations to user search and discards the older list', async () => {
  let finishRecommendation;
  const oldList = new Promise(resolve => { finishRecommendation = resolve; });
  const { view } = open({
    recommendations: limit => { assert.equal(limit, 6); return oldList; },
    search: async query => { assert.equal(query.q, 'alice'); return { items: [{ id: 2 }] }; }
  });
  try {
    view.showRecommendations();
    assert.equal(view.showingRecommendations.value, true);
    view.searchQuery.value = 'alice';
    view.fireTimer();
    await nextTick();
    finishRecommendation([{ id: 1 }]);
    await nextTick();
    assert.deepEqual(view.users.value, [{ id: 2 }]);
    assert.equal(view.showingRecommendations.value, false);
    assert.equal(view.isSearchingUsers.value, false);
  } finally { view.close(); }
});

test('changing accounts clears visible users and cancels both pending and delayed work', async () => {
  let finishSearch;
  let reads = 0;
  const pending = new Promise(resolve => { finishSearch = resolve; });
  const { view, changeAccount } = open({
    recommendations: async () => [{ id: 3 }],
    search: () => { reads++; return pending; }
  });
  try {
    view.showRecommendations();
    await nextTick();
    assert.deepEqual(view.users.value, [{ id: 3 }]);
    view.searchQuery.value = 'cancel before dispatch';
    changeAccount();
    view.fireTimer();
    assert.equal(reads, 0);
    view.searchQuery.value = 'cancel during request';
    view.fireTimer();
    assert.equal(reads, 1);
    changeAccount();
    finishSearch({ items: [{ id: 4 }] });
    await nextTick();
    assert.deepEqual(view.users.value, []);
    assert.equal(view.isPopoverOpen.value, false);
  } finally { view.close(); }
});
