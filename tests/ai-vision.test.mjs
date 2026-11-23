import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { Readable } from 'node:stream';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import policy from '../specifications/requirements/ai-vision.json' with {type:'json'};

const root = fileURLToPath(new URL('../',import.meta.url));
const v2 = `
  export const v2Throw=(statusCode,message)=>{throw Object.assign(new Error(message),{statusCode,data:{code:statusCode*100+1,message,data:null,meta:null}})};
  export const v2BadRequest=m=>v2Throw(400,m),v2NotFound=m=>v2Throw(404,m),v2Conflict=m=>v2Throw(409,m),v2ServerError=()=>v2Throw(500,'服务器内部错误');
  export const v2Auth=e=>({userId:e.actor}),v2Connection=e=>e.db,v2Ok=data=>({data}),v2RouterParam=e=>e.id;
  export const v2Rows=(db,sql,args)=>db.rows(sql,args),v2One=async(db,sql,args)=>(await db.rows(sql,args))[0]??null;
  export const v2Execute=(db,sql,args)=>db.write(sql,args);
`;
const stubs = {
  h3: `export const setResponseHeader=(e,k,v)=>e.headers[k]=v, isError=e=>Number.isInteger(e?.statusCode),
    createError=e=>Object.assign(new Error(e.message ?? e.statusMessage),e);`,
  '~/server/storage': `export const getStorageProvider=()=>globalThis.__visionFixture.storage;`,
  '~/server/utils/logging': `export const logInfo=()=>{}; export const getRequestLogContext=()=>null;`,
  '~/server/utils/ai-model-quota': `export class AiQuotaError extends Error{};export const requireAiModelQuota=()=>{};
    export const throwAiQuotaResponse=()=>{throw Error('unexpected quota failure')};`,
  '~/server/utils/v2': v2,
  './v2': v2,
  './model-source': `export const configuredModelRouter=async()=>({select(role,caps){
    if(role!=='writing'||caps[0]!=='vision')throw Error('incorrect model');return {configurationRevision:2};
  }});`,
  './inference-transport': `export class AiInferenceTransport{async infer(_,input){
    if(globalThis.__visionFixture.outage)throw Error('private upstream detail');
    globalThis.__visionFixture.input=input;
    return {text:'{"alt_text":" A cat ","tags":["#cats","cats"]}',finishReason:'stop',toolCalls:[]};
  }};`,
};
const bundle = await build({
  stdin:{contents:`export * from './server/services/ai/vision-media'; export * from './server/services/ai/vision-image-record';`,resolveDir:root},
  alias:{'~':root},bundle:true,write:false,platform:'node',format:'esm',
  plugins:[{name:'vision-fixture',setup(builder) {
    builder.onResolve({filter:/.*/},({path})=>Object.hasOwn(stubs,path) ? {path,namespace:'stub'} : undefined);
    builder.onLoad({filter:/.*/,namespace:'stub'},({path})=>({contents:stubs[path],loader:'js'}));
  }}],
});
const api = await import(`data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`);
const png = Buffer.from('iVBORw0KGgo=', 'base64');
const asset = {MEDIA_ID:7, STORAGE_KEY:'private/post/test.png',ACCESS_SCOPE:'post',MIME_TYPE:'image/png',FILE_SIZE:png.length};
const event = (db,body,actor=42) => ({db,actor,id:'7',headers:{},node:{req:Readable.from([Buffer.from(body)]),res:new EventEmitter()}});

test('describe uses only an owned stored image and never accepts a URL', async t => {
  const fixture = {reads:0,storage:{
    async readPrivateObject(key) {
      assert.equal(key,asset.STORAGE_KEY);
      fixture.reads++;
      return {statusCode:200,stream:Readable.from([png])};
    },
  }};
  globalThis.__visionFixture = fixture;
  t.after(()=>delete globalThis.__visionFixture);
  let checks = 0;
  const db = {close(){},rows(sql,{viewer_id,media_id}) {
    checks++;
    assert.equal(sql,policy.sql.owned_image);
    assert.equal(media_id,7);
    return viewer_id===42 ? [asset] : [];
  }};
  const request = '{"media_id":7,"locale":"en"}';
  await assert.rejects(api.describeMedia(event(db,'{"url":"https://example.test/image","locale":"en"}')), error=>error.statusCode===400);
  assert.equal(checks,0);
  await assert.rejects(api.describeMedia(event(db,request,99)), error=>error.statusCode===404);
  assert.equal(fixture.reads,0);
  assert.deepEqual((await api.describeMedia(event(db,request))).data, {media_id:7,alt_text:'A cat',tags:['cats']});
  assert.equal(checks,3);
  assert.deepEqual(fixture.input.images,[{mime_type:'image/png',data:png.toString('base64')}]);
  fixture.outage = true;
  await assert.rejects(api.describeMedia(event(db,request)),error=>error.statusCode===503 &&
    !JSON.stringify(error.data).includes('private upstream'));
});

test('only unattached draft metadata is updated, and an image detached during review invalidates its evidence', async () => {
  let attached = false;
  const publicImage = {...asset,STORAGE_KEY:'posts/test.png',ACCESS_SCOPE:'public'};
  let commits = 0;
  const db = {
    async rows(sql,params) {
      assert.equal(params.media_id,7);
      if (sql === policy.sql.lock_owned_image) return params.viewer_id===42 ? [{MEDIA_ID:7}] : [];
      if (sql === policy.sql.image_is_attached) return attached ? [{IN_USE:1}] : [];
      assert.equal(sql,policy.sql.moderation_image);
      assert.equal(params.post_id,8);
      return attached ? [publicImage] : [];
    },
    async write(sql,params) {
      assert.equal(sql,policy.sql.write_alt_text);
      assert.deepEqual(params,{media_id:7,viewer_id:42,alt_text:'A cat'});
      return 1;
    },
    async commit(){ commits++; }, async rollback(){},
  };
  const patch = '{"alt_text":"A cat"}';
  const ref = api.imageReference(api.mediaFromRow(publicImage));
  assert.deepEqual((await api.updateMediaAltText(event(db,patch),db)).data,{media_id:7,alt_text:'A cat'});
  attached = true;
  await assert.rejects(api.updateMediaAltText(event(db,patch),db), error=>error.statusCode===409);
  assert.equal(commits,1);
  assert.equal(await api.moderationImagesCurrent(db,42,'post',8,[ref]),true);
  attached = false;
  assert.equal(await api.moderationImagesCurrent(db,42,'post',8,[ref]),false);
});
