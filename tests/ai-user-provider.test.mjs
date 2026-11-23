import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import policy from '../specifications/requirements/ai-user-provider.json' with {type:'json'};
import { normalizeProviderBaseUrl, openUserProviderKey, sealUserProviderKey } from '../server/services/ai/user-provider-crypto.ts';

const {crypto_vector:vector,sql} = policy;
const key = Buffer.from(vector.fixture_master_b64,'base64');
const binding = {ownerId:vector.owner_id,preset:vector.preset,baseUrl:vector.base_url};
test('the shared encrypted value is scoped to its account, preset and precise service address',()=>{
  assert.equal(normalizeProviderBaseUrl(' '+binding.baseUrl+'/ '),binding.baseUrl);
  assert.equal(normalizeProviderBaseUrl('https://user@example.test/v1'),null);
  assert.equal(normalizeProviderBaseUrl('https://example.test/v1?'),null);
  assert.equal(openUserProviderKey(key,binding,vector.fixture_box),vector.fixture_key);
  assert.equal(openUserProviderKey(key,{...binding,ownerId:7},vector.fixture_box),null);
  assert.equal(openUserProviderKey(key,{...binding,baseUrl:'https://different.example.test/v1'},vector.fixture_box),null);
  const generated=sealUserProviderKey(key,binding,vector.fixture_key);
  assert.notEqual(generated,vector.fixture_box);
  assert.equal(openUserProviderKey(key,binding,generated),vector.fixture_key);
});

const root = fileURLToPath(new URL('../',import.meta.url));
const v2 = `
  const err=(statusCode,message)=>{throw Object.assign(new Error(message),{statusCode,data:{code:statusCode*100+1,message,data:null,meta:null}})};
  export const v2BadRequest=m=>err(400,m),v2NotFound=m=>err(404,m),v2Conflict=m=>err(409,m),
    v2ServerError=()=>err(500,'服务器内部错误'),v2Auth=e=>e.ownerId ? {userId:e.ownerId} : err(401,'未认证或 token 无效');
  export const v2Connection=e=>{e.db.open++;return e.db}, v2Ok=data=>({data}),
    v2One=(db,sql,binds)=>db.row(sql,binds),v2Execute=(db,sql,binds)=>db.write(sql,binds);
`;
const stubs = {
  h3: `export const setResponseHeader=(e,k,v)=>e.headers[k]=v, isError=e=>Number.isInteger(e?.statusCode),
    createError=e=>Object.assign(new Error(e.message ?? e.statusMessage),e);`,
  '~/server/database/readiness': `export const requireFeatureSchema=async(c,id)=>{if(id!=='ai-user-provider')throw Error('Unexpected schema')};`,
  '~/server/utils/v2':v2,
  './v2':v2,
};
const built = await build({
  stdin:{contents:`export * from './server/services/ai/user-provider';`,resolveDir:root},alias:{'~':root},bundle:true,write:false,platform:'node',format:'esm',
  plugins:[{name:'user-provider-fixture',setup(bundler){
    bundler.onResolve({filter:/.*/},({path})=>Object.hasOwn(stubs,path)?{path,namespace:'fixture'}:undefined);
    bundler.onLoad({filter:/.*/,namespace:'fixture'},({path})=>({contents:stubs[path],loader:'js'}));
  }}],
});
const api = await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);

test('configuration, probe and writing stick to the saved owner and never return credentials',async t=>{
  const env = {AI_USER_PROVIDER_SECRET_B64:vector.fixture_master_b64,AI_USER_PROVIDER_URL:vector.base_url+'/'};
  const previous = Object.fromEntries(Object.keys(env).map(name=>[name,process.env[name]]));
  Object.assign(process.env,env);
  t.after(()=>{
    for(const [name,value] of Object.entries(previous)) {
      if(value===undefined) delete process.env[name]; else process.env[name]=value;
    }
  });
  let calls=0;
  t.mock.method(globalThis,'fetch',async (url,options)=>{
    calls++;
    assert.equal(url,vector.base_url+'/models');
    assert.equal(options.redirect,'error');
    assert.equal(options.headers.Authorization,'Bearer '+vector.fixture_key);
    return Response.json({data:[{id:'team/model'}]});
  });
  const rows=new Map();
  const db = {open:0,locks:0, async close(){},async commit(){},async rollback(){},
    async row(statement,{user_id}) {
      if(statement===sql.lock_user){this.locks++;return {USER_ID:user_id};}
      assert.equal(statement,sql.read);
      return rows.get(user_id) ?? null;
    },
    async write(statement,binds) {
      if(statement===sql.delete) return Number(rows.delete(binds.user_id));
      assert.equal(statement,sql.save);
      rows.set(binds.user_id,{PRESET_ID:binds.preset_id,BASE_URL:binds.base_url,MODEL_NAME:binds.model_name,
        SECRET_BOX:binds.secret_box,ENABLED:binds.enabled,REVISION:binds.revision});
      return 1;
    }};
  const event=(body={},ownerId=42)=>({db,ownerId,headers:{},node:{req:Readable.from([Buffer.from(JSON.stringify(body))])}});
  const input={preset:'provided',model:'team/model',enabled:true};
  await assert.rejects(api.readUserProvider(event({},0)),error=>error.statusCode===401);
  await assert.rejects(api.saveUserProvider(event({...input,url:'http://different.example.test'})),error=>error.statusCode===400);
  assert.equal(db.open,0);
  await assert.rejects(api.saveUserProvider(event(input)),error=>error.statusCode===400);
  const saved = (await api.saveUserProvider(event({...input,api_key:vector.fixture_key}))).data;
  assert.deepEqual(saved.config,{...input,key_configured:true,reconnect_required:false,revision:1});
  assert(!JSON.stringify(saved).includes(vector.fixture_key));
  assert(!JSON.stringify(saved).includes(rows.get(42).SECRET_BOX));
  assert.equal((await api.readUserProvider(event({},73))).data.config,null);
  assert.deepEqual((await api.testUserProvider(event())).data,{verified:true});
  assert.equal((await api.personalWritingProvider(event(),42)).selection.profileId,'personal-writing');
  assert.equal(await api.personalWritingAvailability(event()),true);
  const updated=(await api.saveUserProvider(event(input))).data;
  assert.equal(updated.config.revision,2);
  assert.equal(db.locks,3);
  process.env.AI_USER_PROVIDER_URL='https://different.example.test/v1';
  assert.equal((await api.readUserProvider(event())).data.config.reconnect_required,true);
  assert.equal(await api.personalWritingAvailability(event()),false);
  await assert.rejects(api.testUserProvider(event()),error=>error.statusCode===409);
  await assert.rejects(api.saveUserProvider(event(input)),error=>error.statusCode===409);
  assert.equal(calls,1);
  await api.deleteUserProvider(event());
  await api.deleteUserProvider(event());
  assert.equal(await api.personalWritingProvider(event(),42),null);
  delete process.env.AI_USER_PROVIDER_SECRET_B64;
  const before = db.open;
  assert.equal((await api.readUserProvider(event())).data.setup_available,false);
  assert.equal(db.open,before);
});
