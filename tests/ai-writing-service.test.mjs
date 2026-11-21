import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';

const root=fileURLToPath(new URL('../',import.meta.url));
const stubs={
 '~/server/utils/logging':`export const logInfo=(scope,event)=>globalThis.__aiWritingAudit.push({scope,...event});`,
 '~/server/utils/ai-model-quota':`export class AiQuotaError extends Error {} export const requireAiModelQuota=async(e,actor,cost)=>{if(actor!==42||cost!==1)throw Error('quota');e.events.push('reserve')};`,
 '~/server/utils/v2':`export const v2Auth=e=>{if(!e.user)throw Error('401');return {userId:42}}; export const v2Connection=async e=>e.open(); export const v2ServerError=()=>{throw Error('500')};`,
 './skill-conversation':`export async function selectConfiguredConversationSkill(e,c,scope){e.events.push('skill');if(e.disabled)throw Error('SKILL_UNAVAILABLE');if(scope.ownerUserId!==42 || scope.purpose!=='writing')throw Error('scope');return {configGeneration:7,skill:{id:'writing-draft'}}}`,
 './conversation-store':`
  export const readConversation=async(e,c)=>{e.events.push('read');return {purpose:'writing',group_id:null}};
  export const listRecentConversationMessages=async(e,c)=>{e.events.push('history');return [{sequence_no:1,role:'user',content:'test'}]};
  export const appendAssistantMessage=async(e,c,id,input)=>{e.events.push('append');return {sequence_no:2,...input}};`,
 './model-configuration.ts':`export class AiConfigurationError extends Error {}; export class AiModelRouter {constructor(x){} select(){return {configurationRevision:1,profileId:'test',modelVersion:'build-b',contextWindowTokens:8192,maxOutputTokens:512,adapter:'ollama',model:'test',baseUrl:'http://localhost',apiKeyEnv:null,capabilities:[]}}}`,
 './inference-transport.ts':`export class AiInferenceTransport {async infer(s,i){globalThis.__aiWritingEvents.push('infer');return {text:'answer',toolCalls:[],finishReason:'stop'}}}`
};
const result=await build({stdin:{contents:`export {generateWritingReply} from './server/services/ai/writing-service';`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'boundaries',setup(b){
 b.onResolve({filter:/.*/},a=>{if(Object.hasOwn(stubs,a.path))return {path:a.path,namespace:'stub'}});
 b.onLoad({filter:/.*/,namespace:'stub'},a=>({contents:stubs[a.path],loader:'js'}));
}}]});
const {generateWritingReply}=await import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`);
globalThis.__aiWritingAudit=[];

test('closes the read connection before model inference and opens a new one for writing',async()=>{
 const events=[];globalThis.__aiWritingEvents=events;
 const event={user:true,events,async open(){events.push('open');return {async close(){events.push('close')}}}};
 const reply=await generateWritingReply(event,'id','{}',undefined,'writing-draft');
 assert.equal(reply.content,'answer');assert.equal(reply.skillGeneration,7);
 assert.equal(reply.modelVersion,'build-b');
 assert.deepEqual(events,['open','read','history','skill','close','reserve','infer','open','append','close']);
 const {elapsed_ms,...audit}=globalThis.__aiWritingAudit.pop();
 assert(Number.isInteger(elapsed_ms) && elapsed_ms>=0);
 assert.deepEqual(audit,{scope:'ai',event:'ai.run',version:1,operation:'writing_draft',stage:'persist',outcome:'generated',
   config_revision:1,skill_generation:7,skill_selection:'explicit',tool_count:0});
 delete globalThis.__aiWritingEvents;
});

test('connection close failure prevents inference',async()=>{
 const events=[];globalThis.__aiWritingEvents=events;
 const event={user:true,events,async open(){events.push('open');return {async close(){events.push('close');throw Error('private')}}}};
 await assert.rejects(()=>generateWritingReply(event,'id','{}'),/500/);
 assert.deepEqual(events,['open','read','history','skill','close']);
 assert.equal(globalThis.__aiWritingAudit.pop().outcome,'failed');
 delete globalThis.__aiWritingEvents;
});
test('disabled writing skill prevents inference',async()=>{
 const events=[];globalThis.__aiWritingEvents=events;
 const event={user:true,disabled:true,events,async open(){events.push('open');return {async close(){events.push('close')}}}};
 await assert.rejects(()=>generateWritingReply(event,'id','{}'),/SKILL_UNAVAILABLE/);assert(!events.includes('infer'));assert(!events.includes('append'));assert.equal(globalThis.__aiWritingAudit.length,0);delete globalThis.__aiWritingEvents;
});
test('expected writing sequence mismatch prevents quota use, inference and save', async()=>{
 const events=[];globalThis.__aiWritingEvents=events;
 const event={user:true,events,async open(){return {async close(){}}}};
 await assert.rejects(()=>generateWritingReply(event,'id','{}',undefined,null,2),/SEQUENCE_CONFLICT/);
 assert.deepEqual(events,['read','history','skill']);
 assert.equal(globalThis.__aiWritingAudit.pop().outcome,'failed');
 delete globalThis.__aiWritingEvents;
});
