import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const built=await build({stdin:{contents:`export * from './server/services/ai/knowledge-citations.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm'});
const {parseKnowledgeAnswer}=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
const source={kind:'post',id:1,version:'a'.repeat(64)};
test('returns only explicitly cited sources from the verified set',()=>{
 assert.deepEqual(parseKnowledgeAnswer(JSON.stringify({answer:'答案',citations:[source]}),[source,{kind:'comment',id:2,version:'b'.repeat(64)}]),{answer:'答案',sources:[source]});
});
test('rejects fabricated, duplicate, malformed and unsupported citations',()=>{
 for(const citations of [[],[{...source,id:2}],[{...source,version:'b'.repeat(64)}],[source,source],[{...source,extra:'x'}]]) {
  assert.throws(()=>parseKnowledgeAnswer(JSON.stringify({answer:'答案',citations}),[source]),/INVALID_CITATIONS/);
 }
 for(const text of ['answer','{}',JSON.stringify({answer:'',citations:[source]}),JSON.stringify({answer:'答案',citations:[source],extra:true})]) assert.throws(()=>parseKnowledgeAnswer(text,[source]),/INVALID_CITATIONS/);
});
