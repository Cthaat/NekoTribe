import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';
import * as vue from 'vue';
import * as pinia from 'pinia';

globalThis.__sessionVue=vue;globalThis.__sessionPinia=pinia;
const root=fileURLToPath(new URL('../',import.meta.url));
const built=await build({
  stdin:{contents:"export {apiFetch} from './app/composables/useApi'; export {usePreferenceStore} from './app/stores/user'; export {authQueueFor} from './app/services/auth-request-queue'; export {v2Login,v2RefreshCurrentToken} from './app/api/v2/auth'; export {v2DeleteMe} from './app/api/v2/users';",resolveDir:root,loader:'ts'},
  alias:{'~':root+'app','@':root+'app'},bundle:true,write:false,platform:'node',format:'esm',
  banner:{js:`
    const window={location:{origin:'http://example.test'},localStorage:{getItem:()=> 'fixture-device'}};
    const tryUseNuxtApp=()=>globalThis.__sessionContext??globalThis.__sessionOwner;
    const useRuntimeConfig=()=>tryUseNuxtApp().$config;
    const useRoute=()=>undefined;
    const useRequestHeaders=()=>({});
    const useCookie=(name,options)=>{const owner=tryUseNuxtApp();if(!owner.cookies.has(name))owner.cookies.set(name,globalThis.__sessionVue.ref(options.default()));return owner.cookies.get(name);};
    const ref=globalThis.__sessionVue.ref;
    const $fetch=(...args)=>globalThis.__sessionWire(...args);
    const console={info(){},error(){}};
  `},plugins:[{name:'session-boundaries',setup(b){
    b.onResolve({filter:/^(vue|pinia|#app|@\/services)$/},args=>({path:args.path,namespace:'stub'}));
    b.onLoad({filter:/.*/,namespace:'stub'},({path})=>({loader:'js',resolveDir:root,contents:
      path==='vue'?`export const computed=globalThis.__sessionVue.computed;export const getCurrentInstance=globalThis.__sessionVue.getCurrentInstance;`:
      path==='pinia'?`export const defineStore=globalThis.__sessionPinia.defineStore;`:
      path==='#app'?`export const useNuxtApp=()=>globalThis.__sessionContext??globalThis.__sessionOwner;`:
      `export {v2RefreshCurrentToken,v2LogoutCurrent} from './app/services/auth';`
    }));
  }}]
});
const api=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text+'\n//# sourceURL=web-api-session-fixture.mjs\n').toString('base64')}`);
function deferred(){let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return {promise,resolve,reject};}
function unauthorized(){return Object.assign(Error('isolated unauthorized'),{statusCode:401,response:{status:401}});}
const refreshed={data:{session_id:'synthetic-session',access_token:'synthetic-access',refresh_token:'synthetic-refresh',access_token_expires_at:'2026-12-01T00:00:00Z',refresh_token_expires_at:'2026-12-02T00:00:00Z'}};
async function fixture(run){
  const instance=pinia.createPinia(),previousPinia=pinia.getActivePinia();
  const owner={$config:{public:{apiBase:''}},cookies:new Map(),runWithContext(fn){
    const previous=globalThis.__sessionContext,active=pinia.getActivePinia();globalThis.__sessionContext=this;pinia.setActivePinia(instance);
    try{return fn();}finally{globalThis.__sessionContext=previous;pinia.setActivePinia(active);}
  }};
  globalThis.__sessionOwner=owner;const store=owner.runWithContext(()=>api.usePreferenceStore());const queue=api.authQueueFor(owner),calls=[];
  const gate=deferred(),started=deferred(),gets=new Map();let failRetry=false;
  globalThis.__sessionWire=(path,options)=>{
    calls.push({path,method:options.method??'GET'});
    if(options.method==='PATCH'){started.resolve();return gate.promise;}
    const count=(gets.get(path)??0)+1;gets.set(path,count);
    return count===1||failRetry?Promise.reject(unauthorized()):Promise.resolve({data:path});
  };
  try{await run({owner,store,queue,calls,gate,started,failRetries:()=>{failRetry=true;}});}finally{
    pinia.disposePinia(instance);pinia.setActivePinia(previousPinia);
    for(const key of ['__sessionOwner','__sessionContext','__sessionWire'])delete globalThis[key];
  }
}

test('actual transport/store/service/API share one refresh for concurrent 401s',()=>fixture(async({store,calls,gate,started})=>{
  const pending=Promise.all([api.apiFetch('/api/v2/posts'),api.apiFetch('/api/v2/users/me')]);
  await started.promise;assert.equal(store.isRefreshingToken,true);
  assert.equal(calls.filter(c=>c.method==='PATCH').length,1);gate.resolve(refreshed);
  const result=await pending;assert.equal(result.length,2);assert.equal(calls.length,5);
  assert.equal(store.preferences.authSession.sessionId,'synthetic-session');assert.equal(store.isRefreshingToken,false);
}));

for(const failed of [false,true])test(`actual in-flight refresh ${failed?'failure':'success'} cannot clear or publish into a new identity`,()=>fixture(async({store,queue,calls,gate,started})=>{
  const rejected=assert.rejects(api.apiFetch('/api/v2/users/me'),error=>error.name==='AbortError');
  await started.promise;queue.beginIdentityChange();store.setCurrentSession({sessionId:'new-identity'});
  if(failed)gate.reject(unauthorized());else gate.resolve(refreshed);await rejected;
  assert.equal(calls.length,2);assert.equal(store.preferences.authSession.sessionId,'new-identity');assert.equal(store.isRefreshingToken,false);
}));

test('current retry 401 clears through the actual store without another refresh',()=>fixture(async({store,calls,gate,started,failRetries})=>{
  failRetries();const rejected=assert.rejects(api.apiFetch('/api/v2/users/me'));
  await started.promise;gate.resolve(refreshed);await rejected;
  assert.equal(calls.length,3);assert.equal(calls.filter(c=>c.method==='PATCH').length,1);
  assert.equal(store.preferences.authSession,null);assert.equal(store.isRefreshingToken,false);
}));

test('current refresh failure clears once through the store and does not retry',()=>fixture(async({store,queue,calls,gate,started})=>{
  store.setCurrentSession({sessionId:'old-identity'});const revision=queue.revision;
  const rejected=assert.rejects(api.apiFetch('/api/v2/users/me'),error=>error.name==='AbortError');
  await started.promise;gate.reject(unauthorized());await rejected;
  assert.equal(calls.length,2);assert.equal(queue.revision,revision+1);
  assert.equal(store.preferences.authSession,null);assert.equal(store.isRefreshingToken,false);
}));

for(const invalid of ['incomplete','different-session'])test(`actual refresh ${invalid} cannot publish state or replay the original request`,()=>fixture(async({store,calls,gate,started})=>{
  store.setCurrentSession({sessionId:'synthetic-session'});
  const rejected=assert.rejects(api.apiFetch('/api/v2/users/me'));
  await started.promise;const response=structuredClone(refreshed);
  if(invalid==='incomplete')delete response.data.access_token;else response.data.session_id='different-session';
  gate.resolve(response);await rejected;assert.equal(calls.length,2);assert.equal(store.preferences.authSession,null);
}));

for(const fails of [false,true])test(`actual deletion ${fails?'business failure':'success'} waits before a new login and does not clear its state`,()=>fixture(async({store})=>{
  store.setCurrentSession({sessionId:'old-session'});
  const gate=deferred(),started=deferred(),wireCalls=[];let cookie='old-cookie';
  globalThis.__sessionWire=async(path,options)=>{
    wireCalls.push({path,method:options.method});
    if(path==='/api/v2/users/me'){
      started.resolve();await gate.promise;
      if(fails)throw unauthorized();
      cookie='';return {data:{deleted:true,user_id:1}};
    }
    cookie='new-cookie';return {data:{}};
  };
  const deletion=assert.rejects(api.v2DeleteMe({password:'x',confirmation:'DELETE'}),error=>error.name==='AbortError');
  await started.promise;const login=api.v2Login({account:'new',password:'x'});
  store.setCurrentSession({sessionId:'new-session'});await Promise.resolve();const count=wireCalls.length;
  gate.resolve();await Promise.all([deletion,login]);
  assert.equal(count,1);assert.equal(cookie,'new-cookie');assert.equal(store.preferences.authSession.sessionId,'new-session');
  assert.deepEqual(wireCalls.map(c=>c.path),['/api/v2/users/me','/api/v2/auth/tokens']);
}));

test('actual deletion queued before a login intent never reaches the transport',()=>fixture(async({gate,started,calls})=>{
  const refresh=assert.rejects(api.v2RefreshCurrentToken(),error=>error.name==='AbortError');await started.promise;
  const deletion=assert.rejects(api.v2DeleteMe({password:'x',confirmation:'DELETE'}),error=>error.name==='AbortError');
  const login=assert.rejects(api.v2Login({account:'new',password:'x'}));
  gate.resolve(refreshed);await Promise.all([refresh,deletion,login]);
  assert.equal(calls.some(c=>c.path==='/api/v2/users/me'),false);
}));
