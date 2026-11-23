import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import policy from '../specifications/requirements/chat-realtime-details.json' with {type:'json'};
import extras from '../specifications/requirements/direct-message-extras.json' with {type:'json'};
const {sql} = policy;

const built = await build({
  stdin: {
    contents: `export {v2ReadDirectChatStatus,v2SetDirectChatStatus,v2ListDirectMessages} from './server/services/v2/chat';
      export {chatMessageSearch} from './server/services/v2/chat-message-search';`,
    resolveDir: fileURLToPath(new URL('../', import.meta.url)),
  },
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{ name:'direct-read-oracle-fixture', setup(builder) {
    const stubs = {
      'h3': `export const getQuery = event => event.query, readRawBody = event => JSON.stringify(event.body),
               setResponseHeader = (event,name,value) => event.headers[name]=value;`,
      './moderation-publish-policy': `export const requirePublishAccess = () => {};`,
      './notifications': `export const v2DeliverStoredNotification = () => {}, v2StoreNotification = () => {};`,
      './private-media-binding': `export const canBindMedia = () => true;`,
      '~/server/database/readiness': `export const requireFeatureSchema = () => {};`,
      '~/server/storage': `export const normalizeStoragePublicUrl = value => value;`,
      '~/server/storage/local-path': `export const normalizeLocalStorageKey = value => value;`,
      '~/server/models/v2': `export const v2MapMedia = row => row, v2MapPublicUser = row => row;`,
      '~/server/utils/auth-entry-errors': `export const v2ServiceUnavailable = () => {};`,
      '~/server/utils/redis': `export const REDIS_CHANNELS = {USER_MESSAGE:'user:'};
        export const publishMessage = (channel,frame) => globalThis.__readEvents.push([channel,frame]);`,
      '~/server/utils/wsSession': `export const WS_SERVER_ID='fixture', sendWsToRoom=()=>{}, sendWsToUser=()=>{};`,
      '~/server/utils/v2': `
        const fail = statusCode => { throw Object.assign(new Error(), {statusCode}); };
        export const v2Auth = event => ({userId:event.userId}), v2RouterParam = (event,key) => event.params[key];
        export const v2One = (db,query,binds) => db.row(query,binds), v2Execute = (db,query,binds,autoCommit) => db.write(query,binds,autoCommit);
        export const v2Number = value => Number(value) || 0, v2Ok = (data,_message,meta) => ({data,meta}), v2BadRequest = () => fail(400),
          v2Forbidden = () => fail(403), v2ServerError = () => fail(500), v2NotFound = () => fail(404);
        export const v2Body=()=>{},v2BoolNumber=()=>{},v2Boolean=Boolean,v2Conflict=()=>{},v2DateString=value=>value??null,v2NextId=()=>{},
          v2Null=()=>{},v2QueryString=()=>{},v2RequiredString=()=>{},v2String=value=>String(value??'');
        export const v2Page=()=>({page:1,page_size:20,start:1,end:20}),v2PageMeta=(page,page_size,total)=>({page,page_size,total}),
          v2Count=(db,query,binds)=>db.count(query,binds),v2Rows=(db,query,binds)=>db.rows(query,binds);
      `,
    };
    builder.onResolve({filter:/.*/}, ({path}) => Object.hasOwn(stubs,path) ? {path,namespace:'fixture'} : undefined);
    builder.onLoad({filter:/.*/,namespace:'fixture'}, ({path}) => ({contents:stubs[path]}));
  }}],
});
const api = await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);

test('combined direct filters produce one scoped predicate for count and page and leave the cursor untouched', async () => {
  const query = { q:'  中文 %_  ', sender_id:'43', start_at:'2026-09-21T08:00:00+08:00', end_at:'2026-09-22T00:00:00Z' };
  const predicates = api.chatMessageSearch(query, 'direct');
  assert.deepEqual(predicates.binds, {search_keyword:'中文 %_',search_sender:43,
    search_start:'2026-09-21T00:00:00.000+00:00',search_end:'2026-09-22T00:00:00.000+00:00'});
  assert.match(predicates.where, /dm\.sender_id/);
  assert.match(api.chatMessageSearch({sender_id:'43'},'channel').where,/m\.author_id/);
  const seen = [];
  const db = {
    row(statement, binds) {
      assert.doesNotMatch(statement, /FOR UPDATE/);
      assert.equal(binds.conversation_id, 7);
      return binds.user_id === 42 ? {USER_LOW_ID:42,USER_HIGH_ID:43} : null;
    },
    count(statement, binds) {
      seen.push('count');
      assert(statement.includes(predicates.where));
      assert.deepEqual(binds,{conversation_id:7,...predicates.binds});
      return 1;
    },
    rows(statement, binds) {
      if ([extras.sql.list_media,extras.sql.list_replies,extras.sql.list_reactions].includes(statement)) return [];
      seen.push('page');
      assert(statement.includes(predicates.where));
      for (const [key,value] of Object.entries(predicates.binds)) assert.equal(binds[key],value);
      return [{MESSAGE_ID:61,CONVERSATION_ID:7,USER_ID:43,CONTENT:'中文 %_',IS_DELETED:0}];
    },
    write() { assert.fail('Search must not advance the cursor'); },
    commit() {}, rollback() {},
  };
  const result = await api.v2ListDirectMessages({userId:42, query},db,7);
  assert.deepEqual(seen,['count','page']);
  assert.equal(result.data[0].message_id,61);
  assert.equal(result.meta.total,1);
  await assert.rejects(api.v2ListDirectMessages({userId:99, query},db,7),{statusCode:403});
  for (const invalid of [{ sender_id:'0' },{ start_at:'2026-02-31T00:00:00Z' },
    {start_at:query.end_at,end_at:query.start_at}]) {
    assert.throws(()=>api.chatMessageSearch(invalid,'direct'), {statusCode:400});
  }
});
test('the explicit direct cursor advances once, after membership and exact message checks', async t => {
  const events = globalThis.__readEvents = [];
  t.after(() => delete globalThis.__readEvents);
  let cursor = null, commits = 0;
  const db = {
    row(query, binds) {
      assert.equal(binds.conversation_id, 7);
      if (query === extras.sql.query_message) return [11, 12].includes(binds.message_id) ? { MESSAGE_ID: binds.message_id } : null;
      if (binds.user_id !== 42) return null;
      if (query === sql.read_status) return { LAST_READ_MESSAGE_ID:cursor, PARTICIPANT_LAST_READ_MESSAGE_ID:10, UNREAD_COUNT:cursor === null ? 4 : 2 };
      assert.match(query, /FOR UPDATE/);
      return { USER_LOW_ID:42, USER_HIGH_ID:43 };
    },
    write(query, binds, autoCommit) {
      assert.equal(query, sql.advance_read);
      assert.equal(autoCommit, false);
      if ((cursor ?? 0) >= binds.last_read_message_id) return 0;
      cursor = binds.last_read_message_id;
      return 1;
    },
    commit() { commits++; assert.equal(events.length, commits === 1 ? 0 : 2); },
    rollback() {},
  };
  const request = (id, userId = 42) => ({userId,params:{conversation_id:'7'},body:{last_read_message_id:id},headers:{}});
  assert.deepEqual((await api.v2ReadDirectChatStatus(request(null),db)).data, {
    conversation_id:7,last_read_message_id:null,participant_last_read_message_id:10,unread_count:4,
  });
  assert.equal((await api.v2SetDirectChatStatus(request(12),db)).data.last_read_message_id,12);
  assert.equal((await api.v2SetDirectChatStatus(request(11),db)).data.last_read_message_id,12);
  assert.deepEqual(events.map(([channel,frame])=>[channel,frame.type,frame.data.reader_id,frame.data.last_read_message_id]),
    [['user:42','direct_read_updated',42,12],['user:43','direct_read_updated',42,12]]);
  await assert.rejects(api.v2SetDirectChatStatus(request(99),db),{statusCode:400});
  await assert.rejects(api.v2SetDirectChatStatus(request(12,9),db),{statusCode:403});
  assert.equal(commits,2);
});
