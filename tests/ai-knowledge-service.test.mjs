import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';

const root=fileURLToPath(new URL('../',import.meta.url));
const source={kind:'post',id:1,post_id:1,content:'公开资料',version:'a'.repeat(64)};
const stubs={
 '~/server/utils/ai-model-quota':`export const requireAiModelQuota=async(e,actor,cost)=>{if(actor!==42||cost!==1)throw Error('quota')};`,
 '~/server/utils/v2':`export const v2Auth=e=>{if(!e.user)throw Error('401');return {userId:42}};export const v2Connection=async e=>e.open();export const v2ServerError=()=>{throw Error('500')};export const v2Forbidden=()=>{throw Error('403')};export const v2Conflict=()=>{throw Error('409')}; export const v2One=async(c,sql,binds)=>(await c.execute(sql,binds)).rows?.[0];`,
 './knowledge-source':`export async function discoverKnowledgeSources(e,c,q,l){e.events.push('discover');e.search=q;return e.sources};export async function hydrateKnowledgeSources(e,c,input){e.events.push('hydrate');e.onHydrate?.();return [...e.sources,...(e.historical??[])].filter(r=>input.some(x=>x.kind===r.kind && x.id===r.id && x.version===r.version))};`,
 './model-configuration.ts':`export class AiConfigurationError extends Error {}; export class AiModelRouter {constructor(){} select(role){if(role!=='knowledge')throw Error('wrong role');return {configurationRevision:1,profileId:'test',modelVersion:'build-a',contextWindowTokens:8192,maxOutputTokens:512,capabilities:globalThis.__knowledgeCapabilities??[]}}}`,
 './inference-transport.ts':`export class AiInferenceTransport {async infer(s,input){globalThis.__knowledgeEvents.push('infer');globalThis.__knowledgeInput=input;globalThis.__knowledgeOnInfer?.();return {text:globalThis.__knowledgeOutput??JSON.stringify({answer:'answer',citations:[{kind:'post',id:1,version:'a'.repeat(64)}]}),toolCalls:[],finishReason:'stop'}}}`
};
const built=await build({stdin:{contents:`export * from './server/services/ai/knowledge-service.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'service-stubs',setup(b){b.onResolve({filter:/.*/},a=>{if(Object.hasOwn(stubs,a.path))return {path:a.path,namespace:'stub'}});b.onLoad({filter:/.*/,namespace:'stub'},a=>({contents:stubs[a.path],loader:'js'}))}}]});
const {generateKnowledgeReply}=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
function event(sources=[source]) { const events=[];globalThis.__knowledgeEvents=events;return {user:true,sources,events,async open(){events.push('open');return {async close(){events.push('close')}}}}; }

test('uses the ranked Unicode chunk and cites the revalidated full source',async t=>{
 const names=['AI_KNOWLEDGE_INDEX_URL','AI_INDEX_SERVICE_TOKEN'];
 const original=names.map(name=>process.env[name]);
 t.after(()=>names.forEach((name,index)=>{
   if(original[index]===undefined)delete process.env[name];
   else process.env[name]=original[index];
 }));
 process.env.AI_KNOWLEDGE_INDEX_URL='http://127.0.0.1:3818';
 process.env.AI_INDEX_SERVICE_TOKEN='x'.repeat(32);
 t.mock.method(globalThis,'fetch',async (_url,options)=>{
   assert.equal(options.headers['x-neko-knowledge-chunks'],'1');
   return Response.json({version:1,candidates:[{kind:'post',id:1,version:source.version,chunk:1}]});
 });
 const result=await generateKnowledgeReply(event([{...source,content:'🐈'.repeat(640)+'应摘录的段落'}]),'动物','{}');
 const payload=JSON.parse(globalThis.__knowledgeInput.messages[1].content);
 assert.equal(payload.sources[0].content,'应摘录的段落');
 assert.deepEqual(result.sources,[{kind:'post',id:1,version:source.version}]);
});

test('preserves cancellation when inference or historical source revalidation is interrupted',async()=>{
 const e=event(),controller=new AbortController();
 globalThis.__knowledgeOnInfer=()=>{controller.abort();throw Error('transport aborted')};
 try {await assert.rejects(()=>generateKnowledgeReply(e,'猫','{}',controller.signal),error=>error.code==='CANCELLED');} finally {delete globalThis.__knowledgeOnInfer;}
 const e2=event(),second=new AbortController();
 const history=[{sequence_no:1,role:'assistant',content:'old',citations:[{kind:'post',id:1,version:source.version,post_id:1}]},{sequence_no:2,role:'user',content:'猫'}];
 e2.onHydrate=()=>{if(e2.events.includes('infer')) {second.abort();throw Error('query cancelled')}};
 await assert.rejects(()=>generateKnowledgeReply(e2,'猫','{}',second.signal,undefined,history),error=>error.code==='CANCELLED');
});

test('closes connections around inference, uses knowledge model and passes data as user content',async()=>{
 const e=event();const output=await generateKnowledgeReply(e,'猫','{}');
 assert.deepEqual(e.events,['open','discover','close','open','hydrate','close','infer','open','hydrate','close']);
 assert.equal(output.answer,'answer');assert.deepEqual(output.sources,[{kind:'post',id:1,version:source.version}]);
 assert.equal(output.modelVersion,'build-a');
 const messages=globalThis.__knowledgeInput.messages;assert.equal(messages[0].role,'system');assert.equal(messages[1].role,'user');assert.match(messages[0].content,/不可信/);assert.equal(JSON.parse(messages[1].content).sources[0].content,'公开资料');
 assert.equal(globalThis.__knowledgeInput.responseSchema,undefined);
});
test('requests structured answers for capable models and still validates their citations',async(t)=>{
 t.after(()=>{delete globalThis.__knowledgeCapabilities;delete globalThis.__knowledgeOutput;});
 globalThis.__knowledgeCapabilities=['structured-output'];
 globalThis.__knowledgeOutput=JSON.stringify({answer:'answer',citations:[1]});
 const result=await generateKnowledgeReply(event(),'猫','{}');
 assert.equal(result.answer,'answer');
 assert.deepEqual(result.sources,[{kind:'post',id:1,version:source.version}]);
 assert.deepEqual(globalThis.__knowledgeInput.responseSchema.required,['answer','citations']);
 assert.deepEqual(globalThis.__knowledgeInput.responseSchema.properties.citations.items.enum,[1]);
 assert.deepEqual(JSON.parse(globalThis.__knowledgeInput.messages[1].content).sources,[{ref:1,kind:'post',content:'公开资料'}]);
 for(const invalid of [[2],[1,1]]) {
   globalThis.__knowledgeOutput=JSON.stringify({answer:'answer',citations:invalid});
   await assert.rejects(()=>generateKnowledgeReply(event(),'猫','{}'),/INVALID_CITATIONS/);
 }
});
test('uses a separate retrieval phrase while preserving the original question for the model',async()=>{
 const e=event();await generateKnowledgeReply(e,'社区里有哪些猫咪？','{}',undefined,'猫');
 assert.equal(e.search,'猫');assert.equal(JSON.parse(globalThis.__knowledgeInput.messages[1].content).question,'社区里有哪些猫咪？');
});
test('supplies selected history as untrusted data and rechecks its sources before and after inference',async()=>{
 const e=event();const old={kind:'comment',id:23,post_id:1,version:'b'.repeat(64),content:'以前公开的评论'};e.historical=[old];
 const history=[{sequence_no:1,role:'user',content:'以前问题'},{sequence_no:2,role:'assistant',content:'以前回答',citations:[{kind:old.kind,id:old.id,version:old.version,post_id:old.post_id}]},{sequence_no:3,role:'user',content:'新问题'}];
 const result=await generateKnowledgeReply(e,'新问题','{}',undefined,'猫',history);
 const payload=JSON.parse(globalThis.__knowledgeInput.messages[1].content);
 assert.deepEqual(payload.history,[{role:'user',content:'以前问题'},{role:'assistant',content:'以前回答'}]);
 assert.equal(payload.question,'新问题');assert.deepEqual(result.contextSources,[{kind:'comment',id:23,version:old.version}]);
 assert.deepEqual(result.contextSnapshot,history);
 history[1].citations[0].version='c'.repeat(64);history[2].content='changed';
 assert.equal(result.contextSnapshot[1].citations[0].version,old.version);assert.equal(result.contextSnapshot[2].content,'新问题');
 assert.deepEqual(result.sources,[{kind:'post',id:1,version:source.version},{kind:'comment',id:23,version:old.version}]);
 assert.equal(e.events.filter(x=>x==='hydrate').length,4);
});
test('withholds generated reply if a historical source is revoked during inference',async()=>{
 const e=event(),old={kind:'comment',id:23,post_id:1,version:'b'.repeat(64),content:'以前公开的评论'};e.historical=[old];
 const history=[{sequence_no:1,role:'assistant',content:'以前回答',citations:[{kind:old.kind,id:old.id,version:old.version,post_id:old.post_id}]},{sequence_no:2,role:'user',content:'新问题'}];
 globalThis.__knowledgeOnInfer=()=>{e.historical=[]};
 try {await assert.rejects(()=>generateKnowledgeReply(e,'新问题','{}',undefined,'猫',history),/SOURCE_CHANGED/);} finally {delete globalThis.__knowledgeOnInfer;}
});
test('uses bounded excerpts and does not invoke the model for empty evidence',async()=>{
 const e=event([]);const output=await generateKnowledgeReply(e,'猫','{}');assert.equal(output.answer,null);assert.ok(!e.events.includes('infer'));
 const large=event([{...source,content:'狗'.repeat(10000)+'猫'.repeat(10000)}]);await generateKnowledgeReply(large,'猫','{}');
 const payload=JSON.parse(globalThis.__knowledgeInput.messages[1].content);
 assert.equal(payload.sources[0].content,'猫'.repeat(768));
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
