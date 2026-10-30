import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';

const root=fileURLToPath(new URL('../',import.meta.url));
const source={kind:'post',id:1,post_id:1,content:'公开资料',version:'a'.repeat(64)};
const stubs={
 '~/server/utils/v2':`export const v2Auth=e=>{if(!e.user)throw Error('401')};export const v2Connection=async e=>e.open();export const v2ServerError=()=>{throw Error('500')};`,
 './knowledge-source':`export async function discoverKnowledgeSources(e,c,q,l){e.events.push('discover');e.search=q;return e.sources};export async function hydrateKnowledgeSources(e,c,input){e.events.push('hydrate');return e.sources};`,
 './model-configuration.ts':`export class AiModelRouter {constructor(){} select(role){if(role!=='knowledge')throw Error('wrong role');return {configurationRevision:1,profileId:'test',contextWindowTokens:8192,maxOutputTokens:512}}}`,
 './inference-transport.ts':`export class AiInferenceTransport {async infer(s,input){globalThis.__knowledgeEvents.push('infer');globalThis.__knowledgeInput=input;globalThis.__knowledgeOnInfer?.();return {text:globalThis.__knowledgeOutput??JSON.stringify({answer:'answer',citations:[{kind:'post',id:1,version:'a'.repeat(64)}]}),toolCalls:[],finishReason:'stop'}}}`
};
const built=await build({stdin:{contents:`export * from './server/services/ai/knowledge-service.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'service-stubs',setup(b){b.onResolve({filter:/.*/},a=>{if(Object.hasOwn(stubs,a.path))return {path:a.path,namespace:'stub'}});b.onLoad({filter:/.*/,namespace:'stub'},a=>({contents:stubs[a.path],loader:'js'}))}}]});
const {generateKnowledgeReply}=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
function event(sources=[source]) { const events=[];globalThis.__knowledgeEvents=events;return {user:true,sources,events,async open(){events.push('open');return {async close(){events.push('close')}}}}; }

test('closes connections around inference, uses knowledge model and passes data as user content',async()=>{
 const e=event();const output=await generateKnowledgeReply(e,'猫','{}');
 assert.deepEqual(e.events,['open','discover','close','open','hydrate','close','infer','open','hydrate','close']);
 assert.equal(output.answer,'answer');assert.deepEqual(output.sources,[{kind:'post',id:1,version:source.version}]);
 const messages=globalThis.__knowledgeInput.messages;assert.equal(messages[0].role,'system');assert.equal(messages[1].role,'user');assert.match(messages[0].content,/不可信/);assert.equal(JSON.parse(messages[1].content).sources[0].content,'公开资料');
});
test('uses a separate retrieval phrase while preserving the original question for the model',async()=>{
 const e=event();await generateKnowledgeReply(e,'社区里有哪些猫咪？','{}',undefined,'猫');
 assert.equal(e.search,'猫');assert.equal(JSON.parse(globalThis.__knowledgeInput.messages[1].content).question,'社区里有哪些猫咪？');
});
test('does not invoke model for empty evidence or oversized context',async()=>{
 const e=event([]);const output=await generateKnowledgeReply(e,'猫','{}');assert.equal(output.answer,null);assert.ok(!e.events.includes('infer'));
 const large=event([{...source,content:'x'.repeat(20000)}]);await assert.rejects(()=>generateKnowledgeReply(large,'猫','{}'),/CONTEXT_TOO_LARGE/);assert.ok(!large.events.includes('infer'));
});
test('connection close failure and invalid configuration fail before inference',async()=>{
 const e=event();e.open=async()=>({async close(){throw Error('private')}});
 await assert.rejects(()=>generateKnowledgeReply(e,'猫','{}'),/500/);assert.ok(!e.events.includes('infer'));
 await assert.rejects(()=>generateKnowledgeReply(event(),'猫',''),/PROVIDER_FAILED/);
});
test('does not deliver a model reply when its source becomes inaccessible during inference',async()=>{
 const e=event();globalThis.__knowledgeOnInfer=()=>{e.sources=[]};
 try {await assert.rejects(()=>generateKnowledgeReply(e,'猫','{}'),/SOURCE_CHANGED/);} finally {delete globalThis.__knowledgeOnInfer;}
 assert.deepEqual(e.events,['open','discover','close','open','hydrate','close','infer','open','hydrate','close']);
});
test('does not deliver invented citations',async()=>{
 const e=event();globalThis.__knowledgeOutput=JSON.stringify({answer:'invented',citations:[{kind:'post',id:999,version:'a'.repeat(64)}]});
 try {await assert.rejects(()=>generateKnowledgeReply(e,'猫','{}'),/INVALID_CITATIONS/);} finally {delete globalThis.__knowledgeOutput;}
});
