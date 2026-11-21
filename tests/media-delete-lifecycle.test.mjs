import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {DatabaseSync} from 'node:sqlite';
import {test} from 'node:test';
import {createRequire} from 'node:module';
import {fileURLToPath,pathToFileURL} from 'node:url';
import path from 'node:path';
import {build} from 'esbuild';

const root=fileURLToPath(new URL('../',import.meta.url)),require=createRequire(import.meta.url);
const stubs={
 '~/server/storage':`export const STORAGE_MEDIA_MAX_SIZE=32; export const ensureStorageTempDir=async()=>{}; export const storePostMediaFile=async()=>{}; export const deleteStorageReference=input=>globalThis.__mediaDelete.remove(input);`,
 '~/server/models/v2':`export const v2EnsureMediaDescriptionColumn=async()=>{}; export const v2MapMedia=()=>({});`,
 './api-cache':`export const readApiResponseCache=async()=>({status:'disabled'}),writeApiResponseCache=async()=>{},invalidateApiResponseCache=async()=>{},shouldInvalidateApiResponseCache=()=>false;`,
 './logging':`export const getRequestLogContext=()=>null,logError=()=>{},logInfo=()=>{},serializeLogError=()=>({});`,
 oracledb:'export default {OUT_FORMAT_OBJECT:4002};'
};
const compiled=await build({stdin:{contents:`export {v2DeleteMedia} from './server/services/v2/media';`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'media-delete-boundaries',setup(builder){
 builder.onResolve({filter:/.*/},args=>{if(Object.hasOwn(stubs,args.path))return{path:args.path,namespace:'stub'};if(args.path.startsWith('~/'))return{path:path.join(root,`${args.path.slice(2)}.ts`)};if(args.path.startsWith('node:'))return{path:args.path,external:true};if(!args.path.startsWith('.')&&!path.isAbsolute(args.path))return{path:pathToFileURL(require.resolve(args.path)).href,external:true};});
 builder.onLoad({filter:/.*/,namespace:'stub'},args=>({contents:stubs[args.path],loader:'js'}));
}}]});
const {v2DeleteMedia}=await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);

function fixture({rows=1,exists=true,reference=false,fail=false}={}) {
 const removed=[],calls=[];
 return {removed,calls,async remove(input){removed.push(input)},async execute(sql,binds,options){
  calls.push({sql,binds,options});
  if(sql.includes('SELECT storage_key'))return{rows:exists?[{STORAGE_KEY:'post/42/a.png',PUBLIC_URL:'/storage/post/42/a.png',THUMBNAIL_URL:null}]:[]};
  if(sql.includes('SELECT 1 AS in_use'))return{rows:reference?[{IN_USE:1}]:[]};
  if(sql.includes('DELETE FROM n_media_assets'))return{rowsAffected:rows};
  throw new Error('unexpected statement');
 },async commit(){
  calls.push({commit:true});
  if(fail)throw new Error('uncertain database commit');
 },async rollback(){calls.push({rollback:true});}};
}
async function invoke(state) {
 globalThis.__mediaDelete=state;
 try{return await v2DeleteMedia({context:{auth:{userId:42}}},state,7)}finally{delete globalThis.__mediaDelete}
}
test('successful owned deletion cleans up after exactly one committed row',async()=>{
 const state=fixture();const result=await invoke(state);
 assert.equal(result.message,'media deleted');assert.equal(state.calls[2].options.autoCommit,false);
 assert.deepEqual(state.calls[2].binds,{media_id:7,user_id:42});
 assert.deepEqual(state.calls[3],{commit:true});
 assert.deepEqual(state.removed,[{storageKey:'post/42/a.png',publicUrl:'/storage/post/42/a.png'},{publicUrl:null}]);
});
test('reference check runs under the asset lock and rolls back without deleting',async()=>{
 const state=fixture({reference:true});
 await assert.rejects(invoke(state), error=>error.statusCode===409&&error.data?.code===40901);
 assert.match(state.calls[0].sql,/FOR UPDATE/);
 for(const reference of ['n_post_media','n_chat_message_media','avatar_media_id','n_groups','g.avatar_url','g.cover_url','asset.thumbnail_url']) assert.ok(state.calls[1].sql.includes(reference));
 assert.deepEqual(state.calls[2],{rollback:true});
 assert.equal(state.calls.length,3);
 assert.deepEqual(state.removed,[]);
});
test('shared SQL protects group images and group post attachments by exact URL or managed alias',()=>{
 const {checkReferences}=JSON.parse(readFileSync(new URL('../specifications/requirements/media-delete-references.json',import.meta.url),'utf8'));
 const db=new DatabaseSync(':memory:');
 try {
  db.function('REGEXP_REPLACE',(source,pattern,replacement,position,occurrence,flags)=>{
   assert.deepEqual([position,occurrence,flags],[1,0,'i']);
   return source===null?null:source.replace(new RegExp(pattern,'gi'),replacement.replace(/\\([1-9])/g,(_,group)=>'$'+group));
  });
  db.exec(`
   CREATE TABLE n_media_assets(media_id, storage_key, public_url, thumbnail_url);
   CREATE TABLE n_post_media(media_id);
   CREATE TABLE n_chat_message_media(media_id);
   CREATE TABLE n_users(avatar_media_id);
   CREATE TABLE n_groups(avatar_url, cover_url);
   CREATE TABLE n_group_posts(media_urls, is_deleted);
  `);
  const key='posts/images/42/2026/11/unique.png';
  const original=`https://cdn.example.test/custom/${key}`;
  const thumb='https://cdn.example.test/thumb/unique.png';
  db.prepare('INSERT INTO n_media_assets VALUES (7,?,?,?)').run(key,original,thumb);
  const check=db.prepare(checkReferences);
  const group=db.prepare('INSERT INTO n_groups VALUES (?,?)');
  for(const [avatar,cover,inUse] of [
   [original,null,true],
   [null,thumb,true],
   [null,` HTTPS://old.example.test:8443/uploads/${key}?cache=1#preview `,true],
   [`/upload/${key}`,null,true],
   [null,`/storage/${key}2`,false],
   [`/other/${key}`,null,false],
   [null,null,false]
  ]){
   db.exec('DELETE FROM n_groups');
   group.run(avatar,cover);
   assert.equal(Boolean(check.get({media_id:7})),inUse);
   assert.equal(check.get({media_id:99}),undefined);
  }
  const post=db.prepare('INSERT INTO n_group_posts VALUES (?,1)');
  for (const [media,inUse] of [
   [`https://external.test/a,${original},https://external.test/b`,true],
   [`https://external.test/a,${thumb}`,true],
   [`https://external.test/a, HTTPS://old.example.test:8443/uploads/${key}?cache=1#preview ,/storage/unrelated.png`,true],
   [`/upload/${key}2,/storage/else/${key}`,false],
   [`https://external.test/a?q=/storage/${key}`,false],
  ]) {
   db.exec('DELETE FROM n_group_posts');
   post.run(media);
   assert.equal(Boolean(check.get({media_id:7})),inUse);
  }
 } finally {
  db.close();
 }
});
test('missing or concurrently deleted record never removes the object',async()=>{
 for(const state of [fixture({exists:false}),fixture({rows:0})]){
  await assert.rejects(invoke(state),error=>error.statusCode===404);assert.deepEqual(state.removed,[]);
 }
});
test('unexpected row counts and uncertain commit never remove the object',async()=>{
 for(const state of [fixture({rows:2}),fixture({fail:true})]){
  await assert.rejects(invoke(state));assert.deepEqual(state.removed,[]);
 }
});
