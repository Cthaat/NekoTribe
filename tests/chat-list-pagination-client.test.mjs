import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { readFileSync } from 'node:fs';
import { build, transform } from 'esbuild';

const root = fileURLToPath(new URL('../', import.meta.url));
const code = await build({
  stdin: { contents: 'export {v2ListChatGroups,v2ListChatMessages,v2ListDirectConversations} from "@/api/v2/chat";', loader: 'ts', resolveDir: root },
  bundle: true, write: false, platform: 'node', format: 'esm', alias: { '@': root + 'app' },
  plugins: [{ name: 'fixture-api', setup(plugin) {
    plugin.onResolve({ filter: /^@\/composables\/useApi$/ }, args => ({ path: args.path, namespace: 'fixture' }));
    plugin.onLoad({ filter: /.*/, namespace: 'fixture' }, () => ({ contents: 'export const apiFetch=(...args)=>globalThis.__chatGroupFixture(...args);' }));
  } }]
});
const { v2ListChatGroups, v2ListChatMessages, v2ListDirectConversations } = await import(`data:text/javascript;base64,${Buffer.from(code.outputFiles[0].text).toString('base64')}`);
const summary = {conversation_id:77,participant:{user_id:42},unread_count:1};

test('chat groups forward the requested page and preserve the continuation metadata', async () => {
  globalThis.__chatGroupFixture = async (path, options) => {
    assert.equal(path, '/api/v2/chat/groups');
    assert.equal(options.method, 'GET');
    assert.deepEqual(options.query, { page: 2, page_size: 20 });
    return { data: [{ group_id: 42 }], meta: {page: 2, page_size: 20, total: 42, has_next: true} };
  };
  const result = await v2ListChatGroups({ page: 2, page_size: 20 });
  assert.equal(result.items[0].group_id, 42);
  assert.equal(result.meta.page, 2);
  assert.equal(result.meta.has_next, true);
});

test('channel history checks pagination and message identity before returning a page', async () => {
  const meta = {page:2,page_size:50,total:51,has_next:false};
  const message = {channel_id:7,group_id:42,message_id:5,is_deleted:false};
  const valid = {code:200,data:[message],meta};
  let response = valid;
  globalThis.__chatGroupFixture = async (path, options) => {
    assert.equal(path,'/api/v2/chat/channels/7/messages');
    assert.deepEqual(options.query,{page:2,page_size:50,q:'cat'});
    return response;
  };
  const read = () => v2ListChatMessages(7,{page:2,page_size:50,q:'cat'});
  assert.deepEqual((await read()).items,[message]);
  for (const invalid of [
    {...valid,meta:{...meta,page:1}},
    {...valid,data:[message,message]},
    {...valid,data:[{...message,channel_id:8}]},
    {...valid,data:[{...message,is_deleted:true}]}
  ]) {
    response = invalid;
    await assert.rejects(read,/Invalid channel message history response/);
  }
});

test('retrying older channel history preserves the current messages and page', async () => {
  const page = readFileSync(new URL('../app/pages/chat.vue', import.meta.url), 'utf8');
  const start = page.indexOf('async function loadMessages(');
  const end = page.indexOf('async function loadDirectConversations(', start);
  assert.ok(start >= 0 && end > start);
  const { code } = await transform(`
    export function fixture(load) {
      const activeChannel = {value:{id:7}};
      const channelSearch = {value:{q:'cat',sender_id:3}};
      const isLoadingMessages = {value:false};
      const failedMessageLoad = {value:null};
      const messages = {value:[{id:5}]};
      const messagePage = {value:1};
      const hasMoreMessages = {value:true};
      const membersById = {value:{}};
      let messageRequest = 0, liveChannelChanges = null, retry;
      const app = {runWithContext: fn => retry = fn()};
      const captureChatOwner = () => () => true;
      const v2ListChatMessages = load;
      const mapV2ChatMessage = item => item;
      const scheduleChannelRead = () => {};
      ${page.slice(start,end)}
      return {messages,messagePage,failedMessageLoad,loadMessages,retryChannelHistory,result:()=>retry};
    }
  `, {loader:'ts',format:'esm'});
  const { fixture } = await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
  let attempts = 0;
  const view = fixture(async (channelId, query) => {
    assert.equal(channelId,7);
    assert.deepEqual(query,{page:2,page_size:50,q:'cat',sender_id:3});
    if (++attempts === 1) throw Error('temporary failure');
    return {items:[{id:4},{id:5}],meta:{has_next:false}};
  });
  await view.loadMessages(7,false);
  assert.equal(view.failedMessageLoad.value,false);
  assert.equal(view.messagePage.value,1);
  assert.deepEqual(view.messages.value,[{id:5}]);
  view.retryChannelHistory();
  await view.result();
  assert.equal(view.messagePage.value,2);
  assert.equal(view.failedMessageLoad.value,null);
  assert.deepEqual(view.messages.value,[{id:4},{id:5}]);
});

test('direct conversations forward the requested page and retain the server receipt', async () => {
  globalThis.__chatGroupFixture = async (path, options) => {
    assert.equal(path, '/api/v2/chat/direct-conversations');
    assert.equal(options.method, 'GET');
    assert.deepEqual(options.query, { page: 2, page_size: 20 });
    return { code:200, data: [summary], meta: {page: 2, page_size: 20, total: 22, has_next: false} };
  };
  const result = await v2ListDirectConversations({ page: 2, page_size: 20 });
  assert.equal(result.items[0].conversation_id, 77);
  assert.equal(result.meta.page, 2);
  assert.equal(result.meta.has_next, false);
});

test('an existing direct conversation is read by its exact ID', async () => {
  const meta = {page:1,page_size:1,total:1,has_next:false};
  let response = {code:200,data:[summary],meta};
  globalThis.__chatGroupFixture = async (path, options) => {
    assert.equal(path, '/api/v2/chat/direct-conversations');
    assert.equal(options.method, 'GET');
    assert.deepEqual(options.query, { conversation_id: 77, page: 1, page_size: 1 });
    return response;
  };
  const read = () => v2ListDirectConversations({ conversation_id:77,page:1,page_size:1 });
  const result = await read();
  assert.equal(result.items[0].conversation_id, 77);
  response = {code:200,data:[],meta:{...meta,total:0}};
  assert.deepEqual((await read()).items,[]);
  for (const item of [
    {...summary,conversation_id:78},
    {...summary,participant:null},
    {...summary,unread_count:-1}
  ]) {
    response = {code:200,data:[item],meta};
    await assert.rejects(read,/Invalid direct conversation list response/);
  }
});

test('chat keeps a failed conversation link for retry and discards cancelled lookups', async () => {
  const page = readFileSync(new URL('../app/pages/chat.vue', import.meta.url), 'utf8');
  const start = page.indexOf('function cancelDirectLinkLookup()');
  const end = page.indexOf('async function refreshChannels(', start);
  assert.ok(start >= 0 && end > start);
  const { code } = await transform(`
    export function fixture(lookup) {
      const route = {query: {conversation:'77'}};
      const directLinkStatus = {value: null};
      let directSelectionRevision = 0, directLinkRequest = 0;
      const opened = [];
      const captureChatOwner = () => () => true;
      const clearDirectMessageQuery = () => {delete route.query.conversation};
      const directMessageQueryUserId = () => null;
      const notificationTargetId = Number;
      const showMobileNavigation = () => {};
      const v2ListDirectConversations = lookup;
      const openDirectConversation = async value => {
        opened.push(value.conversation_id);
        directLinkStatus.value = null;
        directSelectionRevision++;
      };
      ${page.slice(start,end)}
      return {route, directLinkStatus, opened, openDirectMessageFromQuery, cancelDirectLinkLookup};
    }
  `,{loader:'ts',format:'esm'});
  const { fixture } = await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
  let lookup = () => Promise.reject(Error('temporary failure'));
  const view = fixture(query => {
    assert.deepEqual(query,{conversation_id:77,page:1,page_size:1});
    return lookup();
  });
  await view.openDirectMessageFromQuery();
  assert.equal(view.directLinkStatus.value,'failed');
  assert.equal(view.route.query.conversation,'77');
  lookup = async () => ({items:[summary]});
  await view.openDirectMessageFromQuery();
  assert.deepEqual(view.opened,[77]);
  assert.equal(view.route.query.conversation,undefined);

  let complete;
  lookup = () => new Promise(resolve => { complete = resolve; });
  view.route.query.conversation = '77';
  const pending = view.openDirectMessageFromQuery();
  assert.equal(view.directLinkStatus.value,'loading');
  view.cancelDirectLinkLookup();
  complete({items:[summary]});
  await pending;
  assert.deepEqual(view.opened,[77]);
  assert.equal(view.directLinkStatus.value,null);
});
