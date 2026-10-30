import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';

const root=fileURLToPath(new URL('../',import.meta.url));
const stubs={
 '~/server/utils/v2':`export const v2Auth=e=>{if(!e.user)throw Error('401')}; export const v2Connection=async e=>e.open(); export const v2ServerError=()=>{throw Error('500')};`,
 './conversation-store':`
  export const readConversation=async(e,c)=>{e.events.push('read');return {purpose:'writing'}};
  export const listRecentConversationMessages=async(e,c)=>{e.events.push('history');return [{sequence_no:1,role:'user',content:'test'}]};
  export const appendAssistantMessage=async(e,c,id,input)=>{e.events.push('append');return {sequence_no:2,...input}};`,
 './model-configuration.ts':`export class AiModelRouter {constructor(x){} select(){return {configurationRevision:1,profileId:'test',contextWindowTokens:8192,maxOutputTokens:512,adapter:'ollama',model:'test',baseUrl:'http://localhost',apiKeyEnv:null,capabilities:[]}}}`,
 './inference-transport.ts':`export class AiInferenceTransport {async infer(s,i){globalThis.__aiWritingEvents.push('infer');return {text:'answer',toolCalls:[],finishReason:'stop'}}}`
};
const result=await build({stdin:{contents:`export {generateWritingReply} from './server/services/ai/writing-service';`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'boundaries',setup(b){
 b.onResolve({filter:/.*/},a=>{if(Object.hasOwn(stubs,a.path))return {path:a.path,namespace:'stub'}});
 b.onLoad({filter:/.*/,namespace:'stub'},a=>({contents:stubs[a.path],loader:'js'}));
}}]});
const {generateWritingReply}=await import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`);

test('closes the read connection before model inference and opens a new one for writing',async()=>{
 const events=[];globalThis.__aiWritingEvents=events;
 const event={user:true,events,async open(){events.push('open');return {async close(){events.push('close')}}}};
 const reply=await generateWritingReply(event,'id','{}');
 assert.equal(reply.content,'answer');
 assert.deepEqual(events,['open','read','history','close','infer','open','append','close']);
 delete globalThis.__aiWritingEvents;
});

test('connection close failure prevents inference',async()=>{
 const events=[];globalThis.__aiWritingEvents=events;
 const event={user:true,events,async open(){events.push('open');return {async close(){events.push('close');throw Error('private')}}}};
 await assert.rejects(()=>generateWritingReply(event,'id','{}'),/500/);
 assert.deepEqual(events,['open','read','history','close']);
 delete globalThis.__aiWritingEvents;
});
