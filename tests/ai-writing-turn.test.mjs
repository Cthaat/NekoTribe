import assert from 'node:assert/strict';
import {test} from 'node:test';
import {AiModelRouter} from '../server/services/ai/model-configuration.ts';
import {runWritingTurn} from '../server/services/ai/writing-turn.ts';
import {readFileSync} from 'node:fs';
import {createServer} from 'node:http';
import {AiInferenceTransport} from '../server/services/ai/inference-transport.ts';
import {listenForFetch} from './helpers/loopback-listener.mjs';

const fixture=JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-model-config.json',import.meta.url)));
const config=fixture.cases.find(x=>x.config && !x.expectedError).config;
function boundaries() {
  let writes=0,calls=0,loaded=0,request;
  const state={
    router:new AiModelRouter(config),
    async load(){loaded++;return {purpose:'writing',messages:[
      {sequence_no:1,role:'user',content:'hello'},
      {sequence_no:2,role:'assistant',content:'draft'},
      {sequence_no:3,role:'user',content:'improve'}]};},
    async infer(selection,input){calls++;request={selection,input};return {text:'revised',toolCalls:[],finishReason:'stop'};},
    async write(data){writes++;return {message_id:'id',sequence_no:4,...data};},
    counts:()=>({writes,calls,loaded,request})
  };
  return state;
}
test('writing selects one model snapshot and saves reply after inference',async()=>{
  const deps=boundaries();
  const result=await runWritingTurn(deps);
  const c=deps.counts();assert.equal(c.loaded,1);assert.equal(c.calls,1);assert.equal(c.writes,1);
  assert.equal(result.expectedSequence,3);assert.equal(result.content,'revised');
  assert.equal(result.modelId,c.request.selection.profileId);
  assert.equal(result.configRevision,c.request.selection.configurationRevision);
  assert.deepEqual(c.request.input.messages.slice(1).map(x=>x.content),['hello','draft','improve']);
});
test('rejects unsupported conversation purpose and unsafe history before calling provider',async()=>{
  for (const history of [
    {purpose:'knowledge',messages:[{sequence_no:1,role:'user',content:'q'}]},
    {purpose:'writing',messages:[{sequence_no:1,role:'tool',content:'data'}]},
    {purpose:'writing',messages:[{sequence_no:1,role:'assistant',content:'draft'}]},
    {purpose:'writing',messages:[]}
  ]) {
    const deps=boundaries();deps.load=async()=>history;
    await assert.rejects(()=>runWritingTurn(deps));
    assert.equal(deps.counts().calls,0);assert.equal(deps.counts().writes,0);
  }
});
test('provider failure or non-final reply never writes an assistant message',async()=>{
  for (const infer of [async()=>{throw Error('private provider failure')},async()=>({text:'partial',toolCalls:[],finishReason:'length'})]) {
    const deps=boundaries();deps.infer=infer;
    await assert.rejects(()=>runWritingTurn(deps));
    assert.equal(deps.counts().writes,0);
  }
});
test('oversized last message and cancellation do not call provider or write',async()=>{
  const deps=boundaries();
  deps.load=async()=>({purpose:'writing',messages:[{sequence_no:1,role:'user',content:'x'.repeat(20000)}]});
  await assert.rejects(()=>runWritingTurn(deps),error=>error.code==='CONTEXT_TOO_LARGE');
  assert.equal(deps.counts().calls,0);assert.equal(deps.counts().writes,0);
  const controller=new AbortController();controller.abort();
  await assert.rejects(()=>runWritingTurn(boundaries(),controller.signal),error=>error.code==='CANCELLED');
});

test('writing turn connects through the real inference transport to a loopback provider',async()=>{
  let received;
  const server=createServer(async(req,res)=>{
    let body='';for await(const chunk of req)body+=chunk;received=JSON.parse(body);
    res.writeHead(200,{'content-type':'application/json'});
    res.end(JSON.stringify({choices:[{index:0,finish_reason:'stop',message:{role:'assistant',content:'修改后的草稿'}}]}));
  });
  const origin=await listenForFetch(server);
  try {
    const selection={...new AiModelRouter(config).select('writing'),adapter:'openai-compatible',baseUrl:origin,apiKeyEnv:null};
    const deps=boundaries();deps.router={select:()=>selection};
    const transport=new AiInferenceTransport();
    deps.infer=(model,input,signal)=>transport.infer(model,input,signal);
    const result=await runWritingTurn(deps);
    assert.equal(result.content,'修改后的草稿');
    assert.equal(received.model,selection.model);
    assert.equal(received.messages.at(-1).content,'improve');
    assert.equal(deps.counts().writes,1);
  } finally {server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
});
