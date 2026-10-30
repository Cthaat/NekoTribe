import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const built=await build({stdin:{contents:`export * from './server/services/ai/knowledge-history.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm'});
const {encodeKnowledgeMessage,restoreKnowledgeMessage}=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
const source={kind:'post',id:1,version:'a'.repeat(64)};
test('mixed post and terms citations restore without inventing post identifiers',async()=>{
 const terms={kind:'terms',id:3,version:'b'.repeat(64)};
 const encoded=encodeKnowledgeMessage({answer:'回答',sources:[source,terms]});
 const rows=[{...source,post_id:1,content:'帖子'},{...terms,content:'条款正文'}];
 const result=await restoreKnowledgeMessage(encoded,async()=>rows);
 assert.deepEqual(result.citations,[{...source,post_id:1},terms]);
 await assert.rejects(()=>restoreKnowledgeMessage(encoded,async()=>[rows[0]]),/SOURCE_CHANGED/);
 await assert.rejects(()=>restoreKnowledgeMessage(encoded,async()=>[rows[0],{...rows[1],post_id:3}]),/SOURCE_CHANGED/);
 assert.throws(()=>encodeKnowledgeMessage({answer:'x',sources:[{...terms,id:9}]}),/INVALID_HISTORY/);
});
test('restores only currently authorized citations and preserves answer',async()=>{
 const encoded=encodeKnowledgeMessage({answer:'答案',sources:[source]});
 const result=await restoreKnowledgeMessage(encoded,async refs=>{assert.deepEqual(refs,[source]);return [{...source,post_id:1,content:'当前公开资料'}]});
 assert.deepEqual(result,{answer:'答案',sources:[source],citations:[{...source,post_id:1}]});
});
test('restored comment citations identify the authorized parent without exposing source text',async()=>{
 const comment={kind:'comment',id:23,version:'b'.repeat(64)};
 const encoded=encodeKnowledgeMessage({answer:'回答',sources:[comment]});
 const result=await restoreKnowledgeMessage(encoded,async()=>[{...comment,post_id:99,content:'公开评论'}]);
 assert.deepEqual(result.citations,[{...comment,post_id:99}]);assert.ok(!JSON.stringify(result).includes('公开评论'));
 await assert.rejects(()=>restoreKnowledgeMessage(encoded,async()=>[{...comment,post_id:0,content:'公开评论'}]),/SOURCE_CHANGED/);
});
test('withholds persisted answer when a reference changes or is no longer visible',async()=>{
 const encoded=encodeKnowledgeMessage({answer:'秘密派生',sources:[source]});
 await assert.rejects(()=>restoreKnowledgeMessage(encoded,async()=>[]),/SOURCE_CHANGED/);
 await assert.rejects(()=>restoreKnowledgeMessage(encoded,async()=>[{...source,version:'b'.repeat(64),post_id:1,content:'新'}]),/SOURCE_CHANGED/);
});
test('transitive historical dependency prevents restoring an answer after the old source is revoked',async()=>{
 const old={kind:'comment',id:23,version:'b'.repeat(64)};
 const encoded=encodeKnowledgeMessage({answer:'derived answer',sources:[source,old]});
 await assert.rejects(()=>restoreKnowledgeMessage(encoded,async()=>[{...source,post_id:1,content:'still public'}]),/SOURCE_CHANGED/);
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
