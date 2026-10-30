import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';

const root=fileURLToPath(new URL('../',import.meta.url));
const built=await build({stdin:{contents:`export * from './server/services/ai/knowledge-turn.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm'});
const {runKnowledgeTurn}=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
const source={kind:'post',id:1,post_id:1,content:'公开内容',version:'a'.repeat(64)};
const candidate={kind:'post',id:1,version:'a'.repeat(64)};

test('revalidates discovery before inference and every used source before returning',async()=>{
 const events=[];
 const result=await runKnowledgeTurn({
  async discover(){events.push('discover');return [source]},
  async hydrate(input){events.push('hydrate');assert.deepEqual(input,[candidate]);return [source]},
  async infer(input){events.push('infer');assert.deepEqual(input,[source]);return 'answer'}
 });
 assert.deepEqual(events,['discover','hydrate','infer','hydrate']);
 assert.deepEqual(result,{answer:'answer',sources:[candidate]});
});
test('stale discovery never reaches the model, and no evidence returns without inference',async()=>{
 let inferred=false;
 const result=await runKnowledgeTurn({async discover(){return [source]},async hydrate(){return []},async infer(){inferred=true;return 'answer'}});
 assert.equal(inferred,false);assert.deepEqual(result,{answer:null,sources:[]});
});
test('withholds model output if any used source changes, is removed or permission is revoked',async()=>{
 let reads=0;
 await assert.rejects(()=>runKnowledgeTurn({async discover(){return [source]},async hydrate(){return ++reads===1?[source]:[]},async infer(){return 'private result'}}),/SOURCE_CHANGED/);
});
test('cancellation and unexpected hydrated source fail closed',async()=>{
 const controller=new AbortController();controller.abort();
 await assert.rejects(()=>runKnowledgeTurn({async discover(){throw Error('must not call')},async hydrate(){return []},async infer(){return ''}},controller.signal),/CANCELLED/);
 await assert.rejects(()=>runKnowledgeTurn({async discover(){return [source]},async hydrate(){return [{...source,id:2}]},async infer(){return ''}}),/INVALID_SOURCE/);
 await assert.rejects(()=>runKnowledgeTurn({async discover(){return [source,source]},async hydrate(){throw Error('must not call')},async infer(){return ''}}),/INVALID_SOURCE/);
 const during=new AbortController();
 await assert.rejects(()=>runKnowledgeTurn({async discover(){return [source]},async hydrate(){return [source]},async infer(){during.abort();return 'answer'}},during.signal),/CANCELLED/);
});
