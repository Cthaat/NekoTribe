// Real creation service and route with a transaction-aware isolated Oracle adapter.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createRequire} from 'node:module';
import {ServerResponse} from 'node:http';
import {fileURLToPath,pathToFileURL} from 'node:url';
import path from 'node:path';
import {build} from 'esbuild';
import {createEvent} from 'h3';

const root=fileURLToPath(new URL('../',import.meta.url));
const require=createRequire(import.meta.url);
const stubs={
 '~/server/models/v2': `export const v2RequirePostById = async c => c.snapshot(); const unexpected=()=>{throw new Error('unexpected model')}; export const v2CommentCount=unexpected,v2MapComment=unexpected,v2MapPost=unexpected,v2MapPublicUser=unexpected,v2PostCountSql=unexpected,v2PostSelectSql=unexpected,v2SortOrder=unexpected;`,
 './notifications': `export const v2CreateNotification=async (c,n)=>{c.notices.push(n);if(c.failNotification)throw new Error('private notification error')};`,
 './api-cache': 'export const readApiResponseCache=async()=>({status:"disabled"});export const writeApiResponseCache=async()=>{};export const invalidateApiResponseCache=async()=>{};export const shouldInvalidateApiResponseCache=()=>false;',
 './logging':'export const getRequestLogContext=()=>null;export const logError=()=>{};export const logInfo=()=>{};export const serializeLogError=()=>({});',
 oracledb:'export default {OUT_FORMAT_OBJECT:4002};'
};
const compiled=await build({stdin:{contents:`export {default as create} from './server/api/v2/posts/index.post';`,resolveDir:root,loader:'ts'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'boundaries',setup(builder){
 builder.onResolve({filter:/.*/},args=>{if(Object.hasOwn(stubs,args.path))return{path:args.path,namespace:'stub'};if(args.path.startsWith('~/'))return{path:path.join(root,`${args.path.slice(2)}.ts`)};if(args.path.startsWith('node:'))return{path:args.path,external:true};if(!args.path.startsWith('.')&&!path.isAbsolute(args.path))return{path:pathToFileURL(require.resolve(args.path)).href,external:true};});
 builder.onLoad({filter:/.*/,namespace:'stub'},args=>({contents:stubs[args.path],loader:'js'}));
}}]});
const routes=await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);

function database({media=[11],failAt='',failNotification=false,failCommit=false,failRollback=false}={}){
 const db={pending:[],committed:[],calls:[],notices:[],commits:0,rollbacks:0,failNotification,close:async()=>{},snapshot(){return {post_id:100,committed:this.committed.length}},
  async execute(raw,binds={},options={}){
   const sql=raw.replace(/\s+/g,' ').trim();this.calls.push({sql,binds,options});
   if(sql.startsWith('SELECT seq_post_id'))return{rows:[{ID:100}]};
   if(sql.startsWith('SELECT COALESCE'))return{rows:[{NAME:'viewer'}]};
   if(sql.startsWith('SELECT DBMS_LOB.SUBSTR')&&sql.includes('FROM n_posts'))return{rows:[{CONTENT:'posted'}]};
   if(sql.startsWith('SELECT p.post_id'))return{rows:[{POST_ID:binds.post_id}]};
   if(sql.startsWith('SELECT author_id'))return{rows:[{AUTHOR_ID:2}]};
   const kind=sql.startsWith('INSERT INTO n_posts')?'post':sql.startsWith('INSERT INTO n_post_media')?'media':sql.startsWith('MERGE INTO n_tags')?'tag':sql.startsWith('INSERT INTO n_post_tags')?'post_tag':sql.startsWith('INSERT INTO n_post_mentions')?'mention':null;
   if(!kind)throw new Error(`unexpected SQL ${sql}`);
   if(failAt===kind)throw new Error('private database failure');
   if(kind==='media'&&!media.includes(binds.media_id))return{rowsAffected:0};
   const write={kind,binds};if(options.autoCommit)this.committed.push(write);else this.pending.push(write);return{rowsAffected:1};
  },
  async commit(){this.commits++;if(failCommit)throw new Error('private commit failure');this.committed.push(...this.pending);this.pending=[];},
  async rollback(){this.rollbacks++;this.pending=[];if(failRollback)throw new Error('private rollback failure');}
 };return db;
}
async function invoke(body,db){const request={method:'POST',url:'/api/v2/posts',headers:{'content-type':'application/json'},body};const response=new ServerResponse(request);const event=createEvent(request,response);event.context.auth={userId:1};event.context.getOracleConnection=async()=>db;try{return await routes.create(event);}finally{response.destroy();}}

test('post and valid distinct media, tags and mentions commit together',async()=>{
 const db=database();const result=await invoke({content:'',media_ids:[11,11],tag_names:['#cat'],mention_user_ids:[2]},db);
 assert.equal(result.code,200);assert.deepEqual(db.committed.map(x=>x.kind),['post','media','tag','post_tag','mention']);assert.equal(db.commits,1);assert.equal(db.rollbacks,0);
 assert.ok(db.calls.filter(x=>/^(INSERT|MERGE)/.test(x.sql)).every(x=>x.options.autoCommit===false));assert.equal(db.notices.length,1);
 const attached=db.calls.find(x=>x.sql.startsWith('INSERT INTO n_post_media'));
 assert.match(attached.sql,/owner_user_id = :user_id/);assert.match(attached.sql,/status IN \('uploaded', 'processing', 'ready'\)/);
 assert.equal(attached.binds.user_id,1);assert.equal(attached.binds.media_id,11);
});
test('reposts may omit text and media',async()=>{
 const db=database();const result=await invoke({repost_of_post_id:1},db);
 assert.equal(result.code,200);assert.deepEqual(db.committed.map(x=>x.kind),['post']);assert.equal(db.notices[0].metadata.event,'post_repost');
});
test('invalid media and later relation failures roll back every post write',async()=>{
 for(const [payload,options,status] of [[{content:'',media_ids:[99]},{},400],[{content:'text',media_ids:[99]},{},400],[{content:'text',tag_names:['cat']},{failAt:'post_tag'},500],[{content:'text',mention_user_ids:[2]},{failAt:'mention'},500]]){
  const db=database(options);await assert.rejects(invoke(payload,db),e=>e.statusCode===status&&!String(e.message).includes('private'));assert.deepEqual(db.committed,[]);assert.deepEqual(db.pending,[]);assert.equal(db.rollbacks,1);assert.equal(db.notices.length,0);
 }
});
test('notifications run only after commit and failures do not undo a committed post',async()=>{
 const db=database({failNotification:true});await assert.rejects(invoke({content:'text',mention_user_ids:[2]},db),e=>e.statusCode===500&&!String(e.message).includes('private'));assert.equal(db.commits,1);assert.equal(db.rollbacks,0);assert.deepEqual(db.committed.map(x=>x.kind),['post','mention']);
});
test('commit and rollback errors are sanitized without claiming transaction outcome',async()=>{
 for(const opts of [{failCommit:true},{failAt:'tag',failRollback:true}]){const db=database(opts);await assert.rejects(invoke({content:'text',tag_names:['cat']},db),e=>e.statusCode===500&&!String(e.message).includes('private'));assert.equal(db.rollbacks,1);assert.equal(db.notices.length,0);}
});
