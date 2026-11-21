import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {ServerResponse} from 'node:http';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
import {build} from 'esbuild';
import {createEvent} from 'h3';

const publishPolicy = JSON.parse(readFileSync(new URL('../specifications/requirements/moderation-publish-policy.json', import.meta.url), 'utf8'));
const root=fileURLToPath(new URL('../',import.meta.url)), require=createRequire(import.meta.url);
const vectors=JSON.parse(readFileSync(new URL('../specifications/scenarios/post-update-request.json',import.meta.url),'utf8'));
const stubs={
  '~/server/models/v2': `export const v2RequirePostById=async connection=>connection.readMappedPost();
    const unused=()=>{throw new Error('unexpected model');};
    export const v2CommentCount=unused,v2MapComment=unused,v2MapPost=unused,v2MapPublicUser=unused,v2PostCountSql=unused,v2PostSelectSql=unused,v2SortOrder=unused,v2VisiblePostCommentScope=unused;`,
  './notifications': `export const v2CreateNotification=()=>{throw new Error('unexpected notification');};`,
  './api-cache': `export const readApiResponseCache=async()=>({status:'disabled'}),writeApiResponseCache=async()=>{},invalidateApiResponseCache=async()=>{},shouldInvalidateApiResponseCache=()=>false;`,
  './logging': `export const getRequestLogContext=()=>null,logError=()=>{},logInfo=()=>{},serializeLogError=()=>({});`,
  oracledb:'export default {OUT_FORMAT_OBJECT:4002};'
};
const anchor='  const payload = await v2ReadUpdatePostPayload(event);';
const compiled=await build({
  stdin:{contents:`export {default as patch} from './server/api/v2/posts/[id].patch';export {default as put} from './server/api/v2/posts/[id].put';`,resolveDir:root,loader:'ts'},
  bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'observe-post-update',setup(builder){
    builder.onResolve({filter:/.*/},args=>{
      if(Object.hasOwn(stubs,args.path))return {path:args.path,namespace:'stub'};
      if(args.path.startsWith('~/'))return {path:path.join(root,`${args.path.slice(2)}.ts`)};
      if(args.path.startsWith('node:'))return {path:args.path,external:true};
      if(!args.path.startsWith('.')&&!path.isAbsolute(args.path))return {path:pathToFileURL(require.resolve(args.path)).href,external:true};
    });
    builder.onLoad({filter:/.*/,namespace:'stub'},args=>({contents:stubs[args.path],loader:'js'}));
    builder.onLoad({filter:/services[\\/]v2[\\/]posts\.ts$/},args=>{
      const source=readFileSync(args.path,'utf8');assert.equal(source.split(anchor).length,2);
      return {contents:source.replace(anchor,anchor+'\n  event.context.observeUpdate?.(payload);'),loader:'ts'};
    });
  }}]
});
const routes=await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);
const initial=()=>({content:'old',visibility:'public',language:'zh',location:'there',media:[8],tags:['old'],mentions:[7],updated:false});
function database({fail='',owner=42,missing=false,repost=false,deleted=false,muted=false,retainsPrivate=false,privateMediaIds=[]}={}){
  let saved=initial(),pending;
  const calls=[];
  const fault=stage=>{if(fail===stage)throw new Error('private driver detail');};
  return {
    calls,observed:undefined,commits:0,rollbacks:0,reads:0,
    saved:()=>structuredClone(saved),
    async execute(raw,binds={},options={}){
      const sql=raw.replace(/\s+/g,' ').trim();calls.push({sql,binds,options});
      if (sql === publishPolicy.sql.lock) return {rows: [{USER_ID: binds.user_id}]};
      if (sql === publishPolicy.sql.allowed) return {rows: [{ALLOWED: muted ? 0 : 1}]};
      if(sql.startsWith('SELECT author_id')){
        fault('read');if(sql.endsWith('FOR UPDATE'))pending=structuredClone(saved);
        return {rows:missing?[]:[{AUTHOR_ID:owner,IS_DELETED:deleted?1:0,POST_TYPE:repost?'repost':'post',VISIBILITY:saved.visibility,CONTENT:saved.content}]};
      }
      if(sql.startsWith('SELECT COUNT(*) AS total FROM n_post_media'))return {rows:[{TOTAL:(pending??saved).media.length}]};
      if(sql.startsWith('SELECT 1 AS found FROM n_post_media'))return {rows:retainsPrivate?[{FOUND:1}]:[]};
      if(sql.startsWith('SELECT 1 AS permitted FROM n_media_assets'))return {rows:[{PERMITTED:1}]};
      if(sql.startsWith('SELECT media_id, storage_key FROM n_media_assets')){
        const id=binds.media_id;
        const key=privateMediaIds.includes(id)?`private/post/${id}.txt`:`posts/files/${id}.txt`;
        return {rows:id===999?[]:[{MEDIA_ID:id,STORAGE_KEY:key}]};
      }
      let stage;
      if(sql.startsWith('UPDATE n_posts'))stage='update';
      else if(sql.startsWith('DELETE FROM n_post_media'))stage='media-delete';
      else if(sql.startsWith('INSERT INTO n_post_media'))stage='media-insert';
      else if(sql.startsWith('DELETE FROM n_post_tags'))stage='tag-delete';
      else if(sql.startsWith('MERGE INTO n_tags'))stage='tag-merge';
      else if(sql.startsWith('INSERT INTO n_post_tags'))stage='tag-insert';
      else if(sql.startsWith('DELETE FROM n_post_mentions'))stage='mention-delete';
      else if(sql.startsWith('INSERT INTO n_post_mentions'))stage='mention-insert';
      else throw new Error(`unexpected SQL ${sql}`);
      fault(stage);pending??=structuredClone(saved);
      if(stage==='update'){
        if(fail==='race')return {rowsAffected:0};
        for(const key of ['content','visibility','language','location'])if(Object.hasOwn(binds,key))pending[key]=binds[key];
        pending.updated=true;
      }
      if(stage==='media-delete')pending.media=[];
      if(stage==='media-insert'){
        if(binds.media_id===999)return {rowsAffected:0};
        pending.media.push(binds.media_id);
      }
      if(stage==='tag-delete')pending.tags=[];
      if(stage==='tag-insert'&&!pending.tags.some(tag=>tag.toLowerCase()===binds.name.toLowerCase()))pending.tags.push(binds.name);
      if(stage==='mention-delete')pending.mentions=[];
      if(stage==='mention-insert'&&binds.user_id>0&&Number.isInteger(binds.user_id))pending.mentions.push(binds.user_id);
      if(options.autoCommit===true){saved=structuredClone(pending);pending=undefined;}
      return {rowsAffected:1};
    },
    async commit(){this.commits++;fault('commit');saved=pending??saved;pending=undefined;fault('commit-applied');},
    async rollback(){this.rollbacks++;fault('rollback');pending=undefined;},
    async close(){fault('close');},
    async readMappedPost(){this.reads++;fault('mapped');assert.equal(pending,undefined,'mapping must follow transaction completion');return this.saved();}
  };
}
async function invoke(body,connection,{method='patch',id='20',authenticated=true}={}){
  const request={method:method.toUpperCase(),url:`/api/v2/posts/${id}`,headers:{'content-type':'application/json'},body:JSON.stringify(body)};
  const response=new ServerResponse(request),event=createEvent(request,response);
  if(authenticated)event.context.auth={userId:42};
  event.context.params={id};event.context.getOracleConnection=async()=>connection;
  event.context.observeUpdate=payload=>{connection.observed=structuredClone(payload);};
  try{return await routes[method](event);}
  finally{assert.equal(response.getHeader('Cache-Control'),'private, no-store');response.destroy();}
}
const rejects=(run,status,message)=>assert.rejects(run,error=>{
  assert.equal(error.statusCode,status);assert.deepEqual(error.data,{code:status*100+1,message,data:null,meta:null});
  assert.ok(!error.message.includes('private'));return true;
});
for(const vector of vectors.cases)test(`post update request: ${vector.id}`,async()=>{
  const db=database();
  if(vector.expected.status===200){const result=await invoke(vector.body,db);assert.equal(result.message,'post updated');assert.deepEqual(db.observed,vector.expected.input);}
  else{await rejects(()=>invoke(vector.body,db),400,vector.expected.message);assert.equal(db.calls.length,0);}
});
test('PATCH and PUT refuse a muted account before writing', async () => {
  for (const method of ['patch', 'put']) {
    const db = database({muted: true});
    await rejects(() => invoke({content: 'new'}, db, {method}), 403, publishPolicy.message);
    assert.equal(db.rollbacks, 1);
    assert.equal(db.commits, 0);
    assert.deepEqual(db.calls.map(({sql}) => sql), [publishPolicy.sql.lock, publishPolicy.sql.allowed]);
  }
});
test('PATCH and PUT atomically update scalar and relationship fields',async()=>{
  for(const method of ['patch','put']){
    const db=database();const result=await invoke({content:' changed ',visibility:'private',language:' EN-us ',location:' ',media_ids:[3,3,4],tag_names:[' #News ','news','other'],mention_user_ids:[9,9,10]},db,{method});
    assert.deepEqual(result.data,{content:' changed ',visibility:'private',language:'en-us',location:' ',media:[3,4],tags:['News','other'],mentions:[9,10],updated:true});
    assert.equal(db.commits,1);assert.equal(db.rollbacks,0);assert.equal(db.reads,1);
    assert.match(db.calls[0].sql,/FOR UPDATE$/);
    const writes=db.calls.filter(call=>!call.sql.startsWith('SELECT'));assert.ok(writes.length>0);
    for(const call of writes)assert.equal(call.options.autoCommit,false);
    assert.match(writes[0].sql,/author_id\s*=\s*:user_id/);assert.match(writes[0].sql,/is_deleted\s*=\s*0/);
  }
});
test('each write failure rolls back all earlier fields and relationships',async()=>{
  for(const fail of ['update','media-delete','media-insert','tag-delete','tag-merge','tag-insert','mention-delete','mention-insert','commit']){
    const db=database({fail});await rejects(()=>invoke({content:'new',media_ids:[3],tag_names:['new'],mention_user_ids:[9]},db),500,'服务器内部错误');
    assert.deepEqual(db.saved(),initial(),fail);assert.equal(db.rollbacks,1,fail);assert.equal(db.reads,0,fail);
  }
});
test('unusable media and concurrent missing row never retain earlier edits',async()=>{
  for(const [fail,body,status,message] of [['',{content:'new',media_ids:[3,999]},400,'附件不存在或无权使用'],['race',{content:'new'},404,'帖子不存在']]){
    const db=database({fail});await rejects(()=>invoke(body,db),status,message);assert.deepEqual(db.saved(),initial());assert.equal(db.rollbacks,1);
  }
});
test('making a post public requires explicitly removing or replacing private attachments', async () => {
 const retained = database({retainsPrivate:true,privateMediaIds:[3]});
 await rejects(() => invoke({visibility:'public'}, retained), 400, '附件不存在或无权使用');
 assert.equal(retained.commits,0);
 assert.equal(retained.calls.some(call=>call.sql.startsWith('UPDATE n_posts')),false);
 await rejects(() => invoke({visibility:'public',media_ids:[3]}, retained), 400, '附件不存在或无权使用');
 assert.equal(retained.commits,0);

 const result = await invoke({visibility:'public',media_ids:[4]}, retained);
 assert.deepEqual(result.data.media,[4]);
 assert.equal(result.data.visibility,'public');
 assert.equal(retained.commits,1);
});
test('no-op preserves timestamp, omission preserves relations, explicit empty clears',async()=>{
  const db=database();await invoke({},db);assert.deepEqual(db.saved(),initial());assert.equal(db.commits,1);
  assert.ok(db.calls.every(call=>call.sql.startsWith('SELECT')));
  const clear=database();await invoke({media_ids:null,tag_names:[],mention_user_ids:null},clear);assert.deepEqual(clear.saved(),{...initial(),media:[],tags:[],mentions:[],updated:true});
  const empty=database();await rejects(()=>invoke({content:null,media_ids:[]},empty),400,'content 不能为空');assert.deepEqual(empty.saved(),initial());
  const repost=database({repost:true});await invoke({content:null,media_ids:[]},repost);assert.equal(repost.saved().content,null);
});
test('ownership and deleted states reject before writes and release locks',async()=>{
  for(const [options,status,message] of [[{owner:7},422,'只能修改自己的帖子'],[{missing:true},404,'帖子不存在'],[{deleted:true},404,'帖子不存在']]){
    const db=database(options);await rejects(()=>invoke({content:'new'},db),status,message);assert.equal(db.rollbacks,1);assert.ok(db.calls.every(call=>call.sql.startsWith('SELECT')));
  }
});
test('commit uncertainty and post-commit failures do not claim rollback of saved data',async()=>{
  for(const fail of ['commit-applied','mapped','close']){
    const db=database({fail});await rejects(()=>invoke({content:'new'},db),500,'服务器内部错误');assert.equal(db.saved().content,'new');assert.equal(db.commits,1);
    assert.equal(db.rollbacks,fail==='commit-applied'?1:0);
  }
});
test('rollback failure is a safe internal error and rejects the edit',async()=>{
  const db=database({owner:7,fail:'rollback'});await rejects(()=>invoke({content:'new'},db),500,'服务器内部错误');assert.deepEqual(db.saved(),initial());assert.equal(db.rollbacks,1);
});
test('canonical path and authenticated context are required before editing',async()=>{
  const db=database();await rejects(()=>invoke({content:'new'},db,{id:'01'}),400,'id 参数错误');assert.equal(db.calls.length,0);
  const anonymous=database();await rejects(()=>invoke({content:'new'},anonymous,{authenticated:false}),401,'未认证或 token 无效');assert.equal(anonymous.calls.length,0);
});
