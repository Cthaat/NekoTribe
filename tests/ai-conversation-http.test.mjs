import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const root = fileURLToPath(new URL('../', import.meta.url));
const stubs = {
  h3: `export const getQuery=e=>e.query||{};`,
  '~/server/utils/v2': `
    export const v2Auth=e=>{if(!e.user)throw Error('401');return e.user};
    export const v2Record=value=>{if(!value||typeof value!=='object'||Array.isArray(value))throw Error('400');return value};
    export const v2RouterParam=(e,k)=>e.params[k];
    export const v2BadRequest=()=>{throw Error('400')};
    export const v2Ok=data=>({code:200,message:'success',data,meta:null});`,
  './conversation-store': `
    export const createConversation=async(e,c,b)=>({purpose:b.purpose});
    export const readConversation=async(e,c,id)=>({conversation_id:id});
    export const deleteConversation=async(e,c,id)=>{c.deleted=id};
    export const listConversations=async(e,c,after,limit,purpose,groupId,targetTitle)=>({items:[],next_cursor:null,after,limit,...(purpose?{purpose}:{}),...(groupId?{groupId}:{}),...(targetTitle?{targetTitle}:{})});
    export const appendUserMessage=async(e,c,id,content)=>({conversation_id:id,content});
    export const listConversationMessages=async(e,c,id,after,limit,before)=>[{id,after,limit,...(before?{before}:{})}];`
};
const compiled = await build({
  stdin:{contents:`export * from './server/services/ai/conversation-http';`,resolveDir:root,loader:'ts'},
  bundle:true,write:false,platform:'node',format:'esm',
  plugins:[{name:'http-boundaries',setup(b){
    b.onResolve({filter:/.*/},args=>{if(Object.hasOwn(stubs,args.path))return {path:args.path,namespace:'stub'}});
    b.onLoad({filter:/.*/,namespace:'stub'},args=>({contents:stubs[args.path],loader:'js'}));
  }}]
});
const api = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);
const actor = {user:{userId:42},params:{id:'example'}};
const request = (body, ...rest) => ({...actor,node:{req:Readable.from([body, ...rest])}});

test('conversation operations require an authenticated actor',async()=>{
  for(const operation of [api.create,api.read,api.remove,api.append,api.list,api.listOwned]){
    await assert.rejects(()=>operation({params:{id:'example'},body:{content:'x'}},{}),/401/);
  }
});
test('conversation listing validates cursor and limit',async()=>{
  assert.deepEqual((await api.listOwned({...actor,query:{}},{})).data,{items:[],next_cursor:null,after:'',limit:20});
  const id='f1b5c80f-a1f4-44d6-898d-a5df6bc18bbb';
  assert.equal((await api.listOwned({...actor,query:{after_id:id,limit:'50'}},{})).data.after,id);
  assert.equal((await api.listOwned({...actor,query:{purpose:'knowledge'}},{})).data.purpose,'knowledge');
  assert.equal((await api.listOwned({...actor,query:{purpose:'group',group_id:'7'}},{})).data.groupId,7);
  assert.equal((await api.listOwned({...actor,query:{purpose:'moderation',target_type:'post',target_id:'17'}},{})).data.targetTitle,'moderation:post:17');
  for (const query of [{purpose:'writing',target_type:'post',target_id:'17'},{purpose:'moderation',target_id:'17'},{purpose:'moderation',target_type:'post',target_id:['17','18']},{purpose:'moderation',target_type:'post',target_id:'017'}]) {
    await assert.rejects(()=>api.listOwned({...actor,query},{}),/400/);
  }
  for (const query of [{group_id:'7'},{purpose:'group',group_id:'07'},{purpose:'group',group_id:['7','8']}]) await assert.rejects(()=>api.listOwned({...actor,query},{}),/400/);
  for (const purpose of ['', 'other', ['writing', 'knowledge']]) await assert.rejects(()=>api.listOwned({...actor,query:{purpose}},{}),/400/);
  for(const query of [{after_id:'bad'},{after_id:[id,id]},{limit:'0'},{limit:'51'},{limit:['1','2']}]) await assert.rejects(()=>api.listOwned({...actor,query},{}),/400/);
});
test('deleting a conversation returns null and delegates the authenticated identifier',async()=>{
  const db={};
  assert.equal((await api.remove(actor,db)).data,null);
  assert.equal(db.deleted,'example');
});
test('user messages accept only content and cannot forge an assistant role',async()=>{
  await assert.rejects(()=>api.append(request('{"content":"x","role":"assistant"}'),{}),/400/);
  assert.deepEqual((await api.append(request('{"content":"x"}'),{})).data,{conversation_id:'example',content:'x'});
});
test('conversation writes accept bounded UTF-8 JSON objects', async () => {
  const maxBytes = 1024 * 1024;
  for (const [operation, json, duplicate] of [
    [api.create, '{"purpose":"writing"}', '{"purpose":"knowledge","purpo\\u0073e":"writing"}'],
    [api.append, '{"content":"猫😺"}', '{"content":"first","cont\\u0065nt":"replacement"}'],
  ]) {
    const padding = ' '.repeat(maxBytes - Buffer.byteLength(json));
    assert.equal((await operation(request(json, padding), {})).code, 200);
    await assert.rejects(() => operation(request(json, padding, ' '), {}), /400/);
    for (const raw of ['content=hello', '[]', 'null', json + '{}', duplicate, '{"content":"\\ud800"}',
      Buffer.concat([Buffer.from('{"content":"'), Buffer.from([0xff]), Buffer.from('"}')])]) {
      await assert.rejects(() => operation(request(raw), {}), /400/);
    }
  }
});
test('history validates canonical integer pagination and uses defaults',async()=>{
  assert.deepEqual((await api.list({...actor,query:{}},{})).data,[{id:'example',after:0,limit:20}]);
  assert.deepEqual((await api.list({...actor,query:{after_sequence:'12',limit:'50'}},{})).data,[{id:'example',after:12,limit:50}]);
  assert.deepEqual((await api.list({...actor,query:{before_sequence:'10000000000',limit:'2'}},{})).data,[{id:'example',before:10000000000,after:0,limit:2}]);
  for(const query of [{after_sequence:'-1'},{after_sequence:'1.5'},{after_sequence:['1','2']},{limit:'0'},{limit:'51'},{limit:'1e1'},
    {before_sequence:'0'},{before_sequence:'10000000001'},{before_sequence:['1','2']},{before_sequence:'2',after_sequence:'0'}]){
    await assert.rejects(()=>api.list({...actor,query},{}),/400/);
  }
});

test('private response headers are set before a handler fails', async () => {
  const boundaries={
    h3:`export const defineEventHandler=f=>f; export const setResponseHeader=(e,k,v)=>{e.headers[k]=v};`,
    '~/server/utils/auth-entry-errors':`export const safeAuthEntry=f=>f;`,
    '~/server/utils/v2':`export const defineV2Handler=f=>e=>f(e,{});`
  };
  const bundle=await build({stdin:{contents:`export {privateAiHandler} from './server/services/ai/private-http';`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'private-boundaries',setup(b){
    b.onResolve({filter:/.*/},args=>{if(Object.hasOwn(boundaries,args.path))return {path:args.path,namespace:'stub'}});
    b.onLoad({filter:/.*/,namespace:'stub'},args=>({contents:boundaries[args.path],loader:'js'}));
  }}]});
  const {privateAiHandler}=await import(`data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`);
  const event={headers:{}};
  await assert.rejects(()=>privateAiHandler(async()=>{throw Error('fail')})(event),/fail/);
  assert.equal(event.headers['Cache-Control'],'private, no-store');
});
