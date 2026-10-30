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
function eventFor(redis) {const socket=new Socket(),req=new IncomingMessage(socket),res=new ServerResponse(req);req.url='/api/v2/posts';req.method='GET';req.headers.host='localhost';const event=createEvent(req,res);event.context.redis=redis;event.context.auth={userId:42};return {event,close(){res.destroy();socket.destroy()}}}
function fakeRedis(){const values=new Map();let reads=0;return {get reads(){return reads},async mget(...keys){reads++;return keys.map(k=>values.get(k)??null)},async get(key){reads++;return values.get(key)??null},async incr(k){const v=Number(values.get(k)??0)+1;values.set(k,String(v));return v},async del(k){values.delete(k)},pipeline(){const actions=[];return {set(k,v){actions.push(()=>values.set(k,v));return this},expire(){return this},incr(k){actions.push(()=>values.set(k,String(Number(values.get(k)??0)+1)));return this},async exec(){actions.forEach(fn=>fn());return []}}}}}

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
