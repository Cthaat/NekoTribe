import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { compileScript, parse } from '@vue/compiler-sfc';
import { build } from 'esbuild';
import * as vue from 'vue';

const root = fileURLToPath(new URL('../', import.meta.url));
const file = 'app/components/GroupAuditLogPanel.vue';
const { descriptor } = parse(readFileSync(root + file, 'utf8'), { filename: file });
const component = compileScript(descriptor, { id: 'group-audit-panel', inlineTemplate: true });
globalThis.__groupAuditVue = vue;
const modules = new Map([
  ['vue', Object.keys(vue).filter(key => /^[a-zA-Z_$][\w$]*$/.test(key))
    .map(key => `export const ${key}=globalThis.__groupAuditVue.${key};`).join('\n')],
  ['@/components/ui/button', 'export const Button={setup(_, {slots}){return ()=>globalThis.__groupAuditVue.h("button",slots.default?.());}};'],
  ['@/composables/useApi', 'export const apiFetch=(path, options)=>globalThis.__groupAudit.request(path, options);']
]);
const bundle = await build({
  stdin: { contents: component.content + '\nexport {authQueueFor} from "@/services/auth-request-queue";', loader: 'ts', resolveDir: root },
  bundle: true, write: false, platform: 'node', format: 'esm', alias: { '@': root + 'app' },
  banner: { js: 'const useNuxtApp=()=>globalThis.__groupAudit.app; const useAppLocale=()=>({t:key=>key});' },
  plugins: [{ name: 'client-boundaries', setup(builder) {
    builder.onResolve({ filter: /.*/ }, ({ path }) => modules.has(path) ? { path, namespace: 'fixture' } : undefined);
    builder.onLoad({ filter: /.*/, namespace: 'fixture' }, ({ path }) => ({ contents: modules.get(path) }));
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

test('audit pages use the group endpoint and reject a previous session response', async () => {
  const requests = [];
  globalThis.__groupAudit = {
    app: { runWithContext: action => action() },
    request: (path, options) => new Promise(resolve => requests.push({ path, ...options, resolve }))
  };
  const host = { children: [] };
  const ui = renderer.createApp(Panel, { groupId: 42 });
  ui.mount(host);
  assert.equal(requests[0].path, '/api/v2/groups/42/audit-logs');
  assert.deepEqual(requests[0].query, { page: 1, page_size: 20 });
  requests[0].resolve({ data: [{ log_id: 6, group_id: 42, action: 'first_action' }], meta: { has_next: true } });
  await flush();
  assert(all(host).some(node => node.text === 'first_action'));
  all(host).find(node => node.type === 'button' && node.children.some(child => child.text === 'groups.audit.next')).props.onClick();
  assert.equal(requests[1].query.page, 2);
  authQueueFor(globalThis.__groupAudit.app).beginIdentityChange();
  assert.equal(requests[1].signal.aborted, true);
  requests[1].resolve({ data: [{ log_id: 7, group_id: 42, action: 'stale_action' }] });
  await flush();
  assert(all(host).some(node => node.text === 'groups.audit.expired'));
  assert(!all(host).some(node => ['first_action', 'stale_action'].includes(node.text)));
  ui.unmount();
});
