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
    export const v2NotFound=m=>{throw Error('404:'+m)};
    export const v2ServerError=()=>{throw Error('500:internal')};
    export const v2String=v=>typeof v==='string'?v:'';
    export const v2Number=v=>Number(v)||0;
    export const v2DateString=v=>typeof v==='string'?v:null;
    export const v2Execute=async(c,sql,binds,autoCommit)=>c.insert(sql,binds,autoCommit);
    export const v2One=async(c,sql,binds)=>c.read(sql,binds);`,
  '~/server/database/readiness': `export const requireFeatureSchema=async(c,feature)=>{c.checks.push(feature)};`,
  '~/server/services/v2/groups': `export const v2GroupPermission=async(c)=>{c.permissionChecks++;return c.allowed};`,
  '~/server/services/v2/moderation': `export const requireModerationAccess=async(e,c)=>{if(!c.moderator)throw Error('403:需要审核权限')};`
};
const compiled = await build({
  stdin: { contents: `export {createConversation,readConversation} from './server/services/ai/conversation-store';`, resolveDir: root, loader: 'ts' },
  bundle: true, write: false, platform: 'node', format: 'esm', plugins: [{ name: 'conversation-store-boundaries', setup(builder) {
    builder.onResolve({ filter: /.*/ }, args => { if (Object.hasOwn(stubs, args.path)) return { path: args.path, namespace: 'stub' }; });
    builder.onLoad({ filter: /.*/, namespace: 'stub' }, args => ({ contents: stubs[args.path], loader: 'js' }));
  }}]
});
const { createConversation, readConversation } = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);
function database() {
  return { checks: [], permissionChecks: 0, allowed: true, moderator: true, saved: null, pending: null, commits: 0, rollbacks: 0,
    async insert(sql, binds, autoCommit) {
      assert.match(sql, /INSERT INTO n_ai_conversations/); assert.equal(autoCommit, false);
      this.pending = { CONVERSATION_ID: binds.conversation_id, OWNER_USER_ID: binds.owner_user_id, PURPOSE: binds.purpose, GROUP_ID: binds.group_id, TITLE: binds.title, CREATED_AT: 'created', UPDATED_AT: 'updated' };
      if (this.revokeAfterInsert) this.allowed = false;
      return 1;
    },
    async read(sql, binds) {
      assert.match(sql, /owner_user_id=:owner_user_id/);
      const row = this.pending ?? this.saved;
      return row && row.CONVERSATION_ID === binds.conversation_id && row.OWNER_USER_ID === binds.owner_user_id ? row : null;
    },
    async commit() { this.commits++; if (this.failCommit) throw Error('private'); this.saved = this.pending; this.pending = null; },
    async rollback() { this.rollbacks++; if (this.failRollback) throw Error('private rollback'); this.pending = null; }
  };
}

test('create and read restrict ownership and never accept provider credentials', async () => {
  const db = database();
  const result = await createConversation({ userId: 42 }, db, { purpose: 'knowledge', title: '  hello  ' });
  assert.match(result.conversation_id, /^[0-9a-f-]{36}$/); assert.equal(result.title, 'hello'); assert.equal(db.commits, 1);
  assert.deepEqual(await readConversation({ userId: 42 }, db, result.conversation_id), result);
  await assert.rejects(() => readConversation({ userId: 9 }, db, result.conversation_id), /404:会话不存在/);
  await assert.rejects(() => createConversation({ userId: 42 }, db, { purpose: 'knowledge', api_key: 'secret' }), /400:会话参数错误/);
});

test('group permission is checked again before commit and on later reads', async () => {
  const db = database(); db.revokeAfterInsert = true;
  await assert.rejects(() => createConversation({ userId: 42 }, db, { purpose: 'group', group_id: 7 }), /403:需要群管理员权限/);
  assert.equal(db.permissionChecks, 2); assert.equal(db.commits, 0); assert.equal(db.rollbacks, 1); assert.equal(db.saved, null);
  db.allowed = true; db.revokeAfterInsert = false;
  const result = await createConversation({ userId: 42 }, db, { purpose: 'group', group_id: 7 });
  db.allowed = false;
  await assert.rejects(() => readConversation({ userId: 42 }, db, result.conversation_id), /403:需要群管理员权限/);
});

test('moderation permission and uncertain commit fail safely', async () => {
  const db = database(); db.moderator = false;
  await assert.rejects(() => createConversation({ userId: 42 }, db, { purpose: 'moderation' }), /403:需要审核权限/);
  assert.equal(db.pending, null);
  db.moderator = true; db.failCommit = true;
  await assert.rejects(() => createConversation({ userId: 42 }, db, { purpose: 'moderation' }), /500:internal/);
  assert.equal(db.commits, 1); assert.equal(db.rollbacks, 0);
});

test('rollback failure is safely reported without leaking driver details', async () => {
  const db = database(); db.revokeAfterInsert = true; db.failRollback = true;
  await assert.rejects(() => createConversation({ userId: 42 }, db, { purpose: 'group', group_id: 7 }), error => error.message === '500:internal');
  assert.equal(db.commits, 0); assert.equal(db.rollbacks, 1);
});
