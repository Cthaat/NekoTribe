import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const root = fileURLToPath(new URL('../', import.meta.url));
const stubs = {
  'oracledb': `export default { OUT_FORMAT_OBJECT: 4002, STRING: { num: 2001 } };`,
  '~/server/utils/v2': `
    export const v2Auth=e=>{if(!e.userId)throw Error('unauthorized');return {userId:e.userId}};
    export const v2BadRequest=m=>{throw Error('400:'+m)};
    export const v2Forbidden=m=>{throw Error('403:'+m)};
    export const v2NotFound=m=>{throw Error('404:'+m)};
    export const v2Conflict=m=>{throw Error('409:'+m)};
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
  stdin: { contents: `export {createConversation,readConversation,deleteConversation,appendUserMessage,appendAssistantMessage,listConversationMessages,listRecentConversationMessages} from './server/services/ai/conversation-store';`, resolveDir: root, loader: 'ts' },
  bundle: true, write: false, platform: 'node', format: 'esm', plugins: [{ name: 'conversation-store-boundaries', setup(builder) {
    builder.onResolve({ filter: /.*/ }, args => { if (Object.hasOwn(stubs, args.path)) return { path: args.path, namespace: 'stub' }; });
    builder.onLoad({ filter: /.*/, namespace: 'stub' }, args => ({ contents: stubs[args.path], loader: 'js' }));
  }}]
});
const { createConversation, readConversation, deleteConversation, appendUserMessage, appendAssistantMessage, listConversationMessages, listRecentConversationMessages } = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);
function database() {
  return { checks: [], permissionChecks: 0, allowed: true, moderator: true, saved: null, pending: null, messages: [], pendingMessage: null, commits: 0, rollbacks: 0,
    async insert(sql, binds, autoCommit) {
      if (/DELETE FROM n_ai_conversations/.test(sql)) {
        assert.equal(autoCommit, false);
        assert.equal(binds.owner_user_id, this.saved?.OWNER_USER_ID);
        assert.equal(binds.conversation_id, this.saved?.CONVERSATION_ID);
        this.pendingDelete = true;
        if (this.revokeAfterDelete) this.allowed = false;
        return 1;
      }
      if (/INSERT INTO n_ai_messages/.test(sql)) {
        assert.equal(autoCommit, false); this.pendingMessage = binds;
        if (this.revokeAfterMessage) this.allowed = false;
        return 1;
      }
      if (/UPDATE n_ai_conversations/.test(sql)) return 1;
      assert.match(sql, /INSERT INTO n_ai_conversations/); assert.equal(autoCommit, false);
      this.pending = { CONVERSATION_ID: binds.conversation_id, OWNER_USER_ID: binds.owner_user_id, PURPOSE: binds.purpose, GROUP_ID: binds.group_id, TITLE: binds.title, CREATED_AT: 'created', UPDATED_AT: 'updated' };
      if (this.revokeAfterInsert) this.allowed = false;
      return 1;
    },
    async read(sql, binds) {
      if (/MAX\(sequence_no\)/i.test(sql)) return { NEXT_SEQUENCE: this.messages.length + 1 };
      assert.match(sql, /owner_user_id=:owner_user_id/);
      if (this.expectLock) assert.match(sql, /FOR UPDATE/i);
      const row = this.pending ?? this.saved;
      return row && row.CONVERSATION_ID === binds.conversation_id && row.OWNER_USER_ID === binds.owner_user_id ? row : null;
    },
    async execute(sql, binds, options) {
      assert.match(sql, /owner_user_id\s*=\s*:owner_user_id/i);
      assert.match(sql, /ORDER BY m.sequence_no (ASC|DESC)/i);
      assert.deepEqual(options.fetchTypeHandler({name: 'CONTENT'}), {type: {num: 2001}});
      assert.equal(options.fetchTypeHandler({name: 'MODEL_ID'}), undefined);
      if (this.revokeDuringList) this.allowed = false;
      const messages=this.messages.filter(m => m.sequence_no > binds.after_sequence);
      if (/ORDER BY m.sequence_no DESC/i.test(sql)) messages.reverse();
      return { rows: messages.slice(0, binds.row_limit).map(m => ({
        MESSAGE_ID: m.message_id, CONVERSATION_ID: m.conversation_id, SEQUENCE_NO: m.sequence_no,
        ROLE: m.role, CONTENT: m.content, MODEL_ID: m.model_id, MODEL_VERSION: null, CONFIG_REVISION: m.config_revision, CREATED_AT: 'created'
      })) };
    },
    async commit() { this.commits++; if (this.failCommit) throw Error('private'); if (this.pendingDelete) {this.saved=null;this.messages=[];this.pendingDelete=false;} if (this.pending) this.saved = this.pending; this.pending = null; if (this.pendingMessage) this.messages.push(this.pendingMessage); this.pendingMessage = null; },
    async rollback() { this.rollbacks++; if (this.failRollback) throw Error('private rollback'); this.pendingDelete=false; this.pending = null; this.pendingMessage = null; }
  };
}

test('delete locks owned conversation and removes its messages only after commit', async () => {
  const db=database(),actor={userId:42};
  const c=await createConversation(actor,db,{purpose:'writing'});
  await appendUserMessage(actor,db,c.conversation_id,'private');
  db.expectLock=true;
  await assert.rejects(()=>deleteConversation({userId:9},db,c.conversation_id),/404:/);
  assert.equal(db.messages.length,1);
  await deleteConversation(actor,db,c.conversation_id);
  assert.equal(db.saved,null); assert.deepEqual(db.messages,[]);
});

test('delete rolls back if group permission is revoked before commit',async()=>{
  const db=database(),actor={userId:42};
  const c=await createConversation(actor,db,{purpose:'group',group_id:7});
  db.revokeAfterDelete=true;
  await assert.rejects(()=>deleteConversation(actor,db,c.conversation_id),/403:/);
  assert.equal(db.saved.CONVERSATION_ID,c.conversation_id); assert.equal(db.rollbacks,1);
});

test('delete rejects malformed identifiers and never assumes an uncertain commit rolled back',async()=>{
  const db=database(),actor={userId:42};
  const c=await createConversation(actor,db,{purpose:'writing'});
  const checks=db.checks.length;
  await assert.rejects(()=>deleteConversation(actor,db,'invalid'),/404:/);
  assert.equal(db.checks.length,checks);
  db.failCommit=true;
  await assert.rejects(()=>deleteConversation(actor,db,c.conversation_id),error=>error.message==='500:internal');
  assert.equal(db.rollbacks,0);
});

test('message history paginates by sequence and hides other users conversations', async () => {
  const db = database();
  const conversation = await createConversation({ userId: 42 }, db, { purpose: 'knowledge' });
  await appendUserMessage({ userId: 42 }, db, conversation.conversation_id, 'first');
  await appendUserMessage({ userId: 42 }, db, conversation.conversation_id, 'second');
  const page = await listConversationMessages({ userId: 42 }, db, conversation.conversation_id, 1, 10);
  assert.deepEqual(page.map(m => [m.sequence_no, m.content]), [[2, 'second']]);
  await assert.rejects(() => listConversationMessages({ userId: 9 }, db, conversation.conversation_id, 0, 10), /404:/);
  await assert.rejects(() => listConversationMessages({ userId: 42 }, db, conversation.conversation_id, -1, 10), /400:/);
  await assert.rejects(() => listConversationMessages({ userId: 42 }, db, conversation.conversation_id, 0, 51), /400:/);
});

test('recent conversation history uses newest messages in chronological order',async()=>{
  const db=database(),actor={userId:42};
  const conversation=await createConversation(actor,db,{purpose:'writing'});
  for(let i=0;i<52;i++)await appendUserMessage(actor,db,conversation.conversation_id,String(i));
  const messages=await listRecentConversationMessages(actor,db,conversation.conversation_id);
  assert.equal(messages.length,50);assert.equal(messages[0].sequence_no,3);assert.equal(messages.at(-1).sequence_no,52);
});

test('message history is not returned after group permission is revoked during retrieval', async () => {
  const db = database();
  const conversation = await createConversation({ userId: 42 }, db, { purpose: 'group', group_id: 7 });
  db.revokeDuringList = true;
  await assert.rejects(() => listConversationMessages({ userId: 42 }, db, conversation.conversation_id, 0, 10), /403:/);
});

test('append locks owned conversation and persists sequential user messages', async () => {
  const db = database();
  const conversation = await createConversation({ userId: 42 }, db, { purpose: 'knowledge' });
  db.expectLock = true;
  const first = await appendUserMessage({ userId: 42 }, db, conversation.conversation_id, 'hello');
  const second = await appendUserMessage({ userId: 42 }, db, conversation.conversation_id, 'world');
  assert.deepEqual([first.sequence_no, second.sequence_no], [1, 2]);
  assert.deepEqual(db.messages.map(m => m.content), ['hello', 'world']);
  await assert.rejects(() => appendUserMessage({ userId: 9 }, db, conversation.conversation_id, 'private'), /404:会话不存在/);
  assert.equal(db.messages.length, 2);
});

test('append rolls back when a group administrator loses access before commit', async () => {
  const db = database();
  const conversation = await createConversation({ userId: 42 }, db, { purpose: 'group', group_id: 7 });
  db.revokeAfterMessage = true;
  await assert.rejects(() => appendUserMessage({ userId: 42 }, db, conversation.conversation_id, 'hello'), /403:需要群管理员权限/);
  assert.equal(db.messages.length, 0);
  assert.equal(db.rollbacks, 1);
});

test('append rejects empty or excessive messages', async () => {
  const db = database();
  const conversation = await createConversation({ userId: 42 }, db, { purpose: 'knowledge' });
  await assert.rejects(() => appendUserMessage({ userId: 42 }, db, conversation.conversation_id, ''), /400:/);
  await assert.rejects(() => appendUserMessage({ userId: 42 }, db, conversation.conversation_id, 'x'.repeat(65537)), /400:/);
  await assert.rejects(() => appendUserMessage({ userId: 42 }, db, conversation.conversation_id, '猫'.repeat(21846)), /400:/);
  assert.equal(db.messages.length, 0);
});

test('append reports an uncertain commit as failure without claiming rollback', async () => {
  const db = database();
  const conversation = await createConversation({ userId: 42 }, db, { purpose: 'knowledge' });
  db.failCommit = true;
  await assert.rejects(() => appendUserMessage({ userId: 42 }, db, conversation.conversation_id, 'hello'), error => error.message === '500:internal');
  assert.equal(db.rollbacks, 0);
});

test('assistant message records model revision and rejects stale conversation history', async () => {
  const db=database(), actor={userId:42};
  const conversation=await createConversation(actor,db,{purpose:'writing'});
  const user=await appendUserMessage(actor,db,conversation.conversation_id,'draft');
  const answer=await appendAssistantMessage(actor,db,conversation.conversation_id,{content:'result',expectedSequence:user.sequence_no,modelId:'profile-a',configRevision:12});
  assert.equal(answer.sequence_no,2);assert.equal(answer.role,'assistant');
  assert.equal(db.messages[1].model_id,'profile-a');assert.equal(db.messages[1].config_revision,12);
  const history=await listConversationMessages(actor,db,conversation.conversation_id,1,10);
  assert.equal(history[0].role,'assistant');assert.equal(history[0].model_id,'profile-a');assert.equal(history[0].config_revision,12);
  await assert.rejects(()=>appendAssistantMessage(actor,db,conversation.conversation_id,{content:'stale',expectedSequence:1,modelId:'profile-a',configRevision:12}),/409:/);
  assert.equal(db.messages.length,2);assert.equal(db.rollbacks,1);
});

test('assistant message rejects invalid configuration metadata and revoked access', async () => {
  const db=database(),actor={userId:42};
  const conversation=await createConversation(actor,db,{purpose:'group',group_id:7});
  const user=await appendUserMessage(actor,db,conversation.conversation_id,'draft');
  await assert.rejects(()=>appendAssistantMessage(actor,db,conversation.conversation_id,{content:'x',expectedSequence:user.sequence_no,modelId:'profile-a',configRevision:1000000000000000}),/400:/);
  db.revokeAfterMessage=true;
  await assert.rejects(()=>appendAssistantMessage(actor,db,conversation.conversation_id,{content:'x',expectedSequence:user.sequence_no,modelId:'profile-a',configRevision:1}),/403:/);
  assert.equal(db.messages.length,1);
});

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
