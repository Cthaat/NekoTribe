import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';
import * as pinia from 'pinia';
import * as vue from 'vue';

globalThis.__testPinia=pinia;globalThis.__testVue=vue;
const root=fileURLToPath(new URL('../',import.meta.url));
const built=await build({stdin:{contents:"export {usePreferenceStore} from './app/stores/user'; export {authQueueFor} from './app/services/auth-request-queue';",resolveDir:root,loader:'ts'},alias:{'@':root+'app'},bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'state-boundaries',setup(b){
  for(const name of ['pinia','vue','@/services','@/utils/assets','#app'])b.onResolve({filter:new RegExp('^'+name.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+'$')},()=>({path:name,namespace:'stub'}));
  b.onLoad({filter:/.*/,namespace:'stub'},({path})=>({loader:'js',contents:path==='pinia'?`export const defineStore=globalThis.__testPinia.defineStore;`:path==='vue'?`export const computed=globalThis.__testVue.computed;`:path==='#app'?`export const useNuxtApp=()=>globalThis.__stateOwner;`:path==='@/services'?`export const v2RefreshCurrentToken=()=>globalThis.__refreshState();export const v2LogoutCurrent=()=>globalThis.__logoutState();`:`export const normalizeAvatarUrl=x=>x;`}));
}}]});
const module=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text).toString('base64')}`);
function deferred(){let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return {promise,resolve,reject};}
async function fixture(run){
  const instance=pinia.createPinia();pinia.setActivePinia(instance);globalThis.ref=vue.ref;globalThis.useNuxtApp=()=>globalThis.__stateOwner;
  globalThis.useCookie=(name,options)=>vue.ref(options.default());
  globalThis.__stateOwner={runWithContext:action=>action()};const queue=module.authQueueFor(globalThis.__stateOwner);
  globalThis.__logoutState=()=>{queue.beginIdentityChange();return Promise.resolve();};
  const store=module.usePreferenceStore();
  try{await run({store,queue});}finally{const active=pinia.getActivePinia();if(active&&active!==instance)pinia.disposePinia(active);pinia.disposePinia(instance);for(const key of ['ref','useCookie','useNuxtApp','__stateOwner','__refreshState','__logoutState'])delete globalThis[key];}
}

for(const failed of [false,true])test(`old refresh ${failed?'failure':'success'} cannot alter new auth state`,()=>fixture(async({store,queue})=>{
  const gate=deferred();globalThis.__refreshState=()=>gate.promise;
  const pending=store.refreshAccessToken();const caught=pending.catch(()=>{});
  queue.beginIdentityChange();store.setCurrentSession({sessionId:'new',accessTokenExpiresAt:'new-a',refreshTokenExpiresAt:'new-r'});
  if(failed)gate.reject(Error('isolated'));else gate.resolve({sessionId:'old'});
  await caught;assert.equal(store.preferences.authSession.sessionId,'new');
}));

test('new session refresh does not reuse or clear the old in-flight promise',()=>fixture(async({store,queue})=>{
  const old=deferred(),fresh=deferred();globalThis.__refreshState=()=>old.promise;
  const first=store.refreshAccessToken().catch(()=>{});queue.beginIdentityChange();globalThis.__refreshState=()=>fresh.promise;
  const second=store.refreshAccessToken();old.resolve({sessionId:'old'});await first;
  assert.equal(store.isRefreshingToken,true);fresh.resolve({sessionId:'new'});await second;
  assert.equal(store.preferences.authSession.sessionId,'new');assert.equal(store.isRefreshingToken,false);
}));

test('late logout does not reset a newer session',()=>fixture(async({store,queue})=>{
  const gate=deferred();globalThis.__logoutState=()=>{queue.beginIdentityChange();return gate.promise;};
  const old=store.logoutCurrentSession();queue.beginIdentityChange();store.setCurrentSession({sessionId:'new'});
  gate.resolve();assert.equal(await old,null);assert.equal(store.preferences.authSession.sessionId,'new');
}));

test('current logout failure clears local state and returns a current result',()=>fixture(async({store,queue})=>{
  globalThis.__logoutState=()=>{queue.beginIdentityChange();return Promise.reject(Error('isolated'));};
  store.setCurrentSession({sessionId:'old'});const result=await store.logoutCurrentSession();
  assert.equal(store.preferences.authSession,null);assert(result.error);assert(store.isAuthCurrent(result.revision));
}));

for (const failure of [null, undefined, false]) test(`logout rejection ${String(failure)} remains an explicit failure`,()=>fixture(async({store,queue})=>{
  globalThis.__logoutState=()=>{queue.beginIdentityChange();return Promise.reject(failure);};
  store.setCurrentSession({sessionId:'old'});
  const result=await store.logoutCurrentSession();
  assert.equal(result.ok,false);assert.equal(result.error,failure);
  assert.equal(store.preferences.authSession,null);assert(store.isAuthCurrent(result.revision));
}));

test('preference defaults and reset never share auth state across app/store instances',()=>fixture(async({store})=>{
  store.resetToDefaults();store.setCurrentSession({sessionId:'synthetic-private'});
  const secondPinia=pinia.createPinia();pinia.setActivePinia(secondPinia);globalThis.__stateOwner={runWithContext:fn=>fn()};
  const second=module.usePreferenceStore();
  assert.equal(second.preferences.authSession,null);
  second.resetToDefaults();assert.equal(store.preferences.authSession.sessionId,'synthetic-private');
}));

test('same-version refreshes share work and synchronous failure releases busy state',()=>fixture(async({store})=>{
  const gate=deferred();let calls=0;globalThis.__refreshState=()=>{calls++;return gate.promise;};
  const first=store.refreshAccessToken(),second=store.refreshAccessToken();gate.resolve({sessionId:'same'});await Promise.all([first,second]);assert.equal(calls,1);
  globalThis.__refreshState=()=>{throw Error('isolated synchronous');};
  await assert.rejects(store.refreshAccessToken(),/isolated synchronous/);assert.equal(store.isRefreshingToken,false);
}));
