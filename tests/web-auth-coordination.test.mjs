import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';

const root=fileURLToPath(new URL('../',import.meta.url));
const built=await build({stdin:{contents:"export * from './app/api/v2/auth'; export {v2DeleteMe} from './app/api/v2/users'; export {authQueueFor} from './app/services/auth-request-queue';",resolveDir:root,loader:'ts'},alias:{'@':root+'app'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'web-auth-boundaries',setup(b){
  b.onResolve({filter:/^#app$/},()=>({path:'app',namespace:'stub'}));
  b.onResolve({filter:/^\.\/client$/},()=>({path:'client',namespace:'stub'}));
  b.onLoad({filter:/.*/,namespace:'stub'},({path})=>({loader:'js',contents:path==='app'?`export function useNuxtApp(){return globalThis.__authOwner;}`:`export function v2RequestData(path,options){const owner=globalThis.__authContext??globalThis.__authOwner;globalThis.__authCalls.push({owner:owner.id,path,options});return globalThis.__authRequest(owner,path,options);}export async function v2Request(path,options){return {code:200,message:'success',data:await v2RequestData(path,options),meta:null};}export const toV2PagedResult=x=>x;`}));
}}]});
const api=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
function app(id){return {id,runWithContext(action){const previous=globalThis.__authContext;globalThis.__authContext=this;try{return action();}finally{globalThis.__authContext=previous;}}};}
function defer(){let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return {promise,resolve,reject};}
async function fixture(run){globalThis.__authCalls=[];try{await run();}finally{for(const key of ['__authCalls','__authOwner','__authContext','__authRequest'])delete globalThis[key];}}

test('all auth mutations wait for the previous response and preserve their call order',()=>fixture(async()=>{
  const gate=defer();globalThis.__authOwner=app('one');let first=true;
  globalThis.__authRequest=()=>{if(first){first=false;return gate.promise;}return Promise.resolve({});};
  const refresh=api.v2RefreshCurrentToken();await Promise.resolve();
  const login=api.v2Login({account:'edge',password:'x'});
  const challenge=api.v2CompleteTwoFactorLogin('challenge',{code:'123456'});const logout=api.v2LogoutCurrent();
  await Promise.resolve();
  try{assert.equal(globalThis.__authCalls.length,1);}finally{gate.resolve({});await Promise.all([refresh,login,challenge,logout]);}
  assert.deepEqual(globalThis.__authCalls.map(c=>c.options.method),['PATCH','POST','POST','DELETE']);
}));

test('failure propagates while the next queued mutation still executes',()=>fixture(async()=>{
  const gate=defer();globalThis.__authOwner=app('failure');let first=true;
  globalThis.__authRequest=()=>{if(first){first=false;return gate.promise;}return Promise.resolve({});};
  const refresh=api.v2RefreshCurrentToken();const failure=assert.rejects(refresh,/isolated/);
  const login=api.v2Login({account:'edge',password:'x'});await Promise.resolve();
  gate.reject(Error('isolated'));await failure;await login;
  assert.equal(globalThis.__authCalls.length,2);
}));

test('queued credential inputs are captured before callers edit their forms',()=>fixture(async()=>{
  const gate=defer();globalThis.__authOwner=app('snapshot');let first=true;
  globalThis.__authRequest=()=>{if(first){first=false;return gate.promise;}return Promise.resolve({});};
  const refresh=api.v2RefreshCurrentToken();await Promise.resolve();
  const loginPayload={account:'original',password:'synthetic'};
  const challengePayload={code:'123456'};
  const login=api.v2Login(loginPayload),challenge=api.v2CompleteTwoFactorLogin('challenge',challengePayload);
  loginPayload.account='changed';challengePayload.code='999999';
  gate.resolve({});await Promise.all([refresh,login,challenge]);
  assert.equal(globalThis.__authCalls[1].options.body.account,'original');
  assert.equal(globalThis.__authCalls[2].options.body.code,'123456');
}));

test('SSR/app owners are isolated and queued calls restore their original context',()=>fixture(async()=>{
  const gate=defer(),one=app('one'),two=app('two');
  globalThis.__authRequest=(owner,path)=>owner===one&&path.endsWith('/current')?gate.promise:Promise.resolve({});
  globalThis.__authOwner=one;const refresh=api.v2RefreshCurrentToken();await Promise.resolve();
  const queued=api.v2Login({account:'one',password:'x'});
  globalThis.__authOwner=two;await api.v2Login({account:'two',password:'x'});
  try{assert.deepEqual(globalThis.__authCalls.map(c=>c.owner),['one','two']);}finally{gate.resolve({});await Promise.all([refresh,queued]);}
  assert.equal(globalThis.__authCalls.at(-1).owner,'one');
}));

test('identity mutations invalidate synchronously while queued, with app-local revisions',()=>fixture(async()=>{
  const gate=defer(),one=app('one'),two=app('two');globalThis.__authOwner=one;
  const queue=api.authQueueFor(one);globalThis.__authRequest=()=>gate.promise;
  const refresh=api.v2RefreshCurrentToken();assert.equal(queue.revision,0);
  const login=api.v2Login({account:'one',password:'x'});assert.equal(queue.revision,1);
  const challenge=api.v2CompleteTwoFactorLogin('challenge',{code:'123456'});assert.equal(queue.revision,2);
  const logout=api.v2LogoutCurrent();assert.equal(queue.revision,3);
  assert.equal(api.authQueueFor(two).revision,0);
  gate.resolve({});await Promise.all([refresh,login,challenge,logout]);assert.equal(queue.revision,3);
}));

test('deletion response precedes a later login Cookie even when its JS result is superseded',()=>fixture(async()=>{
  const gate=defer(),started=defer();globalThis.__authOwner=app('delete-first');let cookie='old';
  globalThis.__authRequest=async(owner,path)=>{if(path==='/api/v2/users/me'){started.resolve();await gate.promise;cookie='';return {deleted:true,user_id:1};}cookie='new-login';return {};};
  const deletion=assert.rejects(api.v2DeleteMe({password:'x',confirmation:'DELETE'}),e=>e.name==='AbortError');
  await started.promise;const login=api.v2Login({account:'new',password:'x'});await Promise.resolve();
  const startedCount=globalThis.__authCalls.length;gate.resolve();await Promise.all([deletion,login]);
  assert.equal(startedCount,1);assert.equal(cookie,'new-login');
  assert.deepEqual(globalThis.__authCalls.map(c=>c.path),['/api/v2/users/me','/api/v2/auth/tokens']);
}));

test('deletion waiting for refresh is cancelled before the wire when a newer login is queued',()=>fixture(async()=>{
  const gate=defer(),started=defer();globalThis.__authOwner=app('queued-delete');
  globalThis.__authRequest=async(owner,path)=>{if(path.endsWith('/current')){started.resolve();await gate.promise;}return {};};
  const refresh=api.v2RefreshCurrentToken();await started.promise;
  const deletion=assert.rejects(api.v2DeleteMe({password:'x',confirmation:'DELETE'}),e=>e.name==='AbortError');
  const login=api.v2Login({account:'new',password:'x'});gate.resolve();await Promise.all([refresh,deletion,login]);
  assert.equal(globalThis.__authCalls.some(c=>c.path==='/api/v2/users/me'),false);
}));

for(const change of ['login','challenge','logout'])test(`deletion cannot bind to an already pending ${change}`,()=>fixture(async()=>{
  const gate=defer(),started=defer();globalThis.__authOwner=app(change);
  globalThis.__authRequest=async()=>{started.resolve();await gate.promise;return {};};
  const pending=change==='login'?api.v2Login({account:'new',password:'x'}):change==='challenge'?api.v2CompleteTwoFactorLogin('challenge',{code:'123456'}):api.v2LogoutCurrent();
  await started.promise;const deletion=assert.rejects(api.v2DeleteMe({password:'x',confirmation:'DELETE'}),e=>e.name==='AbortError');
  gate.resolve();await Promise.all([pending,deletion]);assert.equal(globalThis.__authCalls.length,1);
}));

test('deletion captures its payload and original app while another app remains independent',()=>fixture(async()=>{
  const gate=defer(),started=defer(),one=app('one'),two=app('two');globalThis.__authOwner=one;
  globalThis.__authRequest=async(owner,path)=>{if(owner===one&&path.endsWith('/current')){started.resolve();await gate.promise;}return {deleted:true,user_id:1};};
  const refresh=api.v2RefreshCurrentToken();await started.promise;const form={password:'original',confirmation:'DELETE'};
  const deletion=api.v2DeleteMe(form);form.password='edited';globalThis.__authOwner=two;
  await api.v2Login({account:'two',password:'x'});gate.resolve();await Promise.all([refresh,deletion]);
  assert.deepEqual(globalThis.__authCalls.map(c=>c.owner),['one','two','one']);
  assert.equal(globalThis.__authCalls.at(-1).options.body.password,'original');
}));

test('failed deletion releases the queue and identity pending state clears after failed login',()=>fixture(async()=>{
  globalThis.__authOwner=app('failure-release');globalThis.__authRequest=()=>Promise.reject(Error('isolated'));
  await assert.rejects(api.v2Login({account:'new',password:'x'}),/isolated/);
  await assert.rejects(api.v2DeleteMe({password:'x',confirmation:'DELETE'}),/isolated/);
  globalThis.__authRequest=()=>Promise.resolve({deleted:true,user_id:1});
  assert.equal((await api.v2DeleteMe({password:'x',confirmation:'DELETE'})).deleted,true);
}));

for(const fails of [false,true])test(`identity observers see login intent and ${fails?'failed':'successful'} completion synchronously`,()=>fixture(async()=>{
 const gate=defer(),owner=app('signal');globalThis.__authOwner=owner;globalThis.__authRequest=()=>gate.promise;
 const queue=api.authQueueFor(owner),events=[];const stop=queue.subscribe(()=>events.push([queue.revision,queue.isIdentityChanging]));
 const login=api.v2Login({account:'same-account',password:'x'});const completion=fails?assert.rejects(login,/isolated/):login;
 assert.deepEqual(events,[[1,true]]);assert.equal(queue.isIdentityChanging,true);
 if(fails)gate.reject(Error('isolated'));else gate.resolve({});await completion;
 assert.deepEqual(events,[[1,true],[1,false]]);stop();queue.beginIdentityChange();assert.equal(events.length,2);
}));

test('identity observers are app-local and ordinary refresh work preserves an open page',()=>fixture(async()=>{
 const one=app('one'),two=app('two'),events=[];const queue=api.authQueueFor(one),stop=queue.subscribe(()=>events.push(queue.revision));
 globalThis.__authOwner=one;globalThis.__authRequest=()=>Promise.resolve({});await api.v2RefreshCurrentToken();
 api.authQueueFor(two).beginIdentityChange();assert.deepEqual(events,[]);
 queue.beginIdentityChange();assert.deepEqual(events,[1]);stop();
}));

test('an observer failure cannot prevent identity invalidation or the authentication request',()=>fixture(async()=>{
 const owner=app('observer-failure');globalThis.__authOwner=owner;globalThis.__authRequest=()=>Promise.resolve({});
 const queue=api.authQueueFor(owner),events=[];queue.subscribe(()=>{throw Error('isolated observer');});queue.subscribe(()=>events.push(queue.revision));
 await api.v2Login({account:'same',password:'x'});assert.equal(queue.revision,1);assert.equal(queue.isIdentityChanging,false);assert.equal(globalThis.__authCalls.length,1);assert.deepEqual(events,[1,1]);
}));
