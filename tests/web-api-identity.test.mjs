import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';
import {createFetch} from 'ofetch';

const root=fileURLToPath(new URL('../',import.meta.url));
const built=await build({
  stdin:{contents:"export {apiFetch} from './app/composables/useApi'; export {authQueueFor} from './app/services/auth-request-queue'; export * from './app/utils/private-media'; export {savePrivateStream} from './app/utils/private-media-save'; export {v2UploadMedia} from './app/api/v2/posts'; export {v2GetMe,v2GetUserById} from './app/api/v2/users';",resolveDir:root,loader:'ts'},
  alias:{'~':root+'app','@':root+'app'},bundle:true,write:false,platform:'node',format:'esm',
  banner:{js:`
    const tryUseNuxtApp=()=>globalThis.__apiOwner;
    const useRuntimeConfig=()=>({public:{apiBase:''}});
    const useRoute=()=>undefined;
    const useRequestHeaders=()=>({cookie:'synthetic=1'});
    const $fetch=(...args)=>globalThis.__apiWire(...args);
    const console={info:(...args)=>globalThis.__apiLogs.push(args),error:(...args)=>globalThis.__apiLogs.push(args)};
  `},
  plugins:[{name:'api-identity-boundaries',setup(b){
    b.onResolve({filter:/^(vue|#app|~\/stores\/user)$/},args=>({path:args.path,namespace:'stub'}));
    b.onLoad({filter:/.*/,namespace:'stub'},({path})=>({loader:'js',contents:path==='vue'
      ? 'export const getCurrentInstance=()=>null;'
      : path==='#app'
        ? 'export const useNuxtApp=()=>globalThis.__apiOwner;'
        : `export const usePreferenceStore=()=>{const owner=globalThis.__apiContext;if(!owner)throw Error('Missing captured app context');owner.storeReads++;return owner.store;};`}));
  }}]
});
const api=await import(`data:text/javascript;base64,${Buffer.from(built.outputFiles[0].text+'\n//# sourceURL=web-api-identity-fixture.mjs\n').toString('base64')}`);
function deferred(){let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return {promise,resolve,reject};}
function unauthorized(status=401){return Object.assign(Error('isolated transport'),{statusCode:status,response:{status,_data:{message:'synthetic old account detail'}}});}
function app(id){
  const owner={id,$config:{public:{apiBase:'http://'+id+'.example.test'}},storeReads:0,refreshes:0,clears:0,
    runWithContext(fn){const previous=globalThis.__apiContext;globalThis.__apiContext=this;try{return fn();}finally{globalThis.__apiContext=previous;}}
  };
  owner.queue=api.authQueueFor(owner);
  owner.store={async refreshAccessToken(){owner.refreshes++;},clearAuthState(){owner.clears++;owner.queue.beginIdentityChange();}};
  return owner;
}
async function fixture(run){
  const one=app('one'),two=app('two'),calls=[];
  globalThis.window={};
  globalThis.__apiOwner=one;globalThis.__apiLogs=[];
  let wire=()=>Promise.resolve({ok:true});
  globalThis.__apiWire=(path,options)=>{calls.push({path,options});return wire(path,options);};
  try{await run({one,two,calls,setWire:fn=>{wire=fn;}});}finally{for(const key of ['window','__apiOwner','__apiContext','__apiLogs','__apiWire'])delete globalThis[key];}
}
function cancelled(promise){return assert.rejects(promise,error=>error.name==='AbortError'&&!error.message.includes('account detail'));}
function mediaReceipt(publicUrl) {
  return {code: 200, message: 'media uploaded', meta: null, data: {
    media_id: 7, public_url: publicUrl, status: 'ready', thumbnail_url: null
  }};
}

test('current profile requires its success envelope and a positive numeric identity', () => fixture(async ({calls,setWire}) => {
  const receipt = {code: 200, message: 'success', meta: null, data: {user_id: 42}};
  setWire(async () => receipt);
  assert.equal((await api.v2GetMe()).user_id, 42);
  assert.equal(calls[0].path, '/api/v2/users/me');
  for (const change of [{code: 201}, {message: 'OK'}, {meta: undefined}, {data: {user_id: '42'}}, {data: {user_id: 0}}]) {
    setWire(async () => ({...receipt, ...change}));
    await assert.rejects(api.v2GetMe(), /Invalid current user profile response/);
  }
}));

test('public profile accepts only the requested numeric identity', () => fixture(async ({calls,setWire}) => {
  setWire(async () => ({data: {user_id: 42}}));
  assert.equal((await api.v2GetUserById(42)).user_id, 42);
  assert.equal(calls[0].path, '/api/v2/users/42');
  for (const data of [null, {user_id: 43}, {user_id: '42'}]) {
    setWire(async () => ({data}));
    await assert.rejects(api.v2GetUserById(42), /Invalid public profile response/);
  }
}));

test('private media paths are canonical and bound to the exact safe ID', () => {
  assert.equal(api.privateMediaContentPath(7), '/api/v2/media/7/content');
  for (const id of [0, -7, 7.1, Number.MAX_SAFE_INTEGER + 1]) assert.equal(api.privateMediaContentPath(id), null);
  assert.equal(api.isPrivateMediaContent(7, '/api/v2/media/7/content'), true);
  for (const url of ['/api/v2/media/8/content', '/api/v2/media/07/content', '/api/v2/media/7/content?token=x', 'https://other.test/api/v2/media/7/content']) {
    assert.equal(api.isPrivateMediaContent(7, url), false);
  }
});

test('a legacy backend cannot receive a private body at the public path', () => fixture(async ({one,calls,setWire}) => {
  setWire(path => path === '/api/v2/media/private'
    ? Promise.reject(unauthorized(404))
    : Promise.resolve(mediaReceipt('/storage/example.txt')));
  const privateForm = new FormData();
  privateForm.append('file', new Blob(['private bytes']), 'example.txt');
  privateForm.append('access_scope', 'chat');
  await assert.rejects(api.v2UploadMedia(privateForm), { statusCode: 404 });
  assert.deepEqual(calls.map(call => call.path), ['/api/v2/media/private']);
  assert.equal(calls[0].options.redirect, 'error');
  assert.equal(one.refreshes, 0);

  const publicForm = new FormData();
  publicForm.append('file', new Blob(['public bytes']), 'example.txt');
  assert.deepEqual(await api.v2UploadMedia(publicForm), mediaReceipt('/storage/example.txt').data);
  assert.equal(calls[1].path, '/api/v2/media');
  assert.equal(calls[1].options.redirect, undefined);
}));

test('upload refreshes authentication without resending and validates the resulting receipt', () => fixture(async ({one,calls,setWire}) => {
  const form = new FormData();
  form.append('file', new Blob(['upload']), 'example.txt');
  form.append('access_scope', 'post');
  setWire(() => Promise.reject(unauthorized()));
  await assert.rejects(api.v2UploadMedia(form), {statusCode: 401});
  assert.equal(one.refreshes, 1);
  assert.equal(calls.length, 1);

  const receipt = mediaReceipt('/api/v2/media/7/content');
  setWire(async () => receipt);
  assert.deepEqual(await api.v2UploadMedia(form), receipt.data);
  for (const invalid of [
    { ...receipt, message: 'success' },
    { ...receipt, data: { ...receipt.data, status: 'pending' } },
    { ...receipt, data: { ...receipt.data, thumbnail_url: undefined } },
    mediaReceipt('/storage/example.txt'),
  ]) {
    setWire(async () => invalid);
    await assert.rejects(api.v2UploadMedia(form), /Invalid uploaded attachment/);
  }
  form.set('access_scope', 'public');
  setWire(async () => receipt);
  await assert.rejects(api.v2UploadMedia(form), /Invalid uploaded attachment/);
}));

test('private media downloads retain the response mode across an authenticated retry', () => fixture(async ({one,calls,setWire}) => {
  const blob = new Blob(['ok'], {type:'application/octet-stream'});
  setWire(() => calls.length === 1 ? Promise.reject(unauthorized()) : Promise.resolve(blob));
  const path = api.privateMediaContentPath(7);
  assert.equal(await api.apiFetch(path, { responseType:'blob', cache:'no-store', redirect:'error' }), blob);
  assert.equal(one.refreshes, 1);
  assert.equal(calls.length, 2);
  for (const call of calls) {
    assert.equal(call.path, path);
    assert.equal(call.options.responseType, 'blob');
    assert.equal(call.options.cache, 'no-store');
    assert.equal(call.options.redirect, 'error');
    assert.equal(call.options.credentials, 'include');
  }
}));

test('private media streaming retains authentication retry and commits only after reading', () => fixture(async ({one,calls,setWire}) => {
  const body = new ReadableStream({start(controller) {
    controller.enqueue(Uint8Array.of(1, 2));
    controller.enqueue(Uint8Array.of(3));
    controller.close();
  }});
  setWire(() => calls.length === 1 ? Promise.reject(unauthorized()) : Promise.resolve(body));
  const events = [];
  await api.savePrivateStream(async ({suggestedName}) => {
    events.push(['pick', suggestedName]);
    return {async createWritable() {
      return new WritableStream({write: chunk => {events.push([...chunk]);}, close: () => {events.push('commit');}});
    }};
  }, 'attachment.bin', () => api.apiFetch('/api/v2/media/7/content', {responseType:'stream', redirect:'error'}), new AbortController().signal);
  assert.deepEqual(events, [['pick','attachment.bin'],[1,2],[3],'commit']);
  assert.equal(one.refreshes, 1);
  assert.deepEqual(calls.map(call => call.options.responseType), ['stream','stream']);
}));

test('a cancelled browser save aborts its writer without committing', async () => {
  const job = new AbortController();
  const events = [];
  const body = new ReadableStream({start(controller) {controller.enqueue(Uint8Array.of(1));}});
  await assert.rejects(api.savePrivateStream(async () => ({async createWritable() {
    return new WritableStream({
      write() {events.push('write'); job.abort();},
      abort() {events.push('abort');},
      close() {events.push('commit');},
    });
  }}), 'attachment.bin', async () => body, job.signal), {name:'AbortError'});
  assert.deepEqual(events, ['write','abort']);
});

test('private media bytes that finish after an account change are discarded', () => fixture(async ({one,setWire}) => {
  const receipt = deferred();
  setWire(() => receipt.promise);
  const rejected = cancelled(api.apiFetch(api.privateMediaContentPath(7), { responseType:'blob' }));
  one.queue.beginIdentityChange();
  receipt.resolve(new Blob(['old account'], {type:'application/octet-stream'}));
  await rejected;
}));

test('old successful response cannot be delivered to a newer identity',()=>fixture(async({one,setWire})=>{
  const gate=deferred();setWire(()=>gate.promise);
  const pending=api.apiFetch('/api/v2/users/me');const rejected=cancelled(pending);
  one.queue.beginIdentityChange();gate.resolve({private:'old account'});await rejected;
}));

for(const status of [401,403,500])test(`old ${status} cannot refresh, clear or publish old error details`,()=>fixture(async({one,setWire})=>{
  const gate=deferred();setWire(()=>gate.promise);
  const rejected=cancelled(api.apiFetch('/api/v2/users/me'));
  one.queue.beginIdentityChange();gate.reject(unauthorized(status));await rejected;
  assert.equal(one.refreshes,0);assert.equal(one.clears,0);
  assert(!JSON.stringify(globalThis.__apiLogs).includes('synthetic old account detail'));
}));

for(const [path,method]of [['/api/v2/users/me','DELETE'],['/api/v2/users/me/two-factor/setup','POST'],['/api/v2/users/me/two-factor/confirm','POST'],['/api/v2/users/me/two-factor','DELETE']])test(`credential ${method} ${path} 401 never refreshes/replays/clears`,()=>fixture(async({one,calls,setWire})=>{setWire(()=>Promise.reject(unauthorized()));await assert.rejects(api.apiFetch(path,{method}));assert.equal(calls.length,1);assert.equal(one.refreshes,0);assert.equal(one.clears,0);}));
test('a current 401 refreshes then retries once with the original request options',()=>fixture(async({one,calls,setWire})=>{
  setWire(()=>calls.length===1?Promise.reject(unauthorized()):Promise.resolve({ok:'retried'}));
  const body={content:'synthetic'};
  assert.deepEqual(await api.apiFetch('/api/v2/posts',{method:'POST',body}),{ok:'retried'});
  assert.equal(calls.length,2);assert.equal(one.refreshes,1);assert.equal(one.clears,0);
  assert.equal(calls[1].options.body,body);assert.equal(calls[0].options.credentials,'include');
}));

test('401 after retry clears only the current identity and never starts another refresh',()=>fixture(async({one,calls,setWire})=>{
  setWire(()=>Promise.reject(unauthorized()));
  await assert.rejects(api.apiFetch('/api/v2/users/me'));
  assert.equal(calls.length,2);assert.equal(one.refreshes,1);assert.equal(one.clears,1);
}));

for(const failed of [false,true])test(`identity change during refresh ${failed?'failure':'success'} prevents retry and cleanup`,()=>fixture(async({one,calls,setWire})=>{
  const gate=deferred(),started=deferred();setWire(()=>Promise.reject(unauthorized()));
  one.store.refreshAccessToken=()=>{one.refreshes++;started.resolve();return gate.promise;};
  const rejected=cancelled(api.apiFetch('/api/v2/users/me'));await started.promise;
  one.queue.beginIdentityChange();if(failed)gate.reject(Error('old refresh detail'));else gate.resolve();
  await rejected;assert.equal(calls.length,1);assert.equal(one.clears,0);
}));

for(const failed of [false,true])test(`identity change during retry ${failed?'401':'success'} prevents publication and cleanup`,()=>fixture(async({one,calls,setWire})=>{
  const gate=deferred(),started=deferred();setWire(()=>{if(calls.length===1)return Promise.reject(unauthorized());started.resolve();return gate.promise;});
  const rejected=cancelled(api.apiFetch('/api/v2/users/me'));await started.promise;
  one.queue.beginIdentityChange();if(failed)gate.reject(unauthorized());else gate.resolve({private:'old retry'});
  await rejected;assert.equal(calls.length,2);assert.equal(one.clears,0);
}));

for(const path of ['/api/v2/auth/tokens','/api/v2/auth/two-factor/challenges/challenge','/api/v2/auth/tokens/current','/api/v2/auth/password-reset','/api/v2/users/me/email','https://one.example.test/api/v2/users/me/email?source=safety'])test(`auth operation ${path} is never automatically replayed`,()=>fixture(async({one,calls,setWire})=>{
  setWire(()=>Promise.reject(unauthorized()));await assert.rejects(api.apiFetch(path,{method:path.includes('/users/me/email')?'PATCH':'POST'}));
  assert.equal(calls.length,1);assert.equal(one.refreshes,0);assert.equal(one.clears,0);
}));

test('current non-401 request or retry errors do not clear state',()=>fixture(async({one,calls,setWire})=>{
  setWire(()=>Promise.reject(unauthorized(503)));await assert.rejects(api.apiFetch('/api/v2/users/me'));assert.equal(calls.length,1);assert.equal(one.refreshes,0);
  setWire(()=>calls.length===2?Promise.reject(unauthorized()):Promise.reject(unauthorized(503)));
  await assert.rejects(api.apiFetch('/api/v2/users/me'));assert.equal(calls.length,3);assert.equal(one.refreshes,1);assert.equal(one.clears,0);
}));

test('a request keeps its original app after global context switches',()=>fixture(async({one,two,calls,setWire})=>{
  const gate=deferred();setWire(()=>calls.length===1?gate.promise:Promise.resolve({ok:true}));
  const pending=api.apiFetch('/api/v2/users/me');two.queue.beginIdentityChange();globalThis.__apiOwner=two;gate.reject(unauthorized());await pending;
  assert.equal(one.refreshes,1);assert.equal(two.refreshes,0);assert.equal(one.storeReads,1);
  assert(calls.every(c=>c.options.baseURL==='http://one.example.test'));
}));

test('identity change while loading the store prevents starting refresh',()=>fixture(async({one,calls,setWire})=>{
  const gate=deferred();setWire(()=>gate.promise);
  const rejected=cancelled(api.apiFetch('/api/v2/users/me'));gate.reject(unauthorized());
  await Promise.resolve();one.queue.beginIdentityChange();await rejected;
  assert.equal(calls.length,1);assert.equal(one.storeReads,0);assert.equal(one.refreshes,0);
}));

test('an already cancelled request never reaches the network',()=>fixture(async({calls})=>{
  const controller=new AbortController();controller.abort();
  await cancelled(api.apiFetch('/api/v2/users/me',{signal:controller.signal}));assert.equal(calls.length,0);
}));

test('missing app cannot borrow a newly available app for automatic refresh',()=>fixture(async({two,calls,setWire})=>{
  const gate=deferred();setWire(()=>gate.promise);globalThis.__apiOwner=null;
  const pending=api.apiFetch('/api/v2/users/me');const rejected=assert.rejects(pending);
  globalThis.__apiOwner=two;gate.reject(unauthorized());await rejected;
  assert.equal(two.refreshes,0);assert.equal(calls.length,1);
}));

test('caller cancellation during refresh prevents sending the original request again',()=>fixture(async({one,calls,setWire})=>{
  const gate=deferred(),started=deferred(),controller=new AbortController();setWire(()=>Promise.reject(unauthorized()));
  one.store.refreshAccessToken=()=>{started.resolve();return gate.promise;};
  const rejected=cancelled(api.apiFetch('/api/v2/users/me',{signal:controller.signal}));await started.promise;
  controller.abort();gate.resolve();await rejected;assert.equal(calls.length,1);assert.equal(one.clears,0);
}));

test('actual ofetch cannot add hidden retries even when callers request them',()=>fixture(async({one,calls,setWire})=>{
  let wireCalls=0;
  const client=createFetch({fetch:async()=>{wireCalls++;return new Response(JSON.stringify({message:'isolated unavailable'}),{status:503,headers:{'content-type':'application/json'}});}});
  setWire((path,options)=>client(path,options));
  await assert.rejects(api.apiFetch('/api/v2/users/me',{retry:2}));
  assert.equal(calls.length,1);assert.equal(wireCalls,1);assert.equal(one.refreshes,0);
}));

test('actual ofetch response hooks cannot receive an obsolete response',()=>fixture(async({one,setWire})=>{
  const gate=deferred(),seen=[];
  const client=createFetch({fetch:()=>gate.promise});setWire((path,options)=>client(path,options));
  const rejected=cancelled(api.apiFetch('/api/v2/users/me',{onResponse:context=>{seen.push(context.response._data);}}));
  one.queue.beginIdentityChange();gate.resolve(new Response(JSON.stringify({private:'old'}),{headers:{'content-type':'application/json'}}));
  await rejected;assert.deepEqual(seen,[]);
}));

test('identity changes while an async hook waits stop subsequent hooks',()=>fixture(async({one,setWire})=>{
  const gate=deferred(),started=deferred(),seen=[];
  const client=createFetch({fetch:async()=>new Response('{}',{headers:{'content-type':'application/json'}})});setWire((path,options)=>client(path,options));
  const rejected=cancelled(api.apiFetch('/api/v2/users/me',{onResponse:[async()=>{started.resolve();await gate.promise;},()=>{seen.push('late hook');}]}));
  await started.promise;one.queue.beginIdentityChange();gate.resolve();await rejected;assert.deepEqual(seen,[]);
}));

test('an async request hook cannot send after its identity becomes obsolete',()=>fixture(async({one,setWire})=>{
  const gate=deferred(),started=deferred();let sent=0;
  const client=createFetch({fetch:async()=>{sent++;return new Response('{}');}});setWire((path,options)=>client(path,options));
  const rejected=cancelled(api.apiFetch('/api/v2/posts',{onRequest:async()=>{started.resolve();await gate.promise;}}));
  await started.promise;one.queue.beginIdentityChange();gate.resolve();await rejected;assert.equal(sent,0);
}));

test('an obsolete network failure never reaches request-error hooks',()=>fixture(async({one,setWire})=>{
  const gate=deferred(),seen=[];
  const client=createFetch({fetch:()=>gate.promise});setWire((path,options)=>client(path,options));
  const rejected=cancelled(api.apiFetch('/api/v2/posts',{onRequestError:()=>{seen.push('old network error');}}));
  one.queue.beginIdentityChange();gate.reject(Error('isolated network'));await rejected;assert.deepEqual(seen,[]);
}));

test('current response and error hook arrays preserve their normal order',()=>fixture(async({setWire})=>{
  const seen=[];let status=200;
  const client=createFetch({fetch:async()=>new Response('{}',{status,headers:{'content-type':'application/json'}})});setWire((path,options)=>client(path,options));
  const options={onRequest:[()=>{seen.push('request-1');},async()=>{seen.push('request-2');}],onResponse:()=>{seen.push('response');},onResponseError:()=>{seen.push('error');}};
  await api.apiFetch('/api/v2/posts',options);status=403;await assert.rejects(api.apiFetch('/api/v2/posts',options));
  assert.deepEqual(seen,['request-1','request-2','response','request-1','request-2','response','error']);
}));
