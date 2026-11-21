import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { compileScript, parse } from '@vue/compiler-sfc';
import { build } from 'esbuild';
import * as vue from 'vue';

const root = fileURLToPath(new URL('../', import.meta.url));
const file = 'app/components/PostLikersDialog.vue';
const { descriptor } = parse(readFileSync(root + file, 'utf8'), { filename: file });
const component = compileScript(descriptor, { id: 'post-likers-dialog', inlineTemplate: true });
globalThis.__postLikersVue = vue;
const stubs = new Map([
  ['vue', Object.keys(vue).filter(key => /^[a-zA-Z_$][\w$]*$/.test(key))
    .map(key => `export const ${key}=globalThis.__postLikersVue.${key};`).join('\n')],
  ['@/components/ui/button', 'export const Button={setup(_, {slots}){return ()=>globalThis.__postLikersVue.h("button",slots.default?.());}};'],
  ['@/components/ui/dialog', `
    const wrapper={setup(_, {slots}){return ()=>globalThis.__postLikersVue.h('div', slots.default?.());}};
    export const DialogHeader=wrapper, DialogTitle=wrapper, DialogContent=wrapper, DialogTrigger=wrapper;
    export const Dialog={props:['open'],emits:['update:open'],setup(props, {slots, emit}){
      globalThis.__postLikers.toggle=value=>emit('update:open',value);
      return ()=>globalThis.__postLikersVue.h('section', props.open ? slots.default?.() : []);
    }};`],
  ['@/composables/useApi', 'export const apiFetch=(path, options)=>globalThis.__postLikers.request(path, options);']
]);
const bundle = await build({
  stdin: { contents: component.content + '\nexport {authQueueFor} from "@/services/auth-request-queue";', loader: 'ts', resolveDir: root },
  bundle: true, write: false, platform: 'node', format: 'esm', alias: { '@': root + 'app' },
  banner: { js: 'const useNuxtApp=()=>globalThis.__postLikers.app; const useAppLocale=()=>({t:key=>key}); const useLocalePath=()=>value=>value;' },
  plugins: [{ name: 'client-boundaries', setup(builder) {
    builder.onResolve({ filter: /.*/ }, ({ path }) => stubs.has(path) ? { path, namespace: 'fixture' } : undefined);
    builder.onLoad({ filter: /.*/, namespace: 'fixture' }, ({ path }) => ({ contents: stubs.get(path) }));
  } }]
});
const { default: Panel, authQueueFor } = await import(`data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`);

const detach = node => {
  if (!node.parent) return;
  node.parent.children.splice(node.parent.children.indexOf(node), 1);
  node.parent = null;
};
const renderer = vue.createRenderer({
  createElement: type => ({ type, children: [], props: {} }),
  createText: text => ({ text }), createComment: () => ({}),
  setText: (node, text) => { node.text = text; },
  setElementText: (node, text) => { node.text = text; node.children = []; },
  parentNode: node => node.parent,
  nextSibling: node => node.parent?.children[node.parent.children.indexOf(node) + 1],
  insert(node, parent, anchor) {
    detach(node);
    parent.children.splice(anchor ? parent.children.indexOf(anchor) : parent.children.length, 0, node);
    node.parent = parent;
  },
  remove: detach,
  patchProp: (node, key, _, value) => { node.props[key] = value; }
});
const all = node => [node, ...(node.children ?? []).flatMap(all)];
const flush = async () => { await new Promise(resolve => setImmediate(resolve)); await vue.nextTick(); };

test('likes read the visible roster and close on identity change during pagination', async () => {
  const requests = [];
  globalThis.__postLikers = {
    app: { runWithContext: action => action() },
    request: (path, options) => new Promise(resolve => requests.push({ path, ...options, resolve }))
  };
  const host = { children: [] };
  const ui = renderer.createApp(Panel, { postId: 42 });
  ui.component('NuxtLink', { props: ['to'], setup: (props, { slots }) => () => vue.h('a', { href: props.to }, slots.default?.()) });
  ui.mount(host);
  globalThis.__postLikers.toggle(true);
  assert.equal(requests[0].path, '/api/v2/posts/42/likes');
  assert.deepEqual(requests[0].query, { page: 1, page_size: 20 });
  requests[0].resolve({ data: [{ user_id: 9, display_name: 'First liker', username: 'first' }], meta: { has_next: true } });
  await flush();
  assert(all(host).some(node => node.props?.href === '/user/9/profile'));
  all(host).find(node => node.type === 'button' && node.children.some(child => child.text === 'post.likers.next')).props.onClick();
  assert.equal(requests[1].query.page, 2);
  authQueueFor(globalThis.__postLikers.app).beginIdentityChange();
  assert.equal(requests[1].signal.aborted, true);
  requests[1].resolve({ data: [{ user_id: 10, display_name: 'Stale liker', username: 'stale' }] });
  await flush();
  assert(!all(host).some(node => node.type === 'a'));
  ui.unmount();
});
