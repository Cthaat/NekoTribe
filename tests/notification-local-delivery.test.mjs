import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFileSync} from 'node:fs';
import {Readable} from 'node:stream';
import {createEvent} from 'h3';

const policy = JSON.parse(readFileSync(new URL('../specifications/requirements/moderation-publish-policy.json', import.meta.url)));
import {createRequire} from 'node:module';
import {fileURLToPath,pathToFileURL} from 'node:url';
import path from 'node:path';
import {build} from 'esbuild';
console.log = () => {};
const root=fileURLToPath(new URL('../',import.meta.url));
const require=createRequire(import.meta.url);
const stubs={
  '#imports':'export const useRuntimeConfig=()=>({});',
  '~/server/storage':'export const normalizeAvatarPublicUrl=value=>value; export const normalizeNullableStoragePublicUrl=value=>value; export const normalizeStoragePublicUrl=value=>value;',
  '~/server/utils/redis':'export const REDIS_CHANNELS={USER_MESSAGE:"ws:user:"}; export const publishMessage=async(channel,message)=>globalThis.__localNotification.push({channel,message});',
  './api-cache':'export const readApiResponseCache=async()=>({status:"disabled"}); export const writeApiResponseCache=async()=>{}; export const invalidateApiResponseCache=async()=>{}; export const shouldInvalidateApiResponseCache=()=>false;',
  './logging':'export const getRequestLogContext=()=>null; export const logError=()=>{}; export const logInfo=()=>{}; export const serializeLogError=()=>({});',
  oracledb:'export default {OUT_FORMAT_OBJECT:4002};'
};
const bundle=await build({stdin:{contents:`export {v2PublishNotificationEvent} from './server/services/v2/notifications'; export {v2ListDirectConversations,v2ListDirectMessages,v2CreateDirectMessage,v2DeleteDirectMessage,v2CreateDirectConversation,v2CreateChatMessage,v2UpdateChatMessage} from './server/services/v2/chat'; export {sessionManager} from './server/utils/wsSession';`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'local-notification-stubs',setup(builder){
  builder.onResolve({filter:/.*/},args=>{if(Object.hasOwn(stubs,args.path))return {path:args.path,namespace:'stub'};if(args.path.startsWith('~/'))return {path:path.join(root,`${args.path.slice(2)}.ts`)};if(args.path.startsWith('node:'))return {path:args.path,external:true};if(!args.path.startsWith('.')&&!path.isAbsolute(args.path))return {path:pathToFileURL(require.resolve(args.path)).href,external:true};});
  builder.onLoad({filter:/.*/,namespace:'stub'},args=>({contents:stubs[args.path],loader:'js'}));
}}]});
const subject=await import(`data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`);

test('conversation lookup binds the viewer and filters before pagination', async () => {
  const eventFor = query => {
    const request = Readable.from([]);
    request.url = '/api/v2/chat/direct-conversations?' + query;
    const event = createEvent(request, {});
    event.context.auth = { userId: 42 };
    return event;
  };
  const connection = {
    async execute(sql, binds) {
      assert.match(sql, /user_low_id = :viewer_id OR c.user_high_id = :viewer_id/);
      assert.match(sql, /c.conversation_id = :conversation_id/);
      assert.deepEqual(binds, { viewer_id: 42, conversation_id: 7, start_row: 1, end_row: 1 });
      return { rows: [{ CONVERSATION_ID: 7, USER_ID: 9, TOTAL: 1 }] };
    }
  };
  const result = await subject.v2ListDirectConversations(eventFor('conversation_id=%37&page_size=1'), connection);
  assert.equal(result.data[0].conversation_id, 7);
  assert.equal(result.meta.total, 1);
  for (const query of ['conversation_id=', 'conversation_id=07', 'conversation_id=7&conversation_id=7']) {
    await assert.rejects(subject.v2ListDirectConversations(eventFor(query), connection), { statusCode: 400 });
  }
});

test('direct deletion scopes writes, repairs the summary and redacts notifications before commit', async () => {
 const contract=JSON.parse(readFileSync(new URL('../specifications/requirements/direct-message-delete.json',import.meta.url)));
 for(const mode of ['success','already-deleted','non-author','summary-failure']) {
  const event=createEvent(Readable.from([]),{});event.context.auth={userId:42};
  const writes=[];
  const connection={
   async execute(sql,binds,options){
    if(sql===contract.lockConversation){assert.deepEqual(binds,{conversation_id:7,user_id:42});return {rows:[{RECIPIENT:43}]};}
    if(sql===contract.lockMessage){assert.deepEqual(binds,{conversation_id:7,message_id:9});return {rows:[{SENDER_ID:mode==='non-author'?43:42,IS_DELETED:mode==='already-deleted'?1:0}]};}
    assert.equal(options.autoCommit,false);
    if(sql===contract.deleteMessage){assert.deepEqual(binds,{conversation_id:7,message_id:9,user_id:42});writes.push('message');}
    else if(sql===contract.refreshConversation){assert.deepEqual(binds,{conversation_id:7});writes.push('summary');if(mode==='summary-failure')return {rowsAffected:0};}
    else if(sql===contract.redactNotification){assert.deepEqual(binds,{message_id:9,user_id:42});writes.push('notification');}
    else assert.fail('unexpected statement');
    return {rowsAffected:1};
   },
   async commit(){writes.push('commit')},async rollback(){writes.push('rollback')},
  };
  const call=()=>subject.v2DeleteDirectMessage(event,connection,7,9);
  globalThis.__localNotification=[];
  try {
   if(mode==='non-author')await assert.rejects(call,{statusCode:403});
   else if(mode==='summary-failure')await assert.rejects(call,/unexpected number/);
   else assert.deepEqual(await call(),{code:200,message:'direct message deleted',data:null,meta:null});
   assert.deepEqual(globalThis.__localNotification.map(item=>[item.channel,item.message.type]),mode==='success'?
    [['ws:user:42','direct_message_deleted'],['ws:user:43','direct_message_deleted']]:[]);
  } finally { delete globalThis.__localNotification; }
  assert.deepEqual(writes,mode==='success'?['message','summary','notification','commit']:
   mode==='summary-failure'?['message','summary','rollback']:['rollback']);
 }
});

test('creating a conversation reuses the concurrent winner and never restores a deleted pair', async () => {
  const {createEvent} = await import('h3');
  const {Readable} = await import('node:stream');
  for (const deleted of [0,1]) {
    const payload = Buffer.from('{"target_user_id":9}');
    const req = Readable.from([payload]);
    req.method = 'POST';
    req.headers = {'content-type':'application/json','content-length':String(payload.length)};
    const event = createEvent(req, {});
    event.context.auth = {userId:42};
    let reads = 0;
    const connection = {async execute(sql, binds) {
      if (sql.includes('allow_dm_from_strangers')) return {rows:[{RELATION:'mutual_follow'}]};
      if (sql.includes('SELECT conversation_id, is_deleted')) {
        assert.deepEqual(binds,{user_low_id:9,user_high_id:42});
        return {rows:++reads===1 ? [] : [{CONVERSATION_ID:7,IS_DELETED:deleted}]};
      }
      if (sql.includes('seq_direct_conversation_id')) return {rows:[{ID:8}]};
      if (sql.includes('INSERT INTO n_direct_conversations')) throw Object.assign(Error('fixture unique collision'), {errorNum:1});
      assert.equal(binds.conversation_id,7);
      return {rows:[{CONVERSATION_ID:7,USER_ID:9}]};
    }};
    if (deleted) {
      await assert.rejects(subject.v2CreateDirectConversation(event, connection), {statusCode:409});
    } else {
      assert.equal((await subject.v2CreateDirectConversation(event, connection)).data.conversation_id,7);
    }
    assert.equal(reads,2);
  }
});

test('local notification publication checks sessions before delivery and still publishes to Redis',async()=>{
  globalThis.__localNotification=[];
  const peer={messages:[],closed:0,send(value){this.messages.push(JSON.parse(value));},close(){this.closed++;}};
  let active=true;
  subject.sessionManager.addSession('local-session',peer,{userId:42,sessionId:'auth',jti:'jti',type:'access'},async()=>active);
  try {
    await subject.v2PublishNotificationEvent({},42,'notification_created',{id:7});
    assert.equal(peer.messages.length,1);
    assert.equal(globalThis.__localNotification.length,1);
    active=false;
    await subject.v2PublishNotificationEvent({},42,'notification_created',{id:8});
    assert.equal(peer.messages.length,1);
    assert.equal(peer.closed,1);
    assert.equal(globalThis.__localNotification.length,2);
  } finally { subject.sessionManager.removeSession('local-session'); delete globalThis.__localNotification; }
});

test('direct history shares the conversation lock and never rewinds the cursor', async () => {
  for (const mode of ['first', 'empty', 'failure']) {
    const event = createEvent(Readable.from([]), {});
    event.context.auth = {userId:42};
    const actions = [];
    const connection = {
      async execute(sql, binds, options) {
        if (sql.includes('FROM n_direct_conversations')) {
          assert.match(sql, /FOR UPDATE/);
          assert.deepEqual(binds, {conversation_id:7, user_id:42});
          actions.push('lock');
          return {rows:[{USER_LOW_ID:9, USER_HIGH_ID:42}]};
        }
        if (sql.includes('COUNT(*)')) return {rows:[{TOTAL:1}]};
        if (sql.includes('FROM n_direct_messages dm')) {
          return {rows: mode === 'empty' ? [] : [{MESSAGE_ID:10, CONVERSATION_ID:7, USER_ID:9}]};
        }
        assert.match(sql, /GREATEST\(NVL\(r\.last_read_message_id, 0\), src\.last_read_message_id\)/);
        assert.equal(options.autoCommit, false);
        assert.equal(binds.last_read_message_id, 10);
        actions.push('mark');
        if (mode === 'failure') throw Error('read marker unavailable');
        return {rowsAffected:1};
      },
      async commit() { actions.push('commit'); },
      async rollback() { actions.push('rollback'); },
    };
    if (mode === 'failure') {
      await assert.rejects(() => subject.v2ListDirectMessages(event, connection, 7), /marker unavailable/);
      assert.deepEqual(actions, ['lock','mark','rollback']);
    } else {
      const result = await subject.v2ListDirectMessages(event, connection, 7);
      assert.deepEqual(result.data.map(message => message.message_id), mode === 'empty' ? [] : [10]);
      assert.deepEqual(actions, mode === 'empty' ? ['lock','commit'] : ['lock','mark','commit']);
    }
  }
});

test('direct send rolls back all writes and only delivers after commit', async () => {
  for (const failure of ['muted', 'MERGE INTO n_direct_conversation_reads', 'INSERT INTO n_notifications', 'commit', 'push-disabled', null]) {
    globalThis.__localNotification = [];
    const writes = [];
    const req = Readable.from([Buffer.from('{"content":" hello "}')]);
    req.method = 'POST';
    req.headers = {'content-type':'application/json','content-length':'21'};
    const event = createEvent(req, {});
    event.context.auth = {userId:42};
    let committed = false, rolledBack = false;
    const connection = {
      async execute(sql, binds, options) {
        const text = sql.trim();
        if (/^(INSERT|UPDATE|MERGE)/.test(text)) {
          assert.equal(options.autoCommit, false);
          writes.push(text);
          assert.equal(globalThis.__localNotification.length, 0);
          if (failure && text.startsWith(failure)) throw Error('fixture write failed');
          return {rowsAffected:1};
        }
        if (text.includes('FROM n_direct_conversations') && text.includes('FOR UPDATE')) return {rows:[{USER_LOW_ID:9,USER_HIGH_ID:42}]};
        if (text.includes('allow_dm_from_strangers')) return {rows:[{RELATION:'mutual_follow'}]};
        if (text === policy.sql.lock) return {rows:[{USER_ID:42}]};
        if (text === policy.sql.allowed) return {rows:[{ALLOWED:failure === 'muted' ? 0 : 1}]};
        if (text.includes('seq_direct_message_id')) return {rows:[{ID:12}]};
        if (text.includes('FROM n_direct_messages dm')) return {rows:[{MESSAGE_ID:12,CONVERSATION_ID:7,USER_ID:42,CONTENT:'hello'}]};
        if (text.includes(' AS name')) return {rows:[{NAME:'fixture'}]};
        if (text.includes('notification_preferences')) return {rows:[{TYPE_ENABLED:1,PUSH_NOTIFICATION_ENABLED:failure === 'push-disabled' ? 0 : 1}]};
        if (text.includes('seq_notification_id')) return {rows:[{ID:13}]};
        if (text.includes('FROM n_notifications')) return {rows:[{NOTIFICATION_ID:13}]};
        throw Error('unexpected SQL: '+text);
      },
      async commit() {
        assert.equal(writes.length, 4);
        assert.equal(globalThis.__localNotification.length, 0);
        if (failure === 'commit') throw Error('fixture commit failed');
        committed = true;
      },
      async rollback() { rolledBack = true; }
    };
    try {
      if (failure === 'muted') {
        await assert.rejects(subject.v2CreateDirectMessage(event, connection, 7), error => error.statusCode === 403 && error.data.message === policy.message);
        assert.equal(rolledBack, true);
        assert.equal(committed, false);
        assert.deepEqual(writes, []);
        assert.deepEqual(globalThis.__localNotification, []);
      } else if (failure && failure !== 'push-disabled') {
        await assert.rejects(subject.v2CreateDirectMessage(event, connection, 7), /fixture .* failed/);
        assert.equal(rolledBack, true);
        assert.deepEqual(globalThis.__localNotification, []);
      } else {
        const result = await subject.v2CreateDirectMessage(event, connection, 7);
        assert.equal(result.data.message_id,12);
        assert.equal(committed,true);
        const direct = globalThis.__localNotification.filter(item=>item.message.type==='direct_message');
        assert.deepEqual(direct.map(item=>item.channel).sort(), ['ws:user:42','ws:user:9']);
        const notices = globalThis.__localNotification.filter(item=>item.message.type==='notification_created');
        assert.deepEqual(notices.map(item=>item.channel), failure === 'push-disabled' ? [] : ['ws:user:9']);
      }
    } finally { delete globalThis.__localNotification; }
  }
});

test('channel sends and edits roll back on an active account mute', async () => {
  for (const [action, method, id] of [
    ['v2CreateChatMessage', 'POST', 7],
    ['v2UpdateChatMessage', 'PATCH', 8]
  ]) {
    const payload = Buffer.from('{"content":"hello"}');
    const req = Readable.from([payload]);
    req.method = method;
    req.headers = {'content-type': 'application/json', 'content-length': String(payload.length)};
    const event = createEvent(req, {});
    event.context.auth = {userId: 42};
    const checks = [];
    const connection = {
      async execute(raw, binds) {
        const sql = raw.replace(/\s+/g, ' ').trim();
        if (sql === policy.sql.lock || sql === policy.sql.allowed) {
          assert.deepEqual(binds, {user_id: 42});
          checks.push(sql);
          return {rows: sql === policy.sql.lock ? [{USER_ID: 42}] : [{ALLOWED: 0}]};
        }
        if (sql.startsWith('SELECT channel_id FROM n_chat_messages')) return {rows: [{CHANNEL_ID: 7}]};
        if (sql.startsWith('SELECT group_id FROM n_groups')) return {rows: [{GROUP_ID: 6}]};
        if (sql.startsWith('SELECT author_id, message_type')) return {rows: [{AUTHOR_ID: 42, MESSAGE_TYPE: 'text'}]};
        if (sql.includes('FROM n_chat_channels c')) {
          return {rows: [{GROUP_ID: 6, ROLE: 'member', STATUS: 'active', CHANNEL_TYPE: 'text', CAN_MANAGE: 0, IS_PRIVATE: 0}]};
        }
        assert.fail('unexpected query or write after moderation denial: ' + sql);
      },
      async rollback() { checks.push('rollback'); },
      async commit() { assert.fail('denied content was committed'); }
    };
    globalThis.__localNotification = [];
    try {
      await assert.rejects(subject[action](event, connection, id), error => error.statusCode === 403 && error.data.message === policy.message);
      assert.deepEqual(checks, [policy.sql.lock, policy.sql.allowed, 'rollback']);
      assert.deepEqual(globalThis.__localNotification, []);
    } finally { delete globalThis.__localNotification; }
  }
});
