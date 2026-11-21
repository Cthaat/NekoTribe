import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';

const root=fileURLToPath(new URL('../',import.meta.url));
const built=await build({stdin:{contents:"export {useApiFetch} from './app/composables/useApiFetch';export {authQueueFor} from './app/services/auth-request-queue';",resolveDir:root,loader:'ts'},alias:{'~':root+'app'},bundle:true,write:false,platform:'node',format:'esm',
  banner:{js:`
    const tryUseNuxtApp=()=>globalThis.__adapterContext??globalThis.__adapterOwner;
    const useRuntimeConfig=()=>tryUseNuxtApp().$config;
    const useRoute=()=>undefined,useRequestHeaders=()=>globalThis.__adapterHeaders??{},ref=value=>({value});
    const $fetch=(...args)=>globalThis.__adapterWire(...args);
    const console={info(){},error(){}};
  `},plugins:[{name:'adapter-boundaries',setup(b){
    b.onResolve({filter:/^(#app|vue|~\/stores\/user)$/},args=>({path:args.path,namespace:'stub'}));
    b.onLoad({filter:/.*/,namespace:'stub'},({path})=>({contents:path==='vue'?`export const getCurrentInstance=()=>null;export const watch=()=>{globalThis.__adapterWatches++;};`:
      path==='~/stores/user'?`export const usePreferenceStore=()=>globalThis.__adapterContext.store;`:
      `export const useNuxtApp=()=>globalThis.__adapterContext??globalThis.__adapterOwner;export const useFetch=(path,options)=>{const result={options,error:{value:undefined},status:{value:'idle'},execute:()=>{const {$fetch:custom,...fetchOptions}=options;return (custom??globalThis.__adapterWire)(path,fetchOptions);}};result.refresh=result.execute;return result;};`
    }));
  }}]});
const api=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text+'\n//# sourceURL=use-api-fetch-fixture.mjs\n').toString('base64')}`);
function app(id){const owner={$config:{public:{apiBase:'http://'+id+'.example.test'}},refreshes:0,clears:0,runWithContext(fn){const previous=globalThis.__adapterContext;globalThis.__adapterContext=this;try{return fn();}finally{globalThis.__adapterContext=previous;}}};owner.queue=api.authQueueFor(owner);owner.store={async refreshAccessToken(){owner.refreshes++;},clearAuthState(){owner.clears++;owner.queue.beginIdentityChange();}};return owner;}
function deferred(){let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return {promise,resolve,reject};}
function unauthorized(){return Object.assign(Error('isolated unauthorized'),{statusCode:401,response:{status:401}});}
async function fixture(run){const one=app('one'),two=app('two'),calls=[];let wire=()=>Promise.resolve({ok:true});globalThis.__adapterOwner=one;globalThis.__adapterWatches=0;globalThis.__adapterWire=(path,options)=>{calls.push({path,options});return wire(path,options);};try{await run({one,two,calls,setWire:fn=>{wire=fn;}});}finally{for(const key of ['__adapterOwner','__adapterContext','__adapterWatches','__adapterWire'])delete globalThis[key];}}

test('useApiFetch delegates current 401 to the single guarded recovery path',()=>fixture(async({one,calls,setWire})=>{
  globalThis.window={};
  try {
    setWire(()=>calls.length===1?Promise.reject(unauthorized()):Promise.resolve({ok:true}));
    const result=api.useApiFetch('/api/v2/users/me');assert.deepEqual(await result.execute(),{ok:true});
    assert.equal(calls.length,2);assert.equal(one.refreshes,1);assert.equal(globalThis.__adapterWatches,0);
  } finally {
    delete globalThis.window;
  }
}));
test('adapter cannot be redirected to a caller-provided unguarded fetch',()=>fixture(async({calls})=>{
  let bypass=0;const result=api.useApiFetch('/api/v2/posts',{$fetch:()=>{bypass++;return Promise.resolve({});}});
  await result.execute();assert.equal(bypass,0);assert.equal(calls.length,1);assert.equal(calls[0].options.retry,0);
}));

test('SSR uses the private transport base while the browser keeps the public base', () => fixture(async ({one, calls}) => {
  one.$config.apiServerBase = ' http://go:30006/backend/// ';
  globalThis.__adapterHeaders = { cookie: 'session=fixture', authorization: 'Bearer fixture' };
  const request = api.useApiFetch('/api/v2/posts', { server: true });
  try {
    await request.execute();
    assert.equal(request.options.baseURL, 'http://one.example.test');
    assert.equal(calls[0].options.baseURL, 'http://go:30006/backend');
    assert.equal(calls[0].options.headers.cookie, 'session=fixture');
    assert.equal(calls[0].options.headers.authorization, 'Bearer fixture');

    globalThis.window = {};
    await request.refresh();
    assert.equal(calls[1].options.baseURL, 'http://one.example.test');
    assert.equal(calls[1].options.headers.cookie, undefined);
    assert.equal(calls[1].options.headers.authorization, undefined);
  } finally {
    delete globalThis.window;
    delete globalThis.__adapterHeaders;
  }
}));

test('SSR rejects an invalid private base before sending any request and accepts an empty same-origin fallback', () => fixture(async ({one, calls}) => {
  const request = api.useApiFetch('/api/v2/posts', { server: true });
  for (const invalid of ['/backend', 'ws://go', 'http://@go', 'https://go?', 'https://go/#', 'http://go:0']) {
    one.$config.apiServerBase = invalid;
    await assert.rejects(request.execute(), /NUXT_API_SERVER_BASE/);
  }
  assert.equal(calls.length, 0);

  one.$config.apiServerBase = ' ';
  one.$config.public.apiBase = '';
  await request.execute();
  assert.equal(calls[0].options.baseURL, '');
}));
test('SSR leaves an expired browser session available for client-side recovery', () => fixture(async ({one,calls,setWire}) => {
  one.$config.apiServerBase='http://go:30006/backend';
  globalThis.__adapterHeaders={cookie:'session=fixture'};
  setWire(()=>calls.length<3?Promise.reject(unauthorized()):Promise.resolve({ok:true}));
  const request=api.useApiFetch('/api/v2/users/me',{server:true});
  try {
    await assert.rejects(request.execute());
    assert.equal(calls.length,1);
    assert.equal(calls[0].options.baseURL,'http://go:30006/backend');
    assert.equal(calls[0].options.headers.cookie,'session=fixture');
    assert.equal(one.refreshes,0);
    assert.equal(one.clears,0);

    globalThis.window={};
    assert.deepEqual(await request.refresh(),{ok:true});
    assert.equal(one.refreshes,1);
    assert.equal(one.clears,0);
    assert.equal(calls.length,3);
    assert.ok(calls.slice(1).every(call=>call.options.baseURL==='http://one.example.test'));
  } finally {
    delete globalThis.window;
    delete globalThis.__adapterHeaders;
  }
}));
test('delayed adapter execution and explicit refresh keep the creating app',()=>fixture(async({one,two,calls})=>{
  const result=api.useApiFetch('/api/v2/posts');globalThis.__adapterOwner=two;two.queue.beginIdentityChange();
  await result.execute();await result.refresh();assert.equal(one.refreshes,0);assert.equal(two.refreshes,0);
  assert(calls.every(c=>c.options.baseURL==='http://one.example.test'));
}));
test('adapter old successful response is cancelled by the common identity guard',()=>fixture(async({one,setWire})=>{
  const gate=deferred();setWire(()=>gate.promise);const result=api.useApiFetch('/api/v2/users/me');
  const rejected=assert.rejects(result.execute(),error=>error.name==='AbortError');one.queue.beginIdentityChange();gate.resolve({private:'old'});await rejected;
}));
test('adapter auth entry failure never refreshes or automatically replays',()=>fixture(async({one,calls,setWire})=>{
  setWire(()=>Promise.reject(unauthorized()));const result=api.useApiFetch('/api/v2/auth/tokens',{method:'POST'});
  await assert.rejects(result.execute());assert.equal(calls.length,1);assert.equal(one.refreshes,0);
}));
test('adapter preserves Nuxt options, caller hooks, body, headers and default server=false',()=>fixture(async({calls})=>{
  const body={content:'synthetic'},transform=value=>value,onResponse=()=>{};
  const result=api.useApiFetch('/api/v2/posts',{method:'POST',body,transform,onResponse,key:'synthetic-key',watch:false,headers:{Accept:'application/problem+json'}});
  assert.equal(result.options.transform,transform);assert.equal(result.options.key,'synthetic-key');assert.equal(result.options.watch,false);assert.equal(result.options.server,false);
  await result.execute();assert.equal(calls[0].options.body,body);assert.equal(calls[0].options.headers.Accept,'application/problem+json');assert.equal(calls[0].options.credentials,'include');
  assert.equal(api.useApiFetch('/api/v2/posts',{server:true}).options.server,true);
}));
