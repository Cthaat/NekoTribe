import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const stubs={
 h3:`export const defineEventHandler=f=>f,setResponseHeader=(e,k,v)=>e.headers[k]=v,createError=x=>Object.assign(Error(x.message||x.statusMessage),x);`,
 '~/server/utils/v2':`export const v2Auth=e=>{if(!e.user)throw Error('401')},v2RouterParam=e=>e.id,v2Ok=data=>({code:200,data}),v2BadRequest=()=>{throw Error('400')};`,
 '~/server/utils/auth-entry-errors':`export const safeV2Action=f=>f();`,
 '~/server/services/ai/knowledge-conversation-service':`export class KnowledgeConversationError extends Error {constructor(code){super(code);this.code=code}};export async function generateKnowledgeConversation(e,id){e.called++;if(e.fail)throw new KnowledgeConversationError(e.fail);return e.result}`,
 '~/server/services/ai/knowledge-service':`export class KnowledgeServiceError extends Error {}`,
 '~/server/services/ai/knowledge-citations':`export class KnowledgeCitationError extends Error {}`,
 '~/server/services/ai/knowledge-turn':`export class KnowledgeTurnError extends Error {}`
};
const built=await build({stdin:{contents:`export {default} from './server/api/v2/ai/conversations/[id]/knowledge-generate.post';`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'route-stubs',setup(b){b.onResolve({filter:/.*/},a=>{if(Object.hasOwn(stubs,a.path))return {path:a.path,namespace:'stub'}});b.onLoad({filter:/.*/,namespace:'stub'},a=>({contents:stubs[a.path],loader:'js'}))}}]});
const route=(await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`)).default;
test('requires login and returns a private generated message reference',async()=>{
 const denied={headers:{},id:'id',called:0};await assert.rejects(()=>route(denied),/401/);assert.equal(denied.called,0);assert.equal(denied.headers['Cache-Control'],'private, no-store');
 const message={message_id:'m',conversation_id:'id',sequence_no:2,role:'assistant'};
 const event={headers:{},id:'id',user:true,called:0,result:message,body:{model:'attacker'}};
 assert.deepEqual((await route(event)).data,{status:'generated',message});assert.equal(event.called,1);
});
test('distinguishes missing evidence and rejects incorrect context',async()=>{
 const event={headers:{},id:'id',user:true,called:0,result:{message:null}};
 assert.deepEqual((await route(event)).data,{status:'insufficient_evidence',message:null});
 event.fail='INVALID_CONTEXT';await assert.rejects(()=>route(event),/400/);
});
