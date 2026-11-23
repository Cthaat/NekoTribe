import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { build } from 'esbuild';

const {sql}=JSON.parse(readFileSync(new URL('../specifications/requirements/profile-pinned-post.json',import.meta.url),'utf8'));
const compiled=await build({
  stdin:{contents:`export {v2ProfilePin} from './server/services/v2/profile-pinned-post';
    export {v2GetProfilePin,v2SetProfilePin,v2ClearProfilePin} from './app/api/v2/profile-pinned-post';`,
    resolveDir:fileURLToPath(new URL('../',import.meta.url))},
  bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'isolated-profile-pin',setup(builder) {
    const dependencies={
      h3:`export const setResponseHeader=(e,k,v)=>{e.headers[k]=v;};`,
      './client':`export const v2RequestData=(path,options)=>globalThis.__pinFetch(path,options);`,
      '~/server/database/readiness':`export const requireFeatureSchema=(db,feature)=>db.ready(feature);`,
      '~/server/models/v2':`export const v2GetPostById=(db,user,id)=>db.visiblePost(user,id);`,
      '~/server/utils/router-id':`export const v2SafeRouterId=e=>e.profile;`,
      '~/server/utils/v2':`
        const fail=statusCode=>{throw Object.assign(new Error(),{statusCode});};
        export const v2Auth=e=>e.actor?{userId:e.actor}:fail(401),v2Body=e=>e.body,v2Number=Number;
        export const v2BadRequest=()=>fail(400),v2NotFound=()=>fail(404),v2ServerError=()=>fail(500),v2Ok=data=>({data});
        export const v2One=(db,sql,binds)=>db.one(sql,binds),v2Execute=(db,sql,binds,commit)=>db.write(sql,binds,commit);
      `,
    };
    builder.onResolve({filter:/.*/},({path})=>Object.hasOwn(dependencies,path)?{path,namespace:'fixture'}:undefined);
    builder.onLoad({filter:/.*/,namespace:'fixture'},({path})=>({contents:dependencies[path]}));
  }}],
});
const api=await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);

function fixture() {
  const posts=new Map([[1,{post_id:1,author:{user_id:41},visibility:'public'}],[2,{post_id:2,author:{user_id:41},visibility:'private'}],
    [3,{post_id:3,author:{user_id:42},visibility:'public'}]]);
  const pins=new Map(),events=[];
  const db={
    pins,posts,events,
    ready(feature){assert.equal(feature,'profile-pinned-post');},
    visiblePost(actor,id){const post=posts.get(id);return post && (post.author.user_id===actor || post.visibility==='public') ? post : null;},
    one(query,binds){
      if(query===sql.owner) {events.push('owner lock');return {USER_ID:binds.user_id};}
      if(query===sql.eligible) {events.push('post lock');return posts.get(binds.post_id)?.author.user_id===binds.user_id ? {POST_ID:binds.post_id}:null;}
      assert.equal(query,sql.read);
      const postId=pins.get(binds.profile_id);
      return db.visiblePost(binds.viewer_id,postId) ? {POST_ID:postId}:null;
    },
    write(query,binds,autoCommit){
      assert.equal(autoCommit,false);
      if(query===sql.remove) return Number(pins.delete(binds.user_id));
      assert.equal(query,sql.write);
      pins.set(binds.user_id,binds.post_id);
      return 1;
    },
    commit(){events.push('commit');},rollback(){events.push('rollback');},
  };
  return db;
}

const run=(db,action,{actor=41,profile=41,body}={})=>
  api.v2ProfilePin({actor,profile,body,headers:{}},db,action).then(result=>result.data);

test('an account pins, replaces and clears a single post under its own locks',async()=>{
  const db=fixture();
  assert.deepEqual(await run(db,'set',{body:{post_id:1}}),{post_id:1});
  assert.deepEqual(db.events,['owner lock','post lock','commit']);
  assert.equal((await run(db,'read',{actor:42})).post.post_id,1);
  await run(db,'set',{body:{post_id:2}});
  assert.deepEqual([...db.pins],[[41,2]]);
  assert.equal((await run(db,'read')).post.post_id,2);
  assert.deepEqual(await run(db,'read',{actor:42}),{post:null});
  assert.equal(await run(db,'clear'),null);
  assert.equal(await run(db,'clear'),null);
  assert.deepEqual(await run(db,'read'),{post:null});
});

test('foreign, malformed or deleted targets cannot be surfaced as a pin',async()=>{
  const db=fixture();
  await assert.rejects(run(db,'set',{body:{post_id:3}}),{statusCode:404});
  assert.equal(db.events.at(-1),'rollback');
  await assert.rejects(run(db,'set',{body:{post_id:'1'}}),{statusCode:400});
  await run(db,'set',{body:{post_id:1}});
  db.posts.delete(1);
  assert.deepEqual(await run(db,'read'),{post:null});
});

test('profile client uses the dedicated paths and accepts only a matching pin receipt',async()=>{
  const calls=[];
  let owner=41;
  globalThis.__pinFetch=(path,options)=>{
    calls.push([path,options.method,options.body]);
    if(options.method==='PUT') return {post_id:1};
    if(options.method==='DELETE') return null;
    return {post:{post_id:1,author:{user_id:owner}}};
  };
  try {
    assert.equal((await api.v2GetProfilePin(41)).post_id,1);
    await api.v2SetProfilePin(1);
    await api.v2ClearProfilePin();
    assert.deepEqual(calls,[['/api/v2/users/41/pinned-post',undefined,undefined],
      ['/api/v2/users/me/pinned-post','PUT',{post_id:1}],['/api/v2/users/me/pinned-post','DELETE',undefined]]);
    owner=42;
    await assert.rejects(api.v2GetProfilePin(41),/Invalid profile pin/);
  } finally { delete globalThis.__pinFetch; }
});
