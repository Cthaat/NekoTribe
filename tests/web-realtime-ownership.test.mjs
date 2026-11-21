import assert from 'node:assert/strict';
import {test} from 'node:test';
import {build} from 'esbuild';
import {fileURLToPath} from 'node:url';
import {computed, reactive, readonly, ref, shallowRef, watch} from 'vue';

const root = fileURLToPath(new URL('../', import.meta.url));
const vectors = JSON.parse(await (await import('node:fs/promises')).readFile(
  new URL('../specifications/scenarios/local-presence.json', import.meta.url), 'utf8'
));
const {clientCases} = JSON.parse(await (await import('node:fs/promises')).readFile(
  new URL('../specifications/scenarios/storage-public-urls.json', import.meta.url), 'utf8'
));
globalThis.__vue = {computed, reactive, readonly, ref, shallowRef, watch};
const bundle = await build({
  stdin: {
    contents: "export * from './app/composables/useRealtimeSocket'; export {usePostFeed} from './app/composables/usePostFeed'; export {authQueueFor} from './app/services/auth-request-queue'; export {mergeDirectMessages,reconcileDirectHistory} from './app/services/chat'; export {isDirectMessageForConversation,v2DeleteDirectMessage,v2ListDirectMessages} from './app/api/v2/chat'; export {resolveApiBaseUrl,resolveRealtimeUrl} from './app/utils/apiBase'; export {normalizeAssetUrl,normalizePublicMediaUrl} from './app/utils/assets';",
    resolveDir: root
  },
  alias: {'@': root + 'app'}, define: {'import.meta.client': 'true'},
  bundle: true, write: false, platform: 'node', format: 'esm',
  plugins: [{name: 'realtime-app-context', setup(builder) {
    const modules = {
      '#app': 'export const useNuxtApp = () => globalThis.__owner;',
      '@/stores/user': 'export const usePreferenceStore = () => globalThis.__owner.store;',
      vue: 'export const {computed,reactive,readonly,ref,shallowRef,watch}=globalThis.__vue;',
      './client': 'export const v2RequestData=(...args)=>globalThis.__directDeleteRequest(...args); export const v2Request=(...args)=>globalThis.__directHistoryRequest(...args); export const toV2PagedResult=({data,meta})=>({items:data,meta});'
    };
    builder.onResolve({filter: /^(#app|@\/stores\/user|vue|\.\/client)$/}, ({path}) => ({path, namespace: 'fixture'}));
    builder.onLoad({filter: /.*/, namespace: 'fixture'}, ({path}) => ({contents: modules[path]}));
  }}]
});
const subject = await import('data:text/javascript;base64,' + Buffer.from(bundle.outputFiles[0].text).toString('base64'));

test('Nuxt Web derives realtime and storage from the API base and allows independent overrides', t => {
  const previous = globalThis.useRuntimeConfig;
  t.after(() => { globalThis.useRuntimeConfig = previous; });
  const config = {apiBase: ' https://api.example.test:3443/gateway/ '};
  globalThis.useRuntimeConfig = () => ({public: config});
  assert.equal(subject.resolveApiBaseUrl(), 'https://api.example.test:3443/gateway');
  assert.equal(subject.resolveRealtimeUrl(), 'wss://api.example.test:3443/gateway/_ws');
  assert.equal(subject.normalizeAssetUrl('/uploads/a.png'), 'https://api.example.test:3443/gateway/storage/a.png');

  config.storageBase = 'https://cdn.example.test/media/';
  assert.equal(subject.normalizeAssetUrl('/storage/a.png?version=1'), 'https://cdn.example.test/media/storage/a.png?version=1');
  assert.equal(subject.normalizeAssetUrl('https://provider.example.test/storage/a.png'), 'https://provider.example.test/storage/a.png');
  assert.equal(subject.normalizeAssetUrl('default-avatar.png'), 'https://cdn.example.test/media/storage/default-avatar.png');
  assert.equal(subject.normalizeAssetUrl('/favicon.ico'), '/favicon.ico');
  config.storageBase = 'https://user@cdn.example.test';
  assert.equal(subject.normalizeAssetUrl('/storage/a.png'), 'https://api.example.test:3443/gateway/storage/a.png');
});

test('Nuxt Web honors an explicit localhost realtime endpoint for local browsers', () => {
  const config = {apiBase: 'https://api.example.test:3443', wsUrl: 'ws://localhost:3000/_ws'};
  assert.equal(subject.resolveRealtimeUrl({config, browserHostname:'localhost'}), 'ws://localhost:3000/_ws');
  assert.equal(subject.resolveRealtimeUrl({config, browserHostname:'lan.example.test'}), 'wss://api.example.test:3443/_ws');
});

test('public media follows shared address vectors without changing signed links', t => {
  const previous = globalThis.useRuntimeConfig;
  t.after(() => { globalThis.useRuntimeConfig = previous; });
  for (const vector of clientCases) {
    globalThis.useRuntimeConfig = () => ({public: {
      apiBase: 'https://api.example:3443/gateway',
      storageBase: vector.useApiBase ? '' : 'https://cdn.example:8443/public/'
    }});
    assert.equal(subject.normalizePublicMediaUrl(vector.input), vector.expected, vector.id);
  }
});

test('post feed ignores an earlier page and clears an invalidated owner', async () => {
  const pending = [];
  const feed = subject.usePostFeed({loadPage: () => new Promise(resolve => pending.push(resolve))});
  const page = id => ({items: [{id}], total: 1, page: 1, pageSize: 15, hasNext: false});

  const earlier = feed.refresh();
  const latest = feed.refresh();
  pending[1](page(2));
  await latest;
  pending[0](page(1));
  await earlier;
  assert.deepEqual(feed.posts.map(item => item.id), [2]);

  const oldOwner = feed.refresh();
  feed.invalidate();
  pending[2](page(3));
  await oldOwner;
  assert.deepEqual(feed.posts, []);
  assert.equal(feed.loading, false);
});

test('direct delivery validates conversation identity and message details before rendering', () => {
  const message = {conversation_id:11,message_id:7,author:{user_id:42},content:'hello',created_at:'2026-11-20T10:00:00Z',is_deleted:false};
  assert.equal(subject.isDirectMessageForConversation(11,message),true);
  for (const [conversation, candidate] of [
    [12,message], ['11',message], [undefined,message],
    [11,{...message,message_id:7.5}], [11,{...message,message_id:Number.MAX_SAFE_INTEGER + 1}],
    [11,{...message,author:null}], [11,{...message,is_deleted:true}]
  ]) {
    assert.equal(subject.isDirectMessageForConversation(conversation,candidate),false);
  }
});

test('direct history keeps messages arriving after the request started', () => {
  const message = (message_id, content, created_at = '2026-01-01T00:00:00Z') => ({message_id, content, created_at});
  const page = [message(4,'stale snapshot'), message(1,'older','2025-12-31T00:00:00Z')];
  const live = [message(5,'new arrival'), message(4,'current event')];
  assert.deepEqual(subject.mergeDirectMessages(page,live).map(item=>[item.message_id,item.content]), [
    [1,'older'],[4,'current event'],[5,'new arrival'],
  ]);
});

test('direct history rejects a page with invalid metadata or messages', async () => {
  const message = {conversation_id:11,message_id:7,author:{user_id:42},content:'hello',created_at:'2026-11-20T10:00:00Z',is_deleted:false};
  const meta = {page:2,page_size:20,total:22,has_next:false};
  const envelope = {code:200,meta,data:[message]};
  let response = envelope;
  globalThis.__directHistoryRequest = (path, options) => {
    assert.equal(path,'/api/v2/chat/direct-conversations/11/messages');
    assert.deepEqual(options,{method:'GET',query:{page:2,page_size:20}});
    return response;
  };
  try {
    const read = () => subject.v2ListDirectMessages(11,{page:2,page_size:20});
    assert.deepEqual(await read(),{items:[message],meta});
    for (const invalid of [
      {...envelope,meta:null}, {...envelope,meta:{...meta,page:1}},
      {...envelope,meta:{...meta,page:'2'}}, {...envelope,data:{items:[]}},
      {...envelope,data:[message,message]}, {...envelope,data:[{...message,conversation_id:12}]},
      {...envelope,data:[{...message,is_deleted:true}]}
    ]) {
      response = invalid;
      await assert.rejects(read,/Invalid direct message history response/);
    }
  } finally { delete globalThis.__directHistoryRequest; }
});

test('older direct history retains the current view and excludes deletions during paging', () => {
  const message = (message_id, content) => ({message_id,content,created_at:'2026-01-01T00:00:00Z'});
  const page = [message(1,'older'), message(2,'deleted'), message(4,'old copy')];
  const retained = [message(4,'visible copy'), message(5,'newest')];
  const live = new Map([[2,null], [6,message(6,'received')]]);
  assert.deepEqual(subject.reconcileDirectHistory(page, retained, live).map(item=>[item.message_id,item.content]),
    [[1,'older'],[4,'visible copy'],[5,'newest'],[6,'received']]);
});

test('direct deletion uses the conversation path and validates the receipt', async () => {
  const calls=[];
  globalThis.__directDeleteRequest=(...args)=>{calls.push(args);return null;};
  try {
    await subject.v2DeleteDirectMessage(11,5);
    assert.deepEqual(calls,[['/api/v2/chat/direct-conversations/11/messages/5',{method:'DELETE'}]]);
    globalThis.__directDeleteRequest=()=>({});
    await assert.rejects(()=>subject.v2DeleteDirectMessage(11,5), /Invalid direct message delete receipt/);
  } finally { delete globalThis.__directDeleteRequest; }
});
const sockets = [];
class FakeSocket {
  static OPEN = 1;
  readyState = 1;
  closed = false;
  sent = [];
  constructor(url) { this.url = url; sockets.push(this); }
  close() { this.closed = true; }
  send(raw) { this.sent.push(JSON.parse(raw)); }
  receive(value) { this.onmessage?.({data: JSON.stringify(value)}); }
}
function fixture() {
  globalThis.window = {location: new URL('http://frontend.test/')};
  globalThis.WebSocket = FakeSocket;
  const app = {
    endpoint: ref('ws://backend.test/_ws'),
    store: reactive({isLoggedIn: true, preferences: {user: {id: 42}}}),
    runWithContext(action) {
      const previous = globalThis.__owner;
      globalThis.__owner = this;
      try { return action(); } finally { globalThis.__owner = previous; }
    }
  };
  app.$config = {public: {get wsUrl() { return app.endpoint.value; }}};
  const client = app.runWithContext(subject.useRealtimeSocket);
  return {app, client, queue: subject.authQueueFor(app)};
}
function status(remote_events, extra = {}, timestamp = 1) {
  return {type: 'system_notification', timestamp, data: {
    code: 'realtime_status', user_id: 42, server_id: 'fixture',
    local_presence: true, remote_events, ...extra
  }};
}

test('strict common realtime frames only change capability for the current user', () => {
  const {client} = fixture();
  try {
    client.connect();
    const socket = sockets.at(-1);
    assert.equal(client.remoteEvents.value, 'unknown');
    for (const vector of vectors.statusCases) {
      const before = client.remoteEvents.value;
      socket.receive(status(vector.remote_events, {local_presence: vector.local_presence}));
      assert.equal(client.remoteEvents.value, vector.valid ? vector.remote_events : before, vector.id);
    }
    for (const frame of [
      status('connected', {user_id: 43}), status('connected', {server_id: ' '}),
      status('connected', {extra: true}), {...status('connected'), extra: 1},
      ...[-1, 0.5, '123', Number.MAX_SAFE_INTEGER + 1].map(clock => status('connected', {}, clock))
    ]) {
      socket.receive(frame);
      assert.equal(client.remoteEvents.value, 'unavailable');
    }
    socket.receive(status('connected'));
    assert.equal(client.remoteEvents.value, 'connected');
    assert.equal(client.recoveryRevision.value, 1);
    socket.receive(status('connected'));
    assert.equal(client.recoveryRevision.value, 1);
  } finally { client.disconnect(); }
});

test('same-account relogin and backend changes invalidate late socket callbacks', async () => {
  const {app, client, queue} = fixture();
  const received = [];
  const unsubscribe = client.subscribe(message => received.push(message));
  try {
    const first = sockets.at(-1);
    const stale = {message: first.onmessage, close: first.onclose, error: first.onerror};
    first.receive(status('connected'));
    let release;
    const transition = queue.runIdentityChange(() => new Promise(resolve => { release = resolve; }));
    assert.equal(first.closed, true);
    assert.equal(client.remoteEvents.value, 'unknown');
    await Promise.resolve();
    release();
    await transition;
    const second = sockets.at(-1);
    assert.notEqual(second, first);
    stale.message({data: JSON.stringify({type: 'notification_created', data: {}})});
    stale.close(); stale.error();
    assert.equal(second.closed, false);
    assert.deepEqual(received, []);
    second.receive(status('connected'));
    assert.equal(client.recoveryRevision.value, 0);
    app.endpoint.value = 'ws://other.test/_ws';
    assert.equal(second.closed, true);
    assert.equal(sockets.at(-1).url, app.endpoint.value);
    assert.equal(client.remoteEvents.value, 'unknown');
  } finally { unsubscribe(); client.disconnect(); }
});

test('app owners have separate listeners, sockets, and subscription state', () => {
  const first = fixture(), second = fixture(), received = [];
  const unsubscribe = second.client.subscribe(message => received.push(message));
  try {
    const secondSocket = sockets.at(-1);
    first.client.connect();
    const firstSocket = sockets.at(-1);
    assert.notEqual(firstSocket, secondSocket);
    firstSocket.receive(status('connected'));
    firstSocket.receive({type: 'notification_created', data: {}});
    assert.equal(second.client.remoteEvents.value, 'unknown');
    assert.deepEqual(received, []);
  } finally { unsubscribe(); first.client.disconnect(); second.client.disconnect(); }
});

test('disconnect clears capability and a new socket refreshes only after a valid recovered state', t => {
  t.mock.timers.enable({apis: ['setTimeout']});
  const {client} = fixture();
  try {
    client.connect();
    const first = sockets.at(-1);
    first.receive(status('connected'));
    first.onclose();
    assert.equal(client.remoteEvents.value, 'unknown');
    t.mock.timers.tick(3000);
    const second = sockets.at(-1);
    assert.notEqual(first, second);
    second.receive(status('connected', {user_id: 43}));
    assert.equal(client.recoveryRevision.value, 0);
    second.receive(status('connected'));
    assert.equal(client.recoveryRevision.value, 1);
    second.onclose();
    client.disconnect();
    const total = sockets.length;
    t.mock.timers.tick(3000);
    assert.equal(sockets.length, total);
  } finally { client.disconnect(); }
});

test('channel commands wait for a valid server status and never replay across owners', async () => {
  const {app, client, queue} = fixture();
  const join = {type: 'chat_join_channel', data: {channelId: 12}};
  try {
    client.connect();
    const first = sockets.at(-1);
    first.onopen();
    assert.equal(client.send(join), false);
    first.receive(status('connecting', {user_id: 43}));
    assert.equal(client.send(join), false);
    first.receive(status('unavailable'));
    assert.equal(client.serverReady.value, true);
    assert.equal(client.send(join), true);
    assert.deepEqual(first.sent.filter(frame => frame.type !== 'ping'), [join]);
    const change = queue.runIdentityChange(async () => {
      assert.equal(client.serverReady.value, false);
      assert.equal(client.send(join), false);
    });
    await change;
    const second = sockets.at(-1);
    assert.notEqual(second, first);
    second.receive(status('connected'));
    assert.deepEqual(second.sent, []);
    app.endpoint.value = 'ws://alternate.test/_ws';
    assert.equal(client.send(join), false);
  } finally { client.disconnect(); }
});

test('failed channel write retires the socket and lets the current channel rejoin', t => {
  t.mock.timers.enable({apis: ['setTimeout']});
  const {client} = fixture();
  const join = {type: 'chat_join_channel', data: {channelId: 12}};
  try {
    client.connect();
    const first = sockets.at(-1);
    first.receive(status('connected'));
    first.send = () => { throw new Error('fixture transport failure'); };
    assert.equal(client.send(join), false);
    assert.equal(first.closed, true);
    assert.equal(client.serverReady.value, false);
    t.mock.timers.tick(3000);
    const second = sockets.at(-1);
    assert.notEqual(first, second);
    assert.equal(client.send(join), false);
    second.receive(status('connected'));
    assert.equal(client.send(join), true);
    assert.equal(client.recoveryRevision.value, 1);
    assert.deepEqual(second.sent, [join]);
  } finally { client.disconnect(); }
});
