import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const stubs={
 h3:`export const defineEventHandler=f=>f,setResponseHeader=(e,k,v)=>e.headers[k]=v,createError=x=>Object.assign(Error(x.message||x.statusMessage),x);`,
 '~/server/utils/v2':`export const v2Auth=e=>{if(!e.user)throw Error('401')},v2RouterParam=(e)=>e.id,v2Ok=data=>({code:200,data}),v2BadRequest=()=>{throw Error('400')};`,
 '~/server/utils/auth-entry-errors':`export const safeV2Action=f=>f();`,
 '~/server/services/ai/writing-service':`export const generateWritingReply=async(e,id)=>{e.called++;return {conversation_id:id,sequence_no:2,role:'assistant'}};`,
 '~/server/services/ai/writing-turn':`export class WritingTurnError extends Error {}`
};
const compiled=await build({stdin:{contents:`export {default} from './server/api/v2/ai/conversations/[id]/generate.post';`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'route-stubs',setup(b){
 b.onResolve({filter:/.*/},a=>{if(Object.hasOwn(stubs,a.path))return {path:a.path,namespace:'stub'}});
 b.onLoad({filter:/.*/,namespace:'stub'},a=>({contents:stubs[a.path],loader:'js'}));
}}]});
const route=(await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`)).default;
test('generation requires auth and never accepts model configuration from the caller',async()=>{
 const denied={headers:{},id:'id',called:0};
 await assert.rejects(()=>route(denied),/401/);assert.equal(denied.called,0);assert.equal(denied.headers['Cache-Control'],'private, no-store');
 const event={headers:{},id:'id',user:true,called:0,body:{model:'attacker'}};
 const result=await route(event);
 assert.equal(result.data.conversation_id,'id');assert.equal(event.called,1);assert.equal(event.headers['Cache-Control'],'private, no-store');
});
