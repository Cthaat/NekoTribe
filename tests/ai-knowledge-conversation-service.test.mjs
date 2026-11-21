import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const ref={kind:'post',id:1,version:'a'.repeat(64)};
const stubs={
 '~/server/utils/logging':`export const logInfo=(scope,event)=>globalThis.__aiKnowledgeAudit.push(event);`,
 '~/server/utils/ai-model-quota':`export class AiQuotaError extends Error {}`,
 '~/server/utils/v2':`export const v2Auth=e=>{if(!e.user)throw Error('401');return {userId:42}};export const v2Connection=e=>e.open();export const v2ServerError=()=>{throw Error('500')};`,
 './skill-conversation':`export async function selectConfiguredConversationSkill(e,c,scope){e.events.push('skill');if(e.disabled)throw Error('SKILL_UNAVAILABLE');if(scope.ownerUserId!==42 || scope.purpose!=='knowledge')throw Error('bad scope');return {configGeneration:e.generation,skill:{id:'knowledge-answer'}}}`,
 './conversation-store':`export async function readConversation(e){e.events.push('read');return {purpose:e.purpose}};export async function listRecentConversationMessages(e){e.events.push('history');return e.messages};export async function appendKnowledgeAssistantMessage(e,c,id,input){e.events.push('append');e.saved=input;return {sequence_no:2}};`,
 './knowledge-service':`export async function generateKnowledgeReply(e,query,config,signal,search,history,audit){audit.stage='evidence';audit.configRevision=e.reply.configRevision;e.events.push('generate');e.query=query;e.search=search;e.history=history;e.onGenerate?.();return e.reply}`
};
const built=await build({stdin:{contents:`export * from './server/services/ai/knowledge-conversation-service.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'boundaries',setup(b){b.onResolve({filter:/.*/},a=>{if(Object.hasOwn(stubs,a.path))return {path:a.path,namespace:'stub'}});b.onLoad({filter:/.*/,namespace:'stub'},a=>({contents:stubs[a.path],loader:'js'}))}}]});
const {generateKnowledgeConversation}=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
globalThis.__aiKnowledgeAudit=[];
function event(){return {user:true,purpose:'knowledge',generation:7,messages:[{sequence_no:1,role:'user',content:'猫'}],reply:{answer:'answer',sources:[ref],modelId:'profile',configRevision:3},events:[],async open(){this.events.push('open');return {close:async()=>this.events.push('close')}}};}
test('generates after closing the read connection and writes with the selected snapshot and expected sequence',async()=>{
 const e=event(), {signal}=new AbortController();const result=await generateKnowledgeConversation(e,'id','{}',signal);
 assert.equal(result.sequence_no,2);assert.equal(e.query,'猫');assert.deepEqual(e.events,['open','read','history','skill','close','generate','open','append','close']);
 assert.deepEqual(e.saved,{answer:'answer',sources:[ref],expectedSequence:1,modelId:'profile',configRevision:3,skillGeneration:7,signal});
 const {elapsed_ms,...audit}=globalThis.__aiKnowledgeAudit.pop();
 assert(Number.isInteger(elapsed_ms) && elapsed_ms>=0);
 assert.deepEqual(audit,{event:'ai.run',version:1,operation:'knowledge_answer',stage:'persist',outcome:'generated',
   config_revision:3,skill_generation:7,skill_selection:'purpose-default',tool_count:0});
});
test('disabled knowledge skill blocks inference and saving',async()=>{
 const e=event();e.disabled=true;await assert.rejects(()=>generateKnowledgeConversation(e,'id','{}'),/SKILL_UNAVAILABLE/);assert.ok(!e.events.includes('generate'));assert.ok(!e.events.includes('append'));
});
test('expected knowledge sequence conflicts before inference when a newer question is present', async()=>{
 const e=event();e.messages.push({sequence_no:2,role:'user',content:'newer'});
 await assert.rejects(()=>generateKnowledgeConversation(e,'id','{}',undefined,undefined,null,1),/SEQUENCE_CONFLICT/);
 assert.ok(!e.events.includes('generate'));assert.ok(!e.events.includes('append'));
});
test('no evidence, invalid conversation and cancellation do not write',async()=>{
 const e=event();e.reply.answer=null;e.reply.sources=[];assert.deepEqual(await generateKnowledgeConversation(e,'id','{}'),{message:null});assert.ok(!e.events.includes('append'));
 assert.equal(globalThis.__aiKnowledgeAudit.pop().outcome,'insufficient_evidence');
 const bad=event();bad.purpose='writing';await assert.rejects(()=>generateKnowledgeConversation(bad,'id','{}'),/INVALID_CONTEXT/);assert.ok(!bad.events.includes('generate'));
 const cancelled=event(),controller=new AbortController();controller.abort();await assert.rejects(()=>generateKnowledgeConversation(cancelled,'id','{}',controller.signal),/CANCELLED/);assert.deepEqual(cancelled.events,[]);
 const during=event(),mid=new AbortController();during.onGenerate=()=>mid.abort();await assert.rejects(()=>generateKnowledgeConversation(during,'id','{}',mid.signal),/CANCELLED/);assert.ok(!during.events.includes('append'));
 assert.equal(globalThis.__aiKnowledgeAudit.pop().outcome,'cancelled');
});
test('passes an explicit search phrase separately from the persisted user question',async()=>{
 const e=event();e.messages[0].content='社区里有哪些猫咪？';await generateKnowledgeConversation(e,'id','{}',undefined,'猫');
 assert.equal(e.query,'社区里有哪些猫咪？');assert.equal(e.search,'猫');
});
test('passes authorized history to inference and guards the exact selected source snapshot during write',async()=>{
 const e=event(),old={kind:'post',id:2,version:'b'.repeat(64)};
 e.messages=[{sequence_no:1,role:'assistant',content:'old answer',citations:[{...old,post_id:2}]},{sequence_no:2,role:'user',content:'follow-up'}];e.reply.contextSources=[old];e.reply.sources=[ref,old];
 e.reply.contextSnapshot=structuredClone(e.messages);
 await generateKnowledgeConversation(e,'id','{}');assert.deepEqual(e.history,e.messages);assert.deepEqual(e.saved.contextSources,[old]);assert.deepEqual(e.saved.contextSnapshot,e.messages);assert.deepEqual(e.saved.sources,[ref,old]);assert.equal(e.saved.expectedSequence,2);
});
