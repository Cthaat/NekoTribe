import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const root = fileURLToPath(new URL('../', import.meta.url));
const stubs = {
  '~/server/utils/v2': `
    export const v2Auth=e=>{if(!e.userId)throw Error('unauthorized');return {userId:e.userId}};
    export const v2BadRequest=m=>{throw Error('400:'+m)};
    export const v2Forbidden=m=>{throw Error('403:'+m)};
    export const v2NotFound=m=>{throw Error('404:'+m)};`,
  '~/server/services/v2/groups': `export const v2GroupPermission=async(c,user,group,role)=>{c.calls.push({user,group,role});return c.allowed};`,
  '~/server/services/v2/moderation': `export const requireModerationAccess=async(e,c)=>{c.moderation++;if(!c.moderator)throw Error('403:需要审核权限')};`
};
const compiled = await build({
  stdin: { contents: `export {authorizeConversationScope} from './server/services/ai/conversation-access';`, resolveDir: root, loader: 'ts' },
  bundle: true, write: false, platform: 'node', format: 'esm', plugins: [{ name: 'authorization-boundaries', setup(builder) {
    builder.onResolve({ filter: /.*/ }, args => { if (Object.hasOwn(stubs, args.path)) return { path: args.path, namespace: 'stub' }; });
    builder.onLoad({ filter: /.*/, namespace: 'stub' }, args => ({ contents: stubs[args.path], loader: 'js' }));
  }}]
});
const { authorizeConversationScope } = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);
const db = () => ({ calls: [], moderation: 0, allowed: true, moderator: true });

test('personal conversations require the authenticated owner', async () => {
  const conn = db();
  for (const purpose of ['knowledge', 'writing']) await authorizeConversationScope({ userId: 42 }, conn, { ownerUserId: 42, purpose, groupId: null });
  assert.deepEqual(conn.calls, []); assert.equal(conn.moderation, 0);
  await assert.rejects(() => authorizeConversationScope({ userId: 9 }, conn, { ownerUserId: 42, purpose: 'knowledge', groupId: null }), /404:会话不存在/);
  await assert.rejects(() => authorizeConversationScope({}, conn, { ownerUserId: 42, purpose: 'knowledge', groupId: null }), /unauthorized/);
});

test('group access rechecks administrator permission on every call', async () => {
  const conn = db(); const scope = { ownerUserId: 42, purpose: 'group', groupId: 7 };
  await authorizeConversationScope({ userId: 42 }, conn, scope);
  conn.allowed = false;
  await assert.rejects(() => authorizeConversationScope({ userId: 42 }, conn, scope), /403:需要群管理员权限/);
  assert.deepEqual(conn.calls, [{ user: 42, group: 7, role: 'admin' }, { user: 42, group: 7, role: 'admin' }]);
  await assert.rejects(() => authorizeConversationScope({ userId: 42 }, conn, { ...scope, groupId: -1 }), /400:群组参数错误/);
});

test('moderation and malformed scopes fail closed', async () => {
  const conn = db(); const scope = { ownerUserId: 42, purpose: 'moderation', groupId: null };
  await authorizeConversationScope({ userId: 42 }, conn, scope);
  conn.moderator = false;
  await assert.rejects(() => authorizeConversationScope({ userId: 42 }, conn, scope), /403:需要审核权限/);
  assert.equal(conn.moderation, 2);
  await assert.rejects(() => authorizeConversationScope({ userId: 42 }, conn, { ...scope, groupId: 7 }), /400:群组参数错误/);
  await assert.rejects(() => authorizeConversationScope({ userId: 42 }, conn, { ...scope, purpose: 'unknown' }), /400:会话用途错误/);
});
