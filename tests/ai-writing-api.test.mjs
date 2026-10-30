import assert from 'node:assert/strict';
import { test } from 'node:test';
import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const built=await build({stdin:{contents:`export {writingApi} from './app/api/v2/ai-writing.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'v2-boundary',setup(b){
  b.onResolve({filter:/^\.\/client$/},()=>({path:'client',namespace:'stub'}));
  b.onLoad({filter:/.*/,namespace:'stub'},()=>({contents:`export async function v2RequestData(path, options){globalThis.__aiWritingCalls.push({path,options});return {};}`,loader:'js'}));
}}]});
const {writingApi}=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
test('writing client uses the shared v2 API contract',async()=>{
  globalThis.__aiWritingCalls=[];
  await writingApi.create();await writingApi.append('abc','draft');await writingApi.generate('abc');
  await writingApi.messages('abc',12);await writingApi.list('cursor');await writingApi.remove('abc');
  assert.deepEqual(globalThis.__aiWritingCalls,[
    {path:'/api/v2/ai/conversations',options:{method:'POST',body:{purpose:'writing'}}},
    {path:'/api/v2/ai/conversations/abc/messages',options:{method:'POST',body:{content:'draft'}}},
    {path:'/api/v2/ai/conversations/abc/generate',options:{method:'POST'}},
    {path:'/api/v2/ai/conversations/abc/messages',options:{query:{after_sequence:12,limit:50}}},
    {path:'/api/v2/ai/conversations',options:{query:{after_id:'cursor',limit:50}}},
    {path:'/api/v2/ai/conversations/abc',options:{method:'DELETE'}}
  ]);
  delete globalThis.__aiWritingCalls;
});
