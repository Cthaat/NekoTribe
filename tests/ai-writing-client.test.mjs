import assert from 'node:assert/strict';
import { test } from 'node:test';
import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';

const root=fileURLToPath(new URL('../',import.meta.url));
const compiled=await build({stdin:{contents:`export * from './app/services/ai-writing-controller.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm'});
const {createWritingController,initialWritingState}=await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);

function fixture() {
  const state=initialWritingState(), messages=[];
  let appends=0,generations=0,failGeneration=true;
  const api={
    async create(){return {conversation_id:'id'}},
    async append(id,content){appends++;messages.push({message_id:'u',sequence_no:1,role:'user',content})},
    async generate(){generations++;if(failGeneration){failGeneration=false;throw Error('timeout')}messages.push({message_id:'a',sequence_no:2,role:'assistant',content:'draft'})},
    async messages(id,after){return messages.filter(m=>m.sequence_no>after)},
    async list(){return {items:[{conversation_id:'id',purpose:'writing',title:'draft',updated_at:'today'}],next_cursor:null}},
    async remove(){messages.length=0}
  };
  return {state,controller:createWritingController(api,state),stats:()=>({appends,generations})};
}
test('failed generation can be retried without appending user message again',async()=>{
  const f=fixture();f.state.draft='request';await f.controller.send();
  assert.equal(f.state.error,'generation');assert.equal(f.state.refreshRequired,true);
  await f.controller.retry();
  assert.deepEqual(f.stats(),{appends:1,generations:2});assert.equal(f.state.messages.at(-1).content,'draft');
});
test('existing conversation can be selected and deleted',async()=>{
  const f=fixture();await f.controller.loadHistory();assert.equal(f.state.history[0].title,'draft');
  await f.controller.select('id');assert.equal(f.state.id,'id');
  await f.controller.remove();assert.equal(f.state.id,null);assert.deepEqual(f.state.messages,[]);
});
test('unknown append is never automatically repeated and requires refresh',async()=>{
  const state=initialWritingState();let appends=0;
  const api={async create(){return {conversation_id:'id'}},async append(){appends++;throw Error('timeout')},async generate(){throw Error('unexpected')},async messages(){return []},async list(){return {items:[],next_cursor:null}},async remove(){}};
  const controller=createWritingController(api,state);state.draft='request';await controller.send();await controller.send();
  assert.equal(appends,1);assert.equal(state.refreshRequired,true);assert.equal(state.error,'append-unknown');
  await controller.retry(false);assert.equal(state.refreshRequired,false);assert.equal(state.draft,'request');
});
test('failed delete preserves current conversation and reports uncertainty',async()=>{
  const state=initialWritingState();state.id='id';state.messages=[{message_id:'a',sequence_no:1,role:'assistant',content:'draft'}];
  const api={async create(){return {conversation_id:'id'}},async append(){},async generate(){},async messages(){return []},async list(){return {items:[],next_cursor:null}},async remove(){throw Error('timeout')}};
  await createWritingController(api,state).remove();assert.equal(state.id,'id');assert.equal(state.messages[0].content,'draft');assert.equal(state.error,'delete-unknown');
});
