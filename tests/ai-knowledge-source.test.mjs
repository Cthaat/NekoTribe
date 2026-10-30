import assert from 'node:assert/strict';
import { test } from 'node:test';
import { build } from 'esbuild';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const stubs={
  oracledb:`export default {OUT_FORMAT_OBJECT:4002,STRING:{num:2001}};`,
  '~/server/utils/v2':`export const v2Auth=e=>{if(!e.userId)throw Error('401');return {userId:e.userId}};export const v2BadRequest=()=>{throw Error('400')};export const v2ServerError=()=>{throw Error('500')};`
};
const built=await build({stdin:{contents:`export * from './server/services/ai/knowledge-source.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'knowledge-stubs',setup(b){b.onResolve({filter:/.*/},a=>{if(Object.hasOwn(stubs,a.path))return {path:a.path,namespace:'stub'}});b.onLoad({filter:/.*/,namespace:'stub'},a=>({contents:stubs[a.path],loader:'js'}))}}]});
const {sourceVersion,hydrateKnowledgeSources}=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);

test('source fingerprints match shared cross-language vectors',()=>{
  const vectors=JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-knowledge-source-vectors.json',import.meta.url),'utf8'));
  for(const row of vectors.cases) assert.equal(sourceVersion(row.kind,row.source_id,row.post_id,row.content),row.version,row.id);
});

test('current public sources are reloaded with owner-independent public and viewer checks',async()=>{
  const calls=[];const db={async execute(sql,binds,options){calls.push({sql,binds});assert.match(sql,/p\.visibility\s*=\s*'public'/i);assert.match(sql,/p\.is_deleted\s*=\s*0/i);assert.match(sql,/DBMS_LOB\.GETLENGTH\(p\.content\) BETWEEN 1 AND 65536/i);assert.match(sql,/fn_can_view_post\(:viewer_id\s*,\s*p\.post_id\)\s*=\s*1/i);assert.deepEqual(options.fetchTypeHandler({name:'CONTENT'}),{type:{num:2001}});return {rows:[{SOURCE_ID:11,POST_ID:11,CONTENT:'public post'}]}}};
  const version=sourceVersion('post',11,11,'public post');
  const out=await hydrateKnowledgeSources({userId:42},db,[{kind:'post',id:11,version}]);
  assert.equal(calls[0].binds.viewer_id,42);assert.equal(out[0].content,'public post');assert.equal(out[0].version,version);
});
test('stale, inaccessible and deleted sources are omitted instead of exposing indexed content',async()=>{
  const db={async execute(sql,binds){assert.match(sql,/c\.is_deleted\s*=\s*0/i);return binds.source_id===21?{rows:[{SOURCE_ID:21,POST_ID:11,CONTENT:'edited'}]}:{rows:[]}}};
  const before=sourceVersion('comment',21,11,'old');
  const out=await hydrateKnowledgeSources({userId:42},db,[{kind:'comment',id:21,version:before},{kind:'comment',id:22,version:'0'.repeat(64)}]);
  assert.deepEqual(out,[]);
});
test('source hydration rejects unauthenticated, invalid and duplicate candidates',async()=>{
  const db={execute(){throw Error('must not query')}};
  const candidate={kind:'post',id:11,version:'0'.repeat(64)};
  await assert.rejects(()=>hydrateKnowledgeSources({},db,[candidate]),/401/);
  await assert.rejects(()=>hydrateKnowledgeSources({userId:42},db,[candidate,candidate]),/400/);
  await assert.rejects(()=>hydrateKnowledgeSources({userId:42},db,[{...candidate,id:0}]),/400/);
});
test('oversized and empty content are omitted while corrupt database rows fail closed',async()=>{
  const actor={userId:42}, valid={kind:'post',id:11,version:'0'.repeat(64)};
  for(const content of ['', '猫'.repeat(21846)]) {
    const db={async execute(){return {rows:[{SOURCE_ID:11,POST_ID:11,CONTENT:content}]}}};
    assert.deepEqual(await hydrateKnowledgeSources(actor,db,[valid]),[]);
  }
  for(const row of [{SOURCE_ID:11,POST_ID:11,CONTENT:'\ud800'},{SOURCE_ID:12,POST_ID:12,CONTENT:'text'}]) {
    const db={async execute(){return {rows:[row]}}};
    await assert.rejects(()=>hydrateKnowledgeSources(actor,db,[valid]),/500/);
  }
});
