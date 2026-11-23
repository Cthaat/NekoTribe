import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const built = await build({
  stdin:{contents:`export * from './server/services/v2/post-polls';
    export {v2ReadPostPoll,v2VotePostPoll} from './server/services/v2/post-poll-http';
    export {newPostPollDraft,postPollPayload} from './app/utils/post-poll-draft';`,
    resolveDir:fileURLToPath(new URL('../',import.meta.url))},
  bundle:true,write:false,platform:'node',format:'esm',
  plugins:[{name:'post-poll-oracle-fixture',setup(builder) {
    const source = {
      h3:`export const setResponseHeader=(e,k,v)=>{e.headers[k]=v;};`,
      './groups':`export const v2RequireGroupPostRow=(db,user,group,post)=>{db.groupScope=[user,group,post];};
        export const withGroupContentWrite=async (db,_user,_group,write)=>{
          try{const result=await write();await db.commit();return result;}catch(error){await db.rollback();throw error;}
        };`,
      '~/server/database/readiness':`export const requireFeatureSchema=(_db,id)=>{if(id!=='post-polls')throw Error('Unexpected migration set');};`,
      '~/server/utils/auth-entry-errors':`export const v2ServiceUnavailable=()=>{throw Object.assign(new Error(),{statusCode:503});};`,
      '~/server/utils/v2':`
        const fail=statusCode=>{throw Object.assign(new Error(),{statusCode});};
        export const v2Auth=e=>e.actor?{userId:e.actor}:fail(401),v2OptionalAuth=e=>e.actor?{userId:e.actor}:null,
          v2Body=e=>e.body,v2RouterParam=(e,name)=>String(e.params[name]??''),v2Ok=data=>({data});
        export const v2Number=Number,v2String=String,v2Boolean=value=>value===1,v2NextId=()=>75,
          v2BadRequest=()=>fail(400),v2Forbidden=()=>fail(403),v2NotFound=()=>fail(404),v2Conflict=()=>fail(409),v2ServerError=()=>fail(500);
        export const v2One=(db,sql,binds)=>db.one(sql,binds),v2Rows=(db,sql,binds)=>db.rows(sql,binds),
          v2Execute=(db,sql,binds,commit)=>db.write(sql,binds,commit);
      `,
    };
    builder.onResolve({filter:/.*/},({path})=>Object.hasOwn(source,path)?{path,namespace:'fixture'}:undefined);
    builder.onLoad({filter:/.*/,namespace:'fixture'},({path})=>({contents:source[path]}));
  }}],
});
const api=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
const {postPollSql:sql}=api;

test('an attached poll and the first multi-choice ballot use ordered choices and participant percentages',async()=>{
  const options=[];
  const votes=new Map([[44,[1]]]);
  const log=[];
  let actorPending, setup;
  const db={
    one(query,binds){
      if(query.includes('fn_can_post_in_group'))return{ALLOWED:1};
      assert.equal(binds.post_id,25);
      return binds.viewer_id===42?{POST_ID:25}:null;
    },
    rows(query,binds){
      assert.equal(query,sql.read);
      assert.equal(binds.post_id,25);
      const selected=votes.get(binds.viewer_id)??[];
      return options.map((text,index)=>({POLL_ID:75,ALLOW_MULTIPLE:1,CLOSES_AT:setup.closes_at,IS_CLOSED:0,
        OPTION_ID:index+1,OPTION_TEXT:text,TOTAL_BALLOTS:votes.size,VOTES_COUNT:[...votes.values()].filter(ids=>ids.includes(index+1)).length,
        SELECTED:Number(selected.includes(index+1))}));
    },
    write(query,binds,autoCommit){
      assert.equal(autoCommit,false);
      assert.equal(binds.poll_id,75);
      log.push(query);
      if(query===sql.insert_poll)assert.deepEqual(binds,{poll_id:75,post_id:25,group_post_id:null,allow_multiple:1,closes_at:setup.closes_at});
      if(query===sql.insert_option)options.push(binds.option_text);
      if(query===sql.insert_ballot){actorPending=binds.user_id;votes.set(actorPending,[]);}
      if(query===sql.insert_vote)votes.get(actorPending).push(binds.option_id);
      return 1;
    },
    commit(){log.push('commit');},rollback(){log.push('rollback');},
  };
  setup=api.readPollCreation({options:[' Alpha ','Beta'],multiple:true,closes_at:'2026-12-01T11:00:00+08:00'});
  assert.deepEqual(setup,{options:['Alpha','Beta'],multiple:true,closes_at:'2026-12-01T03:00:00.000Z'});
  await api.attachPostPoll(db,'post',25,setup);
  assert.deepEqual(log,[sql.insert_poll,sql.insert_option,sql.insert_option]);
  const event=(actor,choices)=>({actor,params:{id:25},body:{option_ids:choices},headers:{}});
  const outcome=await api.v2VotePostPoll(event(42,[1,2]),db,'post');
  assert.deepEqual(outcome.data.my_option_ids,[1,2]);
  assert.deepEqual(outcome.data.options.map(item=>[item.text,item.votes_count,item.percent]),[['Alpha',2,100],['Beta',1,50]]);
  assert.equal(outcome.data.total_ballots,2);
  assert.deepEqual(log.slice(-4),[sql.insert_ballot,sql.insert_vote,sql.insert_vote,'commit']);
  await assert.rejects(api.v2VotePostPoll(event(42,[1]),db,'post'),{statusCode:409});
  await assert.rejects(api.v2ReadPostPoll(event(57,[]),db,'post'),{statusCode:404});
});

test('readable group polls still require current posting permission to vote',async()=>{
  const event={actor:42,params:{id:9,post_id:25},body:{option_ids:[1]},headers:{}};
  const db={
    rows(query,binds){
      assert.equal(query,sql.read);
      assert.deepEqual(binds,{viewer_id:42,is_group:1,post_id:25});
      return ['Morning','Evening'].map((text,index)=>({POLL_ID:75,ALLOW_MULTIPLE:0,CLOSES_AT:'2026-12-01T03:00:00.000Z',
        IS_CLOSED:0,OPTION_ID:index+1,OPTION_TEXT:text,TOTAL_BALLOTS:0,VOTES_COUNT:0,SELECTED:0}));
    },
    one(query,binds){
      assert.match(query,/fn_can_post_in_group/);
      assert.deepEqual(binds,{user_id:42,group_id:9});
      return {ALLOWED:0};
    },
    write(){assert.fail('a denied vote must not write');},
    commit(){assert.fail('a denied vote must not commit');},
    rollback(){this.rolledBack=true;},
  };
  const read=await api.v2ReadPostPoll(event,db,'group');
  assert.deepEqual(db.groupScope,[42,9,25]);
  assert.deepEqual(read.data.options.map(option=>option.text),['Morning','Evening']);
  await assert.rejects(api.v2VotePostPoll(event,db,'group'),{statusCode:403});
  assert.equal(db.rolledBack,true);
});

test('the common composer sends a UTC deadline and refuses repeated or missing options',()=>{
  const now=Date.parse('2026-11-22T00:00:00Z');
  const draft=api.newPostPollDraft(now);
  assert.equal(api.postPollPayload(draft,now),undefined);
  draft.options=['Morning','Evening'];
  assert.deepEqual(api.postPollPayload(draft,now),{options:draft.options,multiple:false,closes_at:'2026-11-23T00:00:00.000Z'});
  draft.options=['Morning',' Morning '];
  assert.equal(api.postPollPayload(draft,now),undefined);
  assert.throws(()=>api.readPollCreation({options:draft.options,multiple:false,closes_at:'2026-11-23T00:00:00Z'}),{statusCode:400});
});
