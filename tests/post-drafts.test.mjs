import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { build } from 'esbuild';

const {sql} = JSON.parse(readFileSync(new URL('../specifications/requirements/post-drafts.json',import.meta.url),'utf8'));
const built = await build({
  stdin:{contents:`export * from './server/services/v2/post-drafts';
    export {v2SavePostDraft,v2SchedulePostDraft,v2PublishPostDraft} from './app/api/v2/post-drafts';`,
    resolveDir:fileURLToPath(new URL('../',import.meta.url))},
  bundle:true,write:false,platform:'node',format:'esm',
  plugins:[{name:'isolated-draft-writes',setup(builder) {
    const source = {
      h3:`export const setResponseHeader=(e,k,v)=>{e.headers[k]=v;}; export const getQuery=e=>e.query;`,
      oracledb:`export default {OUT_FORMAT_OBJECT:4002,STRING:2001};`,
      './client':`export const v2RequestData=(path,options)=>globalThis.__draftRequest(path,options);`,
      './posts':`export const v2InsertPost=(db,user,payload)=>db.insertPost(user,payload);
        export const v2NotifyPostCreated=(db,user,id)=>db.notify(user,id);`,
      './groups':`export const readGroupPostWrite=raw=>({content:raw.content,announcement:raw.is_announcement,markdown:raw.markdown});
        export const requireGroupPostPublishAccess=(db,user,group)=>db.requirePermission(user,group);
        export const v2EnsureGroupFeatureSchema=()=>{};
        export const v2InsertGroupPost=async (db,user,group,body)=>(await db.insertPost(user,{...body,group_id:group})).postId;
        export const v2NotifyGroupPostCreated=(db,group,id,user)=>db.notify(user,id,group);`,
      './moderation-publish-policy':`export const requirePublishAccess=(db,user)=>db.requirePermission(user,null);`,
      './post-polls':`export const readPollCreation=value=>value;`,
      './post-markdown':`export const readPostMarkdownInput=value=>value;`,
      '~/server/database/readiness':`export const requireFeatureSchema=()=>{};`,
      '~/server/utils/logging':`export const logWarn=()=>{};`,
      '~/server/utils/v2':`
        const fail=statusCode=>{throw Object.assign(new Error(),{statusCode});};
        export const v2Auth=e=>e.actor?{userId:e.actor}:fail(401),v2Body=e=>e.body,
          v2RouterParam=(e,name)=>String(e.params[name]),v2Ok=data=>({data});
        export const v2Number=Number,v2String=String,v2StringOrNull=value=>value==null?null:String(value),v2NextId=db=>db.nextId();
        export const v2BadRequest=()=>fail(400),v2NotFound=()=>fail(404),v2Conflict=()=>fail(409),v2ServerError=()=>fail(500);
        export const v2Rows=async (db,sql,binds)=>(await db.execute(sql,binds)).rows,
          v2Execute=(db,sql,binds,commit)=>db.write(sql,binds,commit);
      `,
    };
    builder.onResolve({filter:/.*/},({path})=>Object.hasOwn(source,path)?{path,namespace:'fixture'}:undefined);
    builder.onLoad({filter:/.*/,namespace:'fixture'},({path})=>({contents:source[path]}));
  }}],
});
const {v2PostDraftRequest,sweepPostDrafts,v2SavePostDraft,v2SchedulePostDraft,v2PublishPostDraft}=
  await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);

function fixture() {
  const records=new Map(), locks=new Map(), posts=[], notices=[];
  let next=0;
  const state={records,posts,notices,time:'2099-05-01T04:30:00.000Z',denyGroup:false,duringInsert:null};
  return Object.assign(state,{connection() {
    const pending=new Map(), writing=[];
    const row=id=>pending.has(id)?pending.get(id):records.get(id);
    const rows=items=>({rows:items});
    const due=item=>item?.STATUS==='scheduled' && item.SCHEDULED_AT<=state.time;
    const release=()=>{ for(const [id,actor] of locks) if(actor===db) locks.delete(id); };
    let savedPosts=0;
    const db={
      nextId:()=>++next,
      async execute(statement,binds={}) {
        if (statement===sql.candidates) return rows([...records.values()].filter(due));
        if (statement===sql.list) return rows([...records.values()].filter(item=>item.OWNER_ID===binds.owner_id &&
          (!binds.before_id || item.DRAFT_ID<binds.before_id) && (binds.group_scope===null || (item.GROUP_ID??0)===binds.group_scope))
          .sort((a,b)=>b.DRAFT_ID-a.DRAFT_ID).slice(0,binds.fetch_limit));
        if (statement.startsWith('SAVEPOINT')) { savedPosts=writing.length; return {}; }
        if (statement.startsWith('ROLLBACK TO SAVEPOINT')) { writing.length=savedPosts; return {}; }
        assert.ok([sql.read,sql.lock_owner,sql.lock_due].includes(statement));
        const id=binds.draft_id, current=row(id);
        if (!current || (statement===sql.lock_due ? !due(current) || locks.has(id) : current.OWNER_ID!==binds.owner_id)) return rows([]);
        if (statement!==sql.read) locks.set(id,db);
        return rows([current]);
      },
      async write(statement,binds,autoCommit) {
        assert.equal(autoCommit,false);
        const id=binds.draft_id;
        if (statement===sql.insert) {
          pending.set(id,{DRAFT_ID:id,OWNER_ID:binds.owner_id,GROUP_ID:binds.group_id,PAYLOAD_JSON:binds.payload_json,
            STATUS:'draft',SCHEDULED_AT:null,PUBLISHED_POST_ID:null,LAST_ERROR:null,UPDATED_AT:state.time});
          return 1;
        }
        const current=row(id);
        if (!current || current.OWNER_ID!==binds.owner_id) return 0;
        if (statement===sql.remove) { pending.set(id,null); return 1; }
        const published=statement===sql.published, editing=statement===sql.edit, failed=statement===sql.failed, scheduling=statement===sql.schedule;
        if (scheduling && binds.scheduled_at<=state.time) return 0;
        assert.ok(published || editing || failed || scheduling || statement===sql.unschedule);
        pending.set(id,{...current,UPDATED_AT:state.time,
          STATUS:published?'published':failed?'failed':scheduling?'scheduled':'draft',
          SCHEDULED_AT:scheduling?binds.scheduled_at:published||failed?current.SCHEDULED_AT:null,
          PUBLISHED_POST_ID:published?binds.post_id:null,LAST_ERROR:failed?binds.reason:null,
          ...(editing?{GROUP_ID:binds.group_id,PAYLOAD_JSON:binds.payload_json}:{})});
        return 1;
      },
      requirePermission(_actor,group) {
        if (group && state.denyGroup) throw Object.assign(new Error(),{statusCode:403});
      },
      async insertPost(owner,payload) {
        const postId=90+posts.length+writing.length;
        writing.push({owner,payload,postId});
        await state.duringInsert?.();
        db.requirePermission(owner,payload.group_id);
        return {postId};
      },
      async notify(owner,id,group) {
        assert(posts.some(post=>post.postId===id),'notifications must follow commit');
        notices.push({owner,id,group});
      },
      async commit() {
        for (const [id,value] of pending) value===null?records.delete(id):records.set(id,value);
        posts.push(...writing);
        await db.rollback();
      },
      async rollback() { pending.clear(); writing.length=0; release(); },
    };
    return db;
  }});
}

function request(db,action,{actor=42,id,body,query={}}={}) {
  return v2PostDraftRequest({actor,body,query,params:{id},headers:{}},db,action).then(result=>result.data);
}

test('owner can resume and edit an incomplete draft, schedule and cancel, while others see 404',async()=>{
  const state=fixture(), db=state.connection();
  const {draft_id:id}=await request(db,'create',{body:{group_id:null,content:'',media_ids:[123]}});
  await assert.rejects(request(db,'remove',{actor:41,id}),{statusCode:404});
  assert.equal((await request(db,'list',{query:{group_id:'0'}})).items[0].payload.media_ids[0],123);
  await request(db,'edit',{id,body:{group_id:null,content:'Editing from another device'}});
  const scheduled=await request(db,'schedule',{id,body:{scheduled_at:'2099-05-02T13:00:00+08:00'}});
  assert.equal(scheduled.status,'scheduled');
  assert.equal(scheduled.scheduled_at,'2099-05-02T05:00:00.000Z');
  assert.equal((await request(db,'unschedule',{id})).status,'draft');
  state.time='2099-05-03T05:00:00.000Z';
  await sweepPostDrafts(db);
  assert.deepEqual(state.posts,[]);
  assert.equal(await request(db,'remove',{id}),null);
});

test('two due workers and a subsequent manual retry create exactly one group post and send one notice',async()=>{
  const state=fixture(), first=state.connection(), second=state.connection();
  const groupId=10_000_000_012;
  const markdown='# Announcement\n\n**Details**';
  const {draft_id:id}=await request(first,'create',{body:{group_id:groupId,content:'Announcement',is_announcement:true,markdown}});
  await request(first,'schedule',{id,body:{scheduled_at:'2099-05-02T05:00:00Z'}});
  state.time='2099-05-03T05:00:00.000Z';
  const entered=Promise.withResolvers(), release=Promise.withResolvers();
  state.duringInsert=async()=>{entered.resolve();await release.promise;};
  const publishing=sweepPostDrafts(first);
  await entered.promise;
  await sweepPostDrafts(second);
  assert.equal(state.posts.length,0);
  release.resolve();
  await publishing;
  const receipt=await request(second,'publish',{id});
  assert.equal(receipt.published_post_id,90);
  assert.equal(receipt.status,'published');
  assert.equal(state.posts.length,1);
  assert.equal(state.posts[0].payload.markdown,markdown);
  assert.deepEqual(state.notices,[{owner:42,id:90,group:groupId}]);
});

test('a due group draft with revoked permission rolls back post writes and retains a failed draft',async()=>{
  const state=fixture(), db=state.connection();
  const {draft_id:id}=await request(db,'create',{body:{group_id:12,content:'Group update'}});
  await request(db,'schedule',{id,body:{scheduled_at:'2099-05-02T05:00:00Z'}});
  state.time='2099-05-03T05:00:00.000Z';
  state.denyGroup=true;
  await sweepPostDrafts(db);
  assert.deepEqual(state.posts,[]);
  assert.deepEqual(state.notices,[]);
  assert.equal(state.records.get(id).STATUS,'failed');
  assert.equal(state.records.get(id).LAST_ERROR,'permission_denied');
});

test('Web saves and schedules the selected draft and verifies the publication target',async()=>{
  const path='/api/v2/users/me/drafts/12', payload={group_id:9,content:'Group post'}, calls=[];
  const scheduledAt='2099-05-02T05:00:00.000Z';
  let returnedId=12;
  globalThis.__draftRequest=(path,options)=>{
    calls.push([path,options.method,options.body]);
    return {draft_id:returnedId,payload,status:path.endsWith('/schedule')?'scheduled':path.endsWith('/publish')?'published':'draft',published_post_id:88};
  };
  try {
    await v2SavePostDraft(payload,12);
    await v2SchedulePostDraft(12,scheduledAt);
    assert.equal((await v2PublishPostDraft(12)).published_post_id,88);
    assert.deepEqual(calls,[[path,'PUT',payload],[`${path}/schedule`,'PUT',{scheduled_at:scheduledAt}],[`${path}/publish`,'POST',undefined]]);
    returnedId=13;
    await assert.rejects(v2PublishPostDraft(12),/Unconfirmed draft operation/);
  } finally { delete globalThis.__draftRequest; }
});
