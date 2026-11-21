import assert from 'node:assert/strict';
import { test } from 'node:test';
import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const built=await build({stdin:{contents:`export {writingApi} from './app/api/v2/ai-writing.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'v2-boundary',setup(b){
  b.onResolve({filter:/^\.\/client$/},()=>({path:'client',namespace:'stub'}));
  b.onLoad({filter:/.*/,namespace:'stub'},()=>({contents:`
    export async function v2RequestData(path, options) {
      globalThis.__aiWritingCalls.push({path,options});
      if (path.endsWith('/generate')) return {conversation_id:'abc',message_id:'reply',sequence_no:2,role:'assistant'};
      if (path.endsWith('/messages')) {
        return options.method === 'POST' ? {conversation_id:'abc',message_id:'user',sequence_no:1,role:'user'} : [];
      }
      return {};
    }
  `,loader:'js'}));
}}]});
const {writingApi}=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
test('writing client uses the shared v2 API contract',async()=>{
  globalThis.__aiWritingCalls=[];
  const {signal} = new AbortController();
  await writingApi.create(signal);const sequence=await writingApi.append('abc','draft',signal);await writingApi.generate('abc',undefined,signal,false,sequence);
  await writingApi.messages('abc',12,signal);await writingApi.list('cursor',signal);await writingApi.remove('abc',signal);
  assert.deepEqual(globalThis.__aiWritingCalls,[
    {path:'/api/v2/ai/conversations',options:{method:'POST',body:{purpose:'writing'}}},
    {path:'/api/v2/ai/conversations/abc/messages',options:{method:'POST',body:{content:'draft'}}},
    {path:'/api/v2/ai/conversations/abc/generate',options:{method:'POST',body:{expected_sequence:1}}},
    {path:'/api/v2/ai/conversations/abc/messages',options:{query:{after_sequence:12,limit:50}}},
    {path:'/api/v2/ai/conversations',options:{query:{after_id:'cursor',limit:50,purpose:'writing'}}},
    {path:'/api/v2/ai/conversations/abc',options:{method:'DELETE'}}
  ].map(({path,options})=>({path,options:{...options,signal}})));
  await assert.rejects(()=>writingApi.generate('abc',undefined,signal,false,2),/assistant sequence/);
  delete globalThis.__aiWritingCalls;
});
