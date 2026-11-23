import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {createEvent} from 'h3';
import {IncomingMessage,ServerResponse} from 'node:http';
import {Socket} from 'node:net';
import {fileURLToPath} from 'node:url';

const root=fileURLToPath(new URL('../',import.meta.url));
const compiled=await build({stdin:{contents:`
 export {readApiResponseCache,writeApiResponseCache} from './server/utils/api-cache';
 export {attachOracleQueryCacheWithSource} from './server/utils/oracle-query-cache';
`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'logs',setup(b){
 b.onResolve({filter:/^\.\/logging$/},()=>({path:'logging',namespace:'stub'}));
 b.onLoad({filter:/.*/,namespace:'stub'},()=>({contents:'export const getRequestLogContext=()=>null;export const logInfo=()=>{};export const logWarn=()=>{};export const serializeLogError=()=>({});',loader:'js'}));
 }}]});
const moduleUrl=`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`;
async function moduleFor(mode,id) {if(mode===undefined)delete process.env.NEKO_CACHE_MODE;else process.env.NEKO_CACHE_MODE=mode;return import(`${moduleUrl}#${id}`)}
function eventFor(redis) {const socket=new Socket(),req=new IncomingMessage(socket),res=new ServerResponse(req);req.url='/api/v2/tags';req.method='GET';req.headers.host='localhost';const event=createEvent(req,res);event.context.redis=redis;event.context.auth={userId:42};return {event,close(){res.destroy();socket.destroy()}}}
function fakeRedis(){
 const values=new Map();let reads=0;
 return {
  get reads(){return reads},
  async mget(...keys){reads++;return keys.map(k=>values.get(k)??null)},
  async get(key){reads++;return values.get(key)??null},
  async set(key,value,_expiry,_seconds,condition){
   if(condition==='NX'&&values.has(key))return null;
   values.set(key,value);return 'OK';
  },
  async incr(k){const value=Number(values.get(k)??0)+1;values.set(k,String(value));return value},
  async del(k){values.delete(k)},
  evictTags(){
   for(const key of values.keys())if(key.startsWith('nt:api-cache-tag:')||key.startsWith('nt:oracle-query-cache-tag:'))values.delete(key);
  },
  pipeline(){
   const actions=[];
   return {
    set(k,v){actions.push(()=>{values.set(k,v);return 'OK'});return this},
    expire(){return this},
    incr(k){actions.push(()=>values.set(k,String(Number(values.get(k)??0)+1)));return this},
    async exec(){return actions.map(fn=>[null,fn()])},
   };
  },
 };
}

test('settings and private message reads bypass Oracle query cache in single-backend mode',async()=>{
 const original=process.env.NEKO_CACHE_MODE;try {
  const m=await moduleFor('single-backend','settings-private');
  for(const pathname of ['/api/v2/auth/registration','/api/v2/auth/registration/?fresh=1','/api/v2/users/me/settings','/api/v2/users/me/settings/?fresh=1','/api/v2/chat/direct-conversations/7/messages?page=1','/api/v2/chat/groups/7/members','/api/v2/chat/channels/7/read-status','/api/v2/chat/channels/7/mute-status','/api/v2/chat/channels/7/messages','/api/v2/chat/messages/8','/api/v2/chat/messages/8/pin-status','/api/v2/groups/7/members/9/approval-status','/api/v2/groups/7/members/8','/api/v2/groups/7/ownership','/other']) {
   const redis=fakeRedis();let count=0;
   const conn=m.attachOracleQueryCacheWithSource({redis,authUserId:42,path:pathname},{async execute(){return {rows:[{VALUE:++count}]}}});
   const queries=pathname==='/other'?['SELECT * FROM n_user_settings']:['SELECT * FROM n_user_settings','SELECT table_name FROM user_tables'];
   for(const sql of queries){const first=await conn.execute(sql),second=await conn.execute(sql);assert.notEqual(first.rows[0].VALUE,second.rows[0].VALUE,pathname+' '+sql);}
   assert.equal(redis.reads,0,pathname);
  }
 } finally {if(original===undefined)delete process.env.NEKO_CACHE_MODE;else process.env.NEKO_CACHE_MODE=original}
});

test('AI content and authorization queries never use Oracle cache',async()=>{
 const original=process.env.NEKO_CACHE_MODE;try {
  const m=await moduleFor('single-backend','ai-private');const redis=fakeRedis();let calls=0;
  const conn=m.attachOracleQueryCacheWithSource({redis,authUserId:42,path:'/api/v2/ai/conversations/1/messages'},{async execute(){return {rows:[{VALUE:++calls}]}}});
  for(const sql of ['SELECT content FROM n_ai_messages','SELECT fn_has_group_permission(:user_id,:group_id,:role) FROM dual','SELECT username FROM n_users']) {
   const first=await conn.execute(sql),second=await conn.execute(sql);assert.notEqual(first.rows[0].VALUE,second.rows[0].VALUE);
  }
  assert.equal(redis.reads,0);
  const direct=m.attachOracleQueryCacheWithSource({redis,authUserId:42,path:'/other'},{async execute(){return {rows:[{VALUE:++calls}]}}});
  for(const sql of ['SELECT content FROM n_ai_messages','SELECT fn_has_group_permission(:user_id,:group_id,:role) FROM dual']) {
   const first=await direct.execute(sql),second=await direct.execute(sql);assert.notEqual(first.rows[0].VALUE,second.rows[0].VALUE);
  }
  assert.equal(redis.reads,0);
 } finally {if(original===undefined)delete process.env.NEKO_CACHE_MODE;else process.env.NEKO_CACHE_MODE=original}
});

test('default shared mode bypasses both cache layers for external writes',async()=>{
 const original=process.env.NEKO_CACHE_MODE;try {
  const m=await moduleFor(undefined,'shared');const redis=fakeRedis(),{event,close}=eventFor(redis);
  try {const res=await m.readApiResponseCache(event,'v2');assert.equal(res.status,'bypass');assert.equal(redis.reads,0);
   let profile='old';let calls=0;const db={async execute(){calls++;return {rows:[{DISPLAY_NAME:profile}]}}};
   const conn=m.attachOracleQueryCacheWithSource({redis,authUserId:42},db);
   assert.equal((await conn.execute('SELECT display_name FROM n_users')).rows[0].DISPLAY_NAME,'old');profile='new';
   assert.equal((await conn.execute('SELECT display_name FROM n_users')).rows[0].DISPLAY_NAME,'new');assert.equal(calls,2);assert.equal(redis.reads,0);
  } finally {close()}
 } finally {if(original===undefined)delete process.env.NEKO_CACHE_MODE;else process.env.NEKO_CACHE_MODE=original}
});

test('single-backend opt-in uses cache and a restart cannot reuse previous process entries',async()=>{
 const original=process.env.NEKO_CACHE_MODE;try {
  const a=await moduleFor('single-backend','single-a');const redis=fakeRedis(),{event,close}=eventFor(redis);
  try {const first=await a.readApiResponseCache(event,'v2');assert.equal(first.status,'miss');await a.writeApiResponseCache(event,first.context,{value:'old'});assert.equal((await a.readApiResponseCache(event,'v2')).status,'hit');
   let current='old';let calls=0;const db={async execute(){calls++;return {rows:[{VALUE:current}]}}};const conn=a.attachOracleQueryCacheWithSource({redis},db);
   await conn.execute('SELECT value FROM n_users');current='new';assert.equal((await conn.execute('SELECT value FROM n_users')).rows[0].VALUE,'old');assert.equal(calls,1);
   const b=await moduleFor('single-backend','single-b');assert.equal((await b.readApiResponseCache(event,'v2')).status,'miss');const next={async execute(){return {rows:[{VALUE:'new'}]}}};assert.equal((await b.attachOracleQueryCacheWithSource({redis},next).execute('SELECT value FROM n_users')).rows[0].VALUE,'new');
  }finally{close()}
 }finally{if(original===undefined)delete process.env.NEKO_CACHE_MODE;else process.env.NEKO_CACHE_MODE=original}
});

test('evicted tags cannot make cached payloads current again',async()=>{
 const original=process.env.NEKO_CACHE_MODE;
 const m=await moduleFor('single-backend','eviction');
 const redis=fakeRedis(),{event,close}=eventFor(redis);
 try {
  const first=await m.readApiResponseCache(event,'v2');
  assert.equal(first.status,'miss');
  await m.writeApiResponseCache(event,first.context,{value:'old'});
  assert.equal((await m.readApiResponseCache(event,'v2')).status,'hit');
  let current='old';
  const conn=m.attachOracleQueryCacheWithSource({redis},{async execute(){return {rows:[{VALUE:current}]}}});
  const sql='SELECT value FROM n_users';
  assert.equal((await conn.execute(sql)).rows[0].VALUE,'old');
  current='new';
  assert.equal((await conn.execute(sql)).rows[0].VALUE,'old');
  redis.evictTags();
  assert.equal((await m.readApiResponseCache(event,'v2')).status,'miss');
  assert.equal((await conn.execute(sql)).rows[0].VALUE,'new');
 } finally {
  close();
  if(original===undefined)delete process.env.NEKO_CACHE_MODE;else process.env.NEKO_CACHE_MODE=original;
 }
});

test('transaction reads stay local and tag rotation follows commit',async()=>{
 const original=process.env.NEKO_CACHE_MODE;
 const m=await moduleFor('single-backend','transaction');
 const redis=fakeRedis();
 const source={redis};
 let stored='old', pending=null;
 let committedReads=0;
 const read='SELECT value FROM n_users';
 const write='UPDATE n_users SET value = :value';
 const readResult=value=>({rows:[{VALUE:value}]});
 const reader=m.attachOracleQueryCacheWithSource(source,{
  async execute(){committedReads++;return readResult(stored)},
 });
 const writer=m.attachOracleQueryCacheWithSource(source,{
  get transactionInProgress(){return pending!==null},
  async execute(sql,binds,options){
   if(sql===read)return readResult(pending??stored);
   pending=binds.value;
   if(options?.autoCommit)await this.commitRaw();
   return {rowsAffected:1};
  },
  async commitRaw(){stored=pending??stored;pending=null},
  async commit(){await this.commitRaw()},
  async rollback(){pending=null},
 });
 async function value(conn){return (await conn.execute(read)).rows[0].VALUE}
 try {
  assert.equal(await value(reader),'old');
  await writer.execute(write,{value:'rolled-back'});
  assert.equal(await value(writer),'rolled-back');
  assert.equal(await value(reader),'old');
  assert.equal(committedReads,1);
  await writer.rollback();
  assert.equal(await value(reader),'old');
  assert.equal(committedReads,1);
  await writer.execute(write,{value:'committed'});
  await writer.commit();
  assert.equal(await value(reader),'committed');
  await writer.execute(write,{value:'auto-committed'},{autoCommit:true});
  assert.equal(await value(reader),'auto-committed');
  assert.equal(committedReads,3);
 } finally {
  if(original===undefined)delete process.env.NEKO_CACHE_MODE;else process.env.NEKO_CACHE_MODE=original;
 }
});

test('unrecognized mode stays safe and mode is fixed at process initialization',async()=>{
 const original=process.env.NEKO_CACHE_MODE;try {
  const m=await moduleFor('unexpected','invalid');process.env.NEKO_CACHE_MODE='single-backend';
  const redis=fakeRedis(),{event,close}=eventFor(redis);try {assert.equal((await m.readApiResponseCache(event,'v2')).status,'bypass');assert.equal(redis.reads,0)}finally{close()}
 }finally{if(original===undefined)delete process.env.NEKO_CACHE_MODE;else process.env.NEKO_CACHE_MODE=original}
});

test('public profiles bypass internal response cache even in single-backend mode',async()=>{
 const original=process.env.NEKO_CACHE_MODE;try {
  const m=await moduleFor('single-backend','public-privacy');const redis=fakeRedis(),{event,close}=eventFor(redis);
  try {event.node.req.url='/api/v2/users/7';const value=await m.readApiResponseCache(event,'v2');assert.equal(value.status,'bypass');assert.equal(redis.reads,0)}finally{close()}
 }finally{if(original===undefined)delete process.env.NEKO_CACHE_MODE;else process.env.NEKO_CACHE_MODE=original}
});

test('account visibility lists bypass response and Oracle caches in single-backend mode', async () => {
 const original=process.env.NEKO_CACHE_MODE;
 try {
  const m=await moduleFor('single-backend','relationship-privacy');
  for(const kind of ['blocks','mutes']) {
   const redis=fakeRedis(),{event,close}=eventFor(redis);
   try {
    event.node.req.url=`/api/v2/users/me/${kind}?page=1`;
    assert.equal((await m.readApiResponseCache(event,'v2')).status,'bypass');
    let calls=0;
    const conn=m.attachOracleQueryCacheWithSource({redis,authUserId:42},{async execute(){return {rows:[{VALUE:++calls}]}}});
    const query=`SELECT target_user_id FROM n_user_${kind} WHERE user_id = :viewer_id`;
    assert.equal((await conn.execute(query,{viewer_id:42})).rows[0].VALUE,1);
    assert.equal((await conn.execute(query,{viewer_id:42})).rows[0].VALUE,2);
    assert.equal(redis.reads,0);
   } finally {close();}
  }
 } finally {if(original===undefined)delete process.env.NEKO_CACHE_MODE;else process.env.NEKO_CACHE_MODE=original}
});

test('user discovery and relationship reads bypass cached state', async () => {
 const original=process.env.NEKO_CACHE_MODE;
 try {
  const m=await moduleFor('single-backend','follow-privacy');
  for(const path of ['/api/v2/users?q=example','/api/v2/users/recommendations?limit=3','/api/v2/users/me/account-statements?page=2','/api/v2/users/me/drafts?group_id=0','/api/v2/posts/7/poll','/api/v2/users/7/pinned-post','/api/v2/moderation/appeals?page=2',
    '/api/v2/moderation/reports?page=2','/api/v2/moderation/reports/12','/api/v2/reports',
    '/api/v2/moderation/settings','/api/v2/moderation/stats','/api/v2/moderation/users?q=reader',
    '/api/v2/moderation/content?priority=high','/api/v2/posts/27/likes?page=2','/api/v2/posts/27/analytics',
    '/api/v2/users/7/analytics','/api/v2/users/7/analytics/daily?days=7','/api/v2/posts','/api/v2/posts/trending',
    ...['followers','following','mutual-following'].map(kind => `/api/v2/users/9/${kind}?page=2`)]) {
   const redis=fakeRedis(),{event,close}=eventFor(redis);
   try {
    event.node.req.url=path;
    assert.equal((await m.readApiResponseCache(event,'v2')).status,'bypass');
    let calls=0;
    const conn=m.attachOracleQueryCacheWithSource({redis,authUserId:42,path},{async execute(){return {rows:[{VALUE:++calls}]}}});
    const query='SELECT followers_count FROM n_user_stats WHERE user_id = :target_id';
    assert.equal((await conn.execute(query,{target_id:9})).rows[0].VALUE,1);
    assert.equal((await conn.execute(query,{target_id:9})).rows[0].VALUE,2);
    assert.equal(redis.reads,0);
   } finally {close();}
  }
 } finally {if(original===undefined)delete process.env.NEKO_CACHE_MODE;else process.env.NEKO_CACHE_MODE=original}
});

test('viewer-scoped tag analytics bypasses both cache layers in single-backend mode',async()=>{
 const original=process.env.NEKO_CACHE_MODE;try {
  const m=await moduleFor('single-backend','tag-privacy');const redis=fakeRedis(),{event,close}=eventFor(redis);
  try {event.node.req.url='/api/v2/tags/cat/analytics';const result=await m.readApiResponseCache(event,'v2');assert.equal(result.status,'bypass');
   let calls=0;const conn=m.attachOracleQueryCacheWithSource({redis,authUserId:42},{async execute(){calls++;return {rows:[{TOTAL_POSTS:calls}]}}});
   const sql='SELECT COUNT(DISTINCT p.post_id) FROM n_posts p WHERE fn_can_view_post(:viewer_id, p.post_id) = 1';
   assert.equal((await conn.execute(sql,{viewer_id:42})).rows[0].TOTAL_POSTS,1);assert.equal((await conn.execute(sql,{viewer_id:42})).rows[0].TOTAL_POSTS,2);assert.equal(calls,2);
  }finally{close()}
 }finally{if(original===undefined)delete process.env.NEKO_CACHE_MODE;else process.env.NEKO_CACHE_MODE=original}
});

test('chat member lists bypass response cache in single-backend mode',async()=>{
 const original=process.env.NEKO_CACHE_MODE;try {
  const m=await moduleFor('single-backend','chat-members');const redis=fakeRedis(),{event,close}=eventFor(redis);
  try {event.node.req.url='/api/v2/chat/groups/7/members';const value=await m.readApiResponseCache(event,'v2');assert.equal(value.status,'bypass');assert.equal(redis.reads,0)}finally{close()}
 }finally{if(original===undefined)delete process.env.NEKO_CACHE_MODE;else process.env.NEKO_CACHE_MODE=original}
});

test('group reads and group post details bypass both caches',async()=>{
 const original=process.env.NEKO_CACHE_MODE;try {
  const m=await moduleFor('single-backend','group-lists');
  for(const path of ['/api/v2/groups','/api/v2/groups/popular','/api/v2/users/me/groups','/api/v2/groups/7/members','/api/v2/groups/7/invites','/api/v2/groups/7/posts/5','/api/v2/groups/7/notification-preference','/api/v2/groups/7/audit-logs','/api/v2/groups/invite-codes/EXAMPLE','/api/v2/users/me/group-invites']){
   const redis=fakeRedis(),{event,close}=eventFor(redis);
   try {
    event.node.req.url=path;
    assert.equal((await m.readApiResponseCache(event,'v2')).status,'bypass');
    let calls=0;
    const conn=m.attachOracleQueryCacheWithSource({redis,authUserId:42,path},{async execute(){return {rows:[{TOTAL:++calls}]}}});
    const sql='SELECT COUNT(*) AS total FROM v_group_details';
    assert.equal((await conn.execute(sql)).rows[0].TOTAL,1);
    assert.equal((await conn.execute(sql)).rows[0].TOTAL,2);
    assert.equal(redis.reads,0);
   }finally{close()}
  }
 }finally{if(original===undefined)delete process.env.NEKO_CACHE_MODE;else process.env.NEKO_CACHE_MODE=original}
});
