import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const root = fileURLToPath(new URL('../', import.meta.url));
const stubs = {
  h3: `export const getQuery=e=>e.query||{};`,
  '~/server/utils/v2': `
    export const v2Auth=e=>{if(!e.user)throw Error('401');return e.user};
    export const v2Body=async e=>{if(!e.body||typeof e.body!=='object'||Array.isArray(e.body))throw Error('400');return e.body};
    export const v2RouterParam=(e,k)=>e.params[k];
    export const v2BadRequest=()=>{throw Error('400')};
    export const v2Ok=data=>({code:200,message:'success',data,meta:null});`,
  './conversation-store': `
    export const createConversation=async(e,c,b)=>({purpose:b.purpose});
    export const readConversation=async(e,c,id)=>({conversation_id:id});
    export const deleteConversation=async(e,c,id)=>{c.deleted=id};
    export const appendUserMessage=async(e,c,id,content)=>({conversation_id:id,content});
    export const listConversationMessages=async(e,c,id,after,limit)=>[{id,after,limit}];`
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

test('conversation operations require an authenticated actor',async()=>{
  for(const operation of [api.create,api.read,api.remove,api.append,api.list]){
    await assert.rejects(()=>operation({params:{id:'example'},body:{content:'x'}},{}),/401/);
  }
});
test('deleting a conversation returns null and delegates the authenticated identifier',async()=>{
  const db={};
  assert.equal((await api.remove(actor,db)).data,null);
  assert.equal(db.deleted,'example');
});
test('user messages accept only content and cannot forge an assistant role',async()=>{
  await assert.rejects(()=>api.append({...actor,body:{content:'x',role:'assistant'}},{}),/400/);
  assert.deepEqual((await api.append({...actor,body:{content:'x'}},{})).data,{conversation_id:'example',content:'x'});
});
test('history validates canonical integer pagination and uses defaults',async()=>{
  assert.deepEqual((await api.list({...actor,query:{}},{})).data,[{id:'example',after:0,limit:20}]);
  assert.deepEqual((await api.list({...actor,query:{after_sequence:'12',limit:'50'}},{})).data,[{id:'example',after:12,limit:50}]);
  for(const query of [{after_sequence:'-1'},{after_sequence:'1.5'},{after_sequence:['1','2']},{limit:'0'},{limit:'51'},{limit:'1e1'}]){
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
