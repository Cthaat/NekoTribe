import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {Readable} from 'node:stream';
const root=fileURLToPath(new URL('../',import.meta.url));
const built=await build({stdin:{contents:`export * from './server/services/ai/knowledge-search-body.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm'});
const {parseKnowledgeSearchBody,readKnowledgeSearchBody}=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
const vectors=JSON.parse(await readFile(new URL('../specifications/scenarios/ai-knowledge-search-body.json',import.meta.url),'utf8'));
test('shared search body vectors preserve compatibility and reject invalid input',()=>{
 for(const item of vectors.cases) {
   const bytes=Buffer.from(item.body,'utf8');
   if(item.accepted) assert.equal(parseKnowledgeSearchBody(bytes),item.phrase,item.id);
   else assert.throws(()=>parseKnowledgeSearchBody(bytes),undefined,item.id);
 }
});
test('streaming reads enforce the actual byte limit without relying on headers',async()=>{
 assert.equal(await readKnowledgeSearchBody(Readable.from([Buffer.from('{"search_'),Buffer.from('phrase":"猫"}')])), '猫');
 await assert.rejects(()=>readKnowledgeSearchBody(Readable.from([Buffer.alloc(2048),Buffer.alloc(2049)])));
});
test('enforces UTF-8 and byte limits',()=>{
 assert.throws(()=>parseKnowledgeSearchBody(Buffer.from([0xff])));
 assert.throws(()=>parseKnowledgeSearchBody(Buffer.alloc(4097,32)));
 assert.equal(parseKnowledgeSearchBody(Buffer.from(JSON.stringify({search_phrase:'猫'.repeat(85)}))),'猫'.repeat(85));
 assert.throws(()=>parseKnowledgeSearchBody(Buffer.from(JSON.stringify({search_phrase:'猫'.repeat(86)}))));
});
