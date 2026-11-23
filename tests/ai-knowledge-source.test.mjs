import assert from 'node:assert/strict';
import { test } from 'node:test';
import { build } from 'esbuild';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const stubs={
  oracledb:`export default {OUT_FORMAT_OBJECT:4002,STRING:{num:2001}};`,
  '~/server/database/readiness':`export const requireFeatureSchema=async()=>{};`,
  '~/server/utils/v2':`export const v2Auth=e=>{if(!e.userId)throw Error('401');return {userId:e.userId}};export const v2BadRequest=()=>{throw Error('400')};export const v2ServerError=()=>{throw Error('500')};export const v2Forbidden=()=>{throw Error('403')};export const v2Conflict=()=>{throw Error('409')}; export const v2One=async(c,sql,binds)=>(await c.execute(sql,binds)).rows?.[0];`
};
const built=await build({stdin:{contents:`export * from './server/services/ai/knowledge-source.ts';export {encodeKnowledgeMessage,restoreKnowledgeMessage} from './server/services/ai/knowledge-history.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'knowledge-stubs',setup(b){b.onResolve({filter:/.*/},a=>{if(Object.hasOwn(stubs,a.path))return {path:a.path,namespace:'stub'}});b.onLoad({filter:/.*/,namespace:'stub'},a=>({contents:stubs[a.path],loader:'js'}))}}]});
const {sourceVersion,hydrateKnowledgeSources,encodeKnowledgeMessage,restoreKnowledgeMessage}=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);

test('source fingerprints match shared cross-language vectors',()=>{
  const vectors=JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-knowledge-source-vectors.json',import.meta.url),'utf8'));
  for(const row of vectors.cases) assert.equal(sourceVersion(row.kind,row.source_id,row.post_id,row.content),row.version,row.id);
});
test('group sources use their own public authority and omit stale or unavailable rows', async () => {
  const actor = {userId:42};
  const candidate = {kind:'group_comment', id:21, version:sourceVersion('group_comment',21,11,'comment')};
  let rows = [{SOURCE_ID:21,POST_ID:11,GROUP_ID:7,CONTENT:'comment'}];
  const db = {async execute(sql, binds) {
    assert.match(sql, /FROM n_group_comments c/);
    assert.match(sql, /g\.privacy='public' AND g\.is_active=1 AND g\.is_deleted=0/);
    assert.match(sql, /b\.target_user_id IN \(p\.author_id,c\.author_id\)/);
    assert.match(sql, /b\.user_id IN \(p\.author_id,c\.author_id\)/);
    assert.match(sql, /p\.post_id BETWEEN 1 AND :max_id/);
    assert.match(sql, /p\.group_id BETWEEN 1 AND :max_id/);
    assert.deepEqual(binds, {source_id:21,viewer_id:42,max_id:999_999_999_999_999});
    return {rows};
  }};
  assert.deepEqual(await hydrateKnowledgeSources(actor, db, [candidate]), [
    {...candidate,post_id:11,group_id:7,content:'comment'},
  ]);
  const stored = encodeKnowledgeMessage({answer:'group answer',sources:[candidate]});
  const restore = () => restoreKnowledgeMessage(stored, refs => hydrateKnowledgeSources(actor, db, refs));
  assert.deepEqual((await restore()).citations, [{...candidate,post_id:11,group_id:7}]);
  assert(!stored.includes('group_id'));
  rows = [{SOURCE_ID:21,POST_ID:11,GROUP_ID:7,CONTENT:'edited'}];
  assert.deepEqual(await hydrateKnowledgeSources(actor, db, [candidate]), []);
  await assert.rejects(restore, /SOURCE_CHANGED/);
  rows = [];
  assert.deepEqual(await hydrateKnowledgeSources(actor, db, [candidate]), []);
});
test('mixed term references are checked against the current shared authority',async()=>{
 const vectors=JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-public-terms-source-vectors.json',import.meta.url),'utf8'));
 const version=vectors.versions[0].version,ref={kind:'terms',id:1,version};let active=true,calls=0;
 const db={async execute(sql){calls++;assert.match(sql,/FROM\s+n_ai_terms_active/i);return {rows:active?[{CATALOG_DIGEST:vectors.catalog_digest,GENERATION:1,ENABLED:1}]:[]}}};
 const rows=await hydrateKnowledgeSources({userId:42},db,[ref]);assert.equal(rows.length,1);assert.equal(rows[0].kind,'terms');assert.equal(rows[0].id,1);assert.equal(rows[0].version,version);assert.equal(typeof rows[0].content,'string');assert(!('post_id' in rows[0]));
 active=false;await assert.rejects(()=>hydrateKnowledgeSources({userId:42},db,[ref]));assert.equal(calls,2);
});
test('term hydration rejects duplicates and omits stale versions',async()=>{
 const vectors=JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-public-terms-source-vectors.json',import.meta.url),'utf8'));
 const ref={kind:'terms',id:1,version:'0'.repeat(64)},db={async execute(){return {rows:[{CATALOG_DIGEST:vectors.catalog_digest,GENERATION:1,ENABLED:1}]}}};
 assert.deepEqual(await hydrateKnowledgeSources({userId:42},db,[ref]),[]);
 await assert.rejects(()=>hydrateKnowledgeSources({userId:42},db,[ref,ref]),/400/);
});
test('mixed stored answer is withheld when a rule is disabled',async()=>{
 const vectors=JSON.parse(readFileSync(new URL('../specifications/scenarios/ai-public-terms-source-vectors.json',import.meta.url),'utf8'));
 const post={kind:'post',id:11,version:sourceVersion('post',11,11,'post')},terms={kind:'terms',id:1,version:vectors.versions[0].version};let enabled=1;
 const db={async execute(sql){return /FROM\s+n_ai_terms_active/i.test(sql)?{rows:[{CATALOG_DIGEST:vectors.catalog_digest,GENERATION:1,ENABLED:enabled}]}:{rows:[{SOURCE_ID:11,POST_ID:11,CONTENT:'post'}]}}};
 const message=encodeKnowledgeMessage({answer:'answer',sources:[post,terms]});
 const restore=()=>restoreKnowledgeMessage(message,refs=>hydrateKnowledgeSources({userId:42},db,refs));
 assert.deepEqual((await restore()).citations,[{...post,post_id:11},terms]);enabled=0;await assert.rejects(restore);
});

test('current public sources are reloaded with owner-independent public and viewer checks',async()=>{
  const calls=[];const db={async execute(sql,binds,options){calls.push({sql,binds});assert.match(sql,/p\.visibility\s*=\s*'public'/i);assert.match(sql,/p\.is_deleted\s*=\s*0/i);assert.match(sql,/DBMS_LOB\.GETLENGTH\(p\.content\) BETWEEN 1 AND 65536/i);assert.match(sql,/fn_can_view_post\(:viewer_id\s*,\s*p\.post_id\)\s*=\s*1/i);assert.deepEqual(options.fetchTypeHandler({name:'CONTENT'}),{type:{num:2001}});return {rows:[{SOURCE_ID:11,POST_ID:11,CONTENT:'public post'}]}}};
  const version=sourceVersion('post',11,11,'public post');
  const out=await hydrateKnowledgeSources({userId:42},db,[{kind:'post',id:11,version}]);
  assert.equal(calls[0].binds.viewer_id,42);assert.equal(out[0].content,'public post');assert.equal(out[0].version,version);
});
test('stale, inaccessible and deleted sources are omitted instead of exposing indexed content',async()=>{
  const db={async execute(sql,binds){
    assert.match(sql,/c\.is_deleted\s*=\s*0/i);
    assert.match(sql,/post_author\.is_active=1/);
    assert.match(sql,/comment_author\.is_active=1/);
    assert.match(sql,/NOT EXISTS\s*\(\s*SELECT 1 FROM n_user_blocks/);
    assert.match(sql,/b\.user_id=:viewer_id AND b\.target_user_id=c\.user_id/);
    assert.match(sql,/b\.target_user_id=:viewer_id AND b\.user_id=c\.user_id/);
    return binds.source_id===21?{rows:[{SOURCE_ID:21,POST_ID:11,CONTENT:'edited'}]}:{rows:[]};
  }};
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
  for(const row of [{SOURCE_ID:11,POST_ID:11,CONTENT:'\ud800'},{SOURCE_ID:12,POST_ID:12,CONTENT:'text'},{SOURCE_ID:11,POST_ID:12,CONTENT:'text'}]) {
    const db={async execute(){return {rows:[row]}}};
    await assert.rejects(()=>hydrateKnowledgeSources(actor,db,[valid]),/500/);
  }
});
