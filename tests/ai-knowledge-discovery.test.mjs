import assert from 'node:assert/strict';
import { test } from 'node:test';
import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const stubs = {
  oracledb: `export default {OUT_FORMAT_OBJECT:4002,STRING:{num:2001}};`,
  '~/server/utils/v2': `export const v2Auth=e=>{if(!e.userId)throw Error('401');return {userId:e.userId}};export const v2BadRequest=()=>{throw Error('400')};export const v2ServerError=()=>{throw Error('500')};`
};
const built = await build({stdin:{contents:`export * from './server/services/ai/knowledge-source.ts'`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'discovery-stubs',setup(b){b.onResolve({filter:/.*/},a=>{if(Object.hasOwn(stubs,a.path))return {path:a.path,namespace:'stub'}});b.onLoad({filter:/.*/,namespace:'stub'},a=>({contents:stubs[a.path],loader:'js'}))}}]});
const {discoverKnowledgeSources,sourceVersion} = await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);

test('discovers public matching posts and comments using viewer-bound queries', async () => {
  const calls=[];
  const db={async execute(sql,binds,options){
    calls.push({sql,binds});
    assert.match(sql,/p\.visibility\s*=\s*'public'/i);
    assert.match(sql,/p\.is_deleted\s*=\s*0/i);
    assert.match(sql,/fn_can_view_post\(:viewer_id\s*,\s*p\.post_id\)\s*=\s*1/i);
    assert.match(sql,/DBMS_LOB\.INSTR\([^,]+,\s*:term\)\s*>\s*0/i);
    assert.match(sql,/DBMS_LOB\.GETLENGTH\([^)]+\) BETWEEN 1 AND 65536/i);
    assert.deepEqual(options.fetchTypeHandler({name:'CONTENT'}),{type:{num:2001}});
    assert.equal(binds.viewer_id,42); assert.equal(binds.term,'猫'); assert.equal(binds.row_limit,2);
    if (/FROM n_comments/i.test(sql)) { assert.match(sql,/c\.is_deleted\s*=\s*0/i); return {rows:[{SOURCE_ID:21,POST_ID:11,CONTENT:'评论猫'}]}; }
    return {rows:[{SOURCE_ID:11,POST_ID:11,CONTENT:'帖子猫'},{SOURCE_ID:10,POST_ID:10,CONTENT:'旧帖子猫'}]};
  }};
  const result=await discoverKnowledgeSources({userId:42},db,' 猫 ',2);
  assert.equal(calls.length,2);
  assert.deepEqual(result,[{kind:'post',id:11,post_id:11,content:'帖子猫',version:sourceVersion('post',11,11,'帖子猫')},{kind:'comment',id:21,post_id:11,content:'评论猫',version:sourceVersion('comment',21,11,'评论猫')}]);
});

test('rejects unauthorized and invalid searches without querying',async()=>{
  const db={execute(){throw Error('must not query')}};
  await assert.rejects(()=>discoverKnowledgeSources({},db,'test',1),/401/);
  for(const [term,limit] of [['',1],['\u0000test',1],['x'.repeat(257),1],['\ud800',1],['ok',0],['ok',21],['ok',1.5]]) {
    await assert.rejects(()=>discoverKnowledgeSources({userId:42},db,term,limit),/400/);
  }
});

test('omits oversized sources and rejects corrupt or duplicate rows',async()=>{
  const actor={userId:42};
  const withRows=rows=>({async execute(sql){return {rows:/FROM n_comments/i.test(sql)?[]:rows}}});
  assert.deepEqual(await discoverKnowledgeSources(actor,withRows([{SOURCE_ID:1,POST_ID:1,CONTENT:'猫'.repeat(21846)}]),'猫',2),[]);
  for(const rows of [[{SOURCE_ID:1,POST_ID:2,CONTENT:'text'}],[{SOURCE_ID:1,POST_ID:1,CONTENT:'\ud800'}],[{SOURCE_ID:1,POST_ID:1,CONTENT:'a'},{SOURCE_ID:1,POST_ID:1,CONTENT:'a'}]]) {
    await assert.rejects(()=>discoverKnowledgeSources(actor,withRows(rows),'text',2),/500/);
  }
});
