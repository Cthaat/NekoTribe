import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const built=await build({stdin:{contents:`export * from './server/services/ai/knowledge-context.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm'});
const {selectKnowledgeContext}=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
const ref={kind:'post',id:1,version:'a'.repeat(64),post_id:1};
const messages=[{sequence_no:1,role:'user',content:'之前的问题'}, {sequence_no:2,role:'assistant',content:'之前的回答',citations:[ref]}, {sequence_no:3,role:'user',content:'新的问题'}];
test('selects history and current question while collecting authorized citation guards',()=>{
 const result=selectKnowledgeContext(messages,10000);
 assert.deepEqual(result,{question:'新的问题',history:[{role:'user',content:'之前的问题'},{role:'assistant',content:'之前的回答'}],sources:[{kind:'post',id:1,version:ref.version}]});
});
test('truncates only from oldest history and never omits current question',()=>{
 const result=selectKnowledgeContext(messages,110);
 assert.equal(result.question,'新的问题');assert.ok(result.history.length<2);
 assert.throws(()=>selectKnowledgeContext(messages,1),/CONTEXT_TOO_LARGE/);
});
test('fails closed for missing citations or contradictory source versions',()=>{
 assert.throws(()=>selectKnowledgeContext([messages[0],{...messages[1],citations:[]},messages[2]],10000),/INVALID_CONTEXT/);
 assert.throws(()=>selectKnowledgeContext([messages[0],{...messages[1],citations:[ref,ref]},messages[2]],10000),/INVALID_CONTEXT/);
 const bad=[messages[0],messages[1],{sequence_no:3,role:'assistant',content:'another',citations:[{...ref,version:'b'.repeat(64)}]},{sequence_no:4,role:'user',content:'question'}];
 assert.throws(()=>selectKnowledgeContext(bad,10000),/INVALID_CONTEXT/);
});
test('bounds source guards and counts encoded JSON bytes including escapes',()=>{
 const refs=Array.from({length:20},(_,i)=>({...ref,id:i+1,post_id:i+1}));
 const more={kind:'comment',id:25,version:'b'.repeat(64),post_id:3};
 const input=[{sequence_no:1,role:'assistant',content:'older',citations:[more]},{sequence_no:2,role:'assistant',content:'newer',citations:refs},{sequence_no:3,role:'user',content:'"\\'.repeat(10)}];
 const result=selectKnowledgeContext(input,10000);assert.equal(result.history.length,1);assert.equal(result.sources.length,20);
 const serialized=JSON.stringify({question:input[2].content,history:[]});const byteLength=Buffer.byteLength(serialized);
 assert.throws(()=>selectKnowledgeContext(input,byteLength-1),/CONTEXT_TOO_LARGE/);
 assert.equal(selectKnowledgeContext(input,byteLength).history.length,0);
});
test('reserves source capacity for newly retrieved evidence',()=>{
 const selected=selectKnowledgeContext(messages,10000,0);
 assert.equal(selected.question,'新的问题');assert.deepEqual(selected.history,[]);assert.deepEqual(selected.sources,[]);
});
