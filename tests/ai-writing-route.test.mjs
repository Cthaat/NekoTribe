import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';
import {Readable} from 'node:stream';
const root=fileURLToPath(new URL('../',import.meta.url));
const stubs={
 '~/server/utils/ai-model-quota':`export class AiQuotaError extends Error {} export const throwAiQuotaResponse=(_,error)=>{throw error};`,
 h3:`export const defineEventHandler=f=>f,setResponseHeader=(e,k,v)=>e.headers[k]=v,createError=x=>Object.assign(Error(x.message||x.statusMessage),x);`,
 '~/server/utils/v2':`export const v2Auth=e=>{if(!e.user)throw Error('401')},v2RouterParam=(e)=>e.id,v2Ok=data=>({code:200,data}),v2BadRequest=()=>{throw Error('400')},v2Conflict=()=>{throw Error('409')};`,
 '~/server/utils/auth-entry-errors':`export const safeV2Action=f=>f();`,
 '~/server/services/ai/writing-service':`export const generateWritingReply=async(e,id,config,signal,skill,sequence)=>{e.called++;e.skill=skill;e.expectedSequence=sequence;if(e.skillFail)throw Error(e.skillFail);return {conversation_id:id,sequence_no:2,role:'assistant'}};`,
 '~/server/services/ai/writing-turn':`export class WritingTurnError extends Error {}`
};
const compiled=await build({stdin:{contents:`export {default} from './server/api/v2/ai/conversations/[id]/generate.post';`,resolveDir:root,loader:'ts'},alias:{'~':root},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'route-stubs',setup(b){
 b.onResolve({filter:/.*/},a=>{if(Object.hasOwn(stubs,a.path))return {path:a.path,namespace:'stub'}});
 b.onLoad({filter:/.*/,namespace:'stub'},a=>({contents:stubs[a.path],loader:'js'}));
}}]});
const route=(await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`)).default;
const request = (raw) => ({headers:{},id:'id',user:true,called:0,node:{req:Readable.from(raw ? [Buffer.from(raw)] : [])}});
test('generation requires auth and accepts only the writing skill',async()=>{
 const denied={headers:{},id:'id',called:0};
 await assert.rejects(()=>route(denied),/401/);assert.equal(denied.called,0);assert.equal(denied.headers['Cache-Control'],'private, no-store');
 for(const [raw, skill] of [['',null],['{}',null],['{"skill_id":"writing-draft"}','writing-draft']]) {
  const event=request(raw);
  const result=await route(event);
  assert.equal(result.data.conversation_id,'id');assert.equal(event.called,1);assert.equal(event.skill,skill);
  assert.equal(event.headers['Cache-Control'],'private, no-store');
 }
 const guarded=request('{"skill_id":"writing-draft","expected_sequence":1}');
 await route(guarded);
 assert.equal(guarded.expectedSequence,1);
 await assert.rejects(()=>route(request('{"expected_sequence":0}')),/400/);
 for(const raw of ['{"model":"caller"}','{"skill_id":"group-brief"}','{"skill_id":null}','{"skill_id":"writing-draft","skill_id":"writing-draft"}',' '.repeat(4097)]) {
  const event=request(raw);
  await assert.rejects(()=>route(event),/400/);assert.equal(event.called,0);
 }
});
test('skill failures return a safe unavailable response',async()=>{
 for(const skillFail of ['SKILL_UNAVAILABLE','SKILL_CONFIG_UNAVAILABLE']) {
  const event={...request('{"skill_id":"writing-draft"}'),skillFail};
  await assert.rejects(()=>route(event),e=>e.statusCode===503 && e.data.code===50301 && !JSON.stringify(e.data).includes(skillFail));
 }
});
