import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';
import {Readable} from 'node:stream';
import {EventEmitter} from 'node:events';
import {readFile} from 'node:fs/promises';
import {createServer} from 'node:http';
const root=fileURLToPath(new URL('../',import.meta.url));
const stubs={
 '~/server/utils/ai-model-quota':`export class AiQuotaError extends Error {} export const throwAiQuotaResponse=(_,error)=>{throw error};`,
 h3:`export const defineEventHandler=f=>f,setResponseHeader=(e,k,v)=>e.headers[k]=v,createError=x=>Object.assign(Error(x.message||x.statusMessage),x);`,
 '~/server/utils/v2':`export const v2Auth=e=>{if(!e.user)throw Error('401')},v2RouterParam=e=>e.id,v2Ok=data=>({code:200,data}),v2BadRequest=()=>{throw Error('400')},v2Conflict=()=>{throw Error('409')};`,
 '~/server/utils/auth-entry-errors':`export const safeV2Action=f=>f();`,
 '~/server/services/ai/knowledge-conversation-service':`export class KnowledgeConversationError extends Error {constructor(code){super(code);this.code=code}};export async function generateKnowledgeConversation(e,id,config,signal,phrase,skill){e.called++;e.phrase=phrase;e.skill=skill;if(e.skillFail)throw Error(e.skillFail);if(e.fail)throw new KnowledgeConversationError(e.fail);return e.result}`,
 '~/server/services/ai/knowledge-service':`export class KnowledgeServiceError extends Error {}`,
 '~/server/services/ai/knowledge-citations':`export class KnowledgeCitationError extends Error {}`,
 '~/server/services/ai/knowledge-turn':`export class KnowledgeTurnError extends Error {}`
};
stubs['~/server/services/ai/knowledge-search-body']=await readFile(new URL('../server/services/ai/knowledge-search-body.ts',import.meta.url),'utf8');
stubs['~/server/services/ai/stream-response']=await readFile(new URL('../server/services/ai/stream-response.ts',import.meta.url),'utf8');
const built=await build({stdin:{contents:`export {default} from './server/api/v2/ai/conversations/[id]/knowledge-generate.post';`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'route-stubs',setup(b){b.onResolve({filter:/.*/},a=>{if(Object.hasOwn(stubs,a.path))return {path:a.path,namespace:'stub'}});b.onLoad({filter:/.*/,namespace:'stub'},a=>({contents:stubs[a.path],loader:'ts',resolveDir:fileURLToPath(new URL('../server/services/ai/',import.meta.url))}))}}]});
const route=(await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`)).default;
test('requires login and returns a private generated message reference',async()=>{
 const denied={headers:{},id:'id',called:0};await assert.rejects(()=>route(denied),/401/);assert.equal(denied.called,0);assert.equal(denied.headers['Cache-Control'],'private, no-store');
 const message={message_id:'m',conversation_id:'id',sequence_no:2,role:'assistant'};
 const event={headers:{},id:'id',user:true,called:0,result:message,node:{req:Readable.from([]),res:new EventEmitter()}};
 assert.deepEqual((await route(event)).data,{status:'generated',message});assert.equal(event.called,1);
});
test('distinguishes missing evidence and rejects incorrect context',async()=>{
 const event={headers:{},id:'id',user:true,called:0,result:{message:null},node:{req:Readable.from([]),res:new EventEmitter()}};
 assert.deepEqual((await route(event)).data,{status:'insufficient_evidence',message:null});
 event.fail='INVALID_CONTEXT';event.node.req=Readable.from([]);await assert.rejects(()=>route(event),/400/);
});
test('skill configuration failures return a safe unavailable response',async()=>{
 for(const skillFail of ['SKILL_UNAVAILABLE','SKILL_CONFIG_UNAVAILABLE']) {
  const event={headers:{},id:'id',user:true,called:0,skillFail,node:{req:Readable.from([]),res:new EventEmitter()}};
  await assert.rejects(()=>route(event),e=>e.statusCode===503 && e.data.code===50301 && !JSON.stringify(e.data).includes(skillFail));
 }
});
test('accepts a separate phrase and rejects invalid or oversized requests before model work',async()=>{
 const make=body=>({headers:{},id:'id',user:true,called:0,result:{message_id:'m'},node:{req:Readable.from([Buffer.from(body)]),res:new EventEmitter()}});
 const valid=make('{"search_phrase":" 猫 ","skill_id":"knowledge-answer"}');await route(valid);assert.equal(valid.phrase,'猫');assert.equal(valid.skill,'knowledge-answer');
 for(const body of ['{"search_phrase":"猫","search_phrase":"狗"}','x'.repeat(4097)]) {
   const event=make(body);await assert.rejects(()=>route(event),/400/);assert.equal(event.called,0);
 }
});
test('reads bounded bodies from actual HTTP streams including empty requests',async()=>{
 const server=createServer(async(req,res)=>{
   const e={headers:{},id:'id',user:true,called:0,result:{message_id:'m'},node:{req,res}};
   try {await route(e);res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({phrase:e.phrase??null}));}
   catch {res.writeHead(400);res.end();}
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const url=`http://127.0.0.1:${server.address().port}`;
 try {
   const empty=await fetch(url,{method:'POST'});assert.equal(empty.status,200);assert.equal((await empty.json()).phrase,null);
   const valid=await fetch(url,{method:'POST',body:'{"search_phrase":"猫"}'});assert.equal(valid.status,200);assert.equal((await valid.json()).phrase,'猫');
   const large=await fetch(url,{method:'POST',body:'x'.repeat(4097)});assert.equal(large.status,400);
 } finally {await new Promise(resolve=>server.close(resolve));}
});
