import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';
import {readFileSync} from 'node:fs';
const root=fileURLToPath(new URL('../',import.meta.url));
const built=await build({stdin:{contents:`export * from './server/services/ai/knowledge-citations.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm'});
const {parseKnowledgeAnswer}=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
const source={kind:'post',id:1,version:'a'.repeat(64)};
test('accepts only verified fixed-ID terms citations',()=>{
 const terms={kind:'terms',id:3,version:'b'.repeat(64)};
 assert.deepEqual(parseKnowledgeAnswer(JSON.stringify({answer:'条款',citations:[terms]}),[terms]),{answer:'条款',sources:[terms]});
 assert.throws(()=>parseKnowledgeAnswer(JSON.stringify({answer:'条款',citations:[{...terms,id:9}]}),[{...terms,id:9}]),/INVALID_CITATIONS/);
});
test('matches shared cross-backend citation vectors',()=>{
 const vectors=JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-knowledge-citation-vectors.json',import.meta.url),'utf8'));
 for(const row of vectors.cases) {
  if(row.accepted) assert.ok(parseKnowledgeAnswer(row.output,vectors.verified).answer,row.id);
  else assert.throws(()=>parseKnowledgeAnswer(row.output,vectors.verified),/INVALID_CITATIONS/,row.id);
 }
});
test('returns only explicitly cited sources from the verified set',()=>{
 assert.deepEqual(parseKnowledgeAnswer(JSON.stringify({answer:'答案',citations:[source]}),[source,{kind:'comment',id:2,version:'b'.repeat(64)}]),{answer:'答案',sources:[source]});
});
test('rejects fabricated, duplicate, malformed and unsupported citations',()=>{
 for(const citations of [[],[{...source,id:2}],[{...source,version:'b'.repeat(64)}],[source,source],[{...source,extra:'x'}]]) {
  assert.throws(()=>parseKnowledgeAnswer(JSON.stringify({answer:'答案',citations}),[source]),/INVALID_CITATIONS/);
 }
 for(const text of ['answer','{}',JSON.stringify({answer:'',citations:[source]}),JSON.stringify({answer:'答案',citations:[source],extra:true})]) assert.throws(()=>parseKnowledgeAnswer(text,[source]),/INVALID_CITATIONS/);
});
