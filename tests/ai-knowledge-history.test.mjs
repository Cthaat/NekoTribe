import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const built=await build({stdin:{contents:`export * from './server/services/ai/knowledge-history.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm'});
const {encodeKnowledgeMessage,restoreKnowledgeMessage}=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
const source={kind:'post',id:1,version:'a'.repeat(64)};
test('restores only currently authorized citations and preserves answer',async()=>{
 const encoded=encodeKnowledgeMessage({answer:'答案',sources:[source]});
 const result=await restoreKnowledgeMessage(encoded,async refs=>{assert.deepEqual(refs,[source]);return [{...source,post_id:1,content:'当前公开资料'}]});
 assert.deepEqual(result,{answer:'答案',sources:[source]});
});
test('withholds persisted answer when a reference changes or is no longer visible',async()=>{
 const encoded=encodeKnowledgeMessage({answer:'秘密派生',sources:[source]});
 await assert.rejects(()=>restoreKnowledgeMessage(encoded,async()=>[]),/SOURCE_CHANGED/);
 await assert.rejects(()=>restoreKnowledgeMessage(encoded,async()=>[{...source,version:'b'.repeat(64),post_id:1,content:'新'}]),/SOURCE_CHANGED/);
});
test('invalid, missing or duplicate stored references never become visible',async()=>{
 let called=false;
 for(const raw of ['text',JSON.stringify({version:1,answer:'text',sources:[]}),JSON.stringify({version:1,answer:'text',sources:[source,source]})]) {
  await assert.rejects(()=>restoreKnowledgeMessage(raw,async()=>{called=true;return []}),/INVALID_HISTORY/);
 }
 assert.equal(called,false);
});
test('storage payload excludes source text and enforces encoded size',()=>{
 const encoded=encodeKnowledgeMessage({answer:'答案',sources:[source]});
 assert.deepEqual(Object.keys(JSON.parse(encoded)),['version','answer','sources']);
 assert.throws(()=>encodeKnowledgeMessage({answer:'x'.repeat(65536),sources:[source]}),/INVALID_HISTORY/);
});
