import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const root = fileURLToPath(new URL('../', import.meta.url));
const compiled = await build({
  entryPoints: ['app/api/v2/chat.ts'],
  absWorkingDir: root,
  alias: { '@': `${root}app` },
  bundle: true,
  write: false,
  platform: 'node',
  format: 'esm',
  plugins: [{
    name: 'chat-write-transport',
    setup(builder) {
      builder.onResolve({ filter: /^@\/utils\/chat-channel-mute$/ }, () => ({
        path: fileURLToPath(new URL('../app/utils/chat-channel-mute.ts', import.meta.url))
      }));
      builder.onResolve({ filter: /^\.\/client$/ }, () => ({ path: 'client', namespace: 'fixture' }));
      builder.onLoad({ filter: /.*/, namespace: 'fixture' }, () => ({ contents: `
        export const toV2PagedResult = response => response;
        export const v2Request = (path, options) => globalThis.channelTransport(path, options);
        export const v2RequestData = async (path, options) => (await v2Request(path, options)).data;
      ` }));
    }
  }]
});
const api = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`);

test('channel reads distinguish an empty result and a mismatched list', async () => {
  const channel = { channel_id: 7, group_id: 42 };
  let data = [channel];
  globalThis.channelTransport = (path, options) => {
    assert.equal(path, '/api/v2/chat/groups/42/channels');
    assert.equal(options.method, 'GET');
    return { data };
  };
  assert.deepEqual(await api.v2ListChatChannels(42), [channel]);
  data = [];
  assert.deepEqual(await api.v2ListChatChannels(42), []);
  for (const invalid of [null, {items: []}, [channel, channel], [{...channel, group_id: 9}], [{...channel, channel_id: '7'}]]) {
    data = invalid;
    await assert.rejects(api.v2ListChatChannels(42), /Invalid chat channel list/);
  }
});

test('direct chat writes confirm the recipient, conversation, and sent text', async () => {
  const conversation = { conversation_id: 11, participant: { user_id: 42 } };
  const message = { message_id: 9, conversation_id: 11, is_deleted: false, content: 'hello',
    author: { user_id: 21 }, created_at: '2026-11-21T03:00:00Z' };
  let data = conversation;
  globalThis.channelTransport = () => ({ data });
  const open = () => api.v2CreateDirectConversation({ target_user_id: 42 });
  const send = () => api.v2CreateDirectMessage(11, { content: ' hello ' });
  assert.deepEqual(await open(), conversation);
  data = { ...conversation, participant: { user_id: 43 } };
  await assert.rejects(open, /Invalid direct conversation response/);
  data = message;
  assert.deepEqual(await send(), message);
  for (const invalid of [{ ...message, conversation_id: 12 }, { ...message, content: 'other' }, { ...message, is_deleted: true }]) {
    data = invalid;
    await assert.rejects(send, /Invalid direct message response/);
  }
});

test('private attachment receipts confirm order, quote identity and own reaction state', async () => {
  const asset = id => ({ media_id: id, file_name: `${id}.png`, public_url: `/api/v2/media/${id}/content`, thumbnail_url: null });
  const message = { message_id: 9, conversation_id: 11, is_deleted: false, content: '',
    author: { user_id: 21 }, created_at: '2026-11-21T03:00:00Z', media: [asset(36), asset(32)],
    reply_to: { message_id: 7, content: 'reply', author_name: 'member' } };
  let data = message;
  const requests = [];
  globalThis.channelTransport = (path, options) => { requests.push({ path, ...options }); return { data }; };
  const send = () => api.v2CreateDirectMessage(11, { media_ids: [36, 32], reply_to_message_id: 7 });
  assert.deepEqual(await send(), message);
  for (const invalid of [{ ...message, media: [...message.media].reverse() },
    { ...message, reply_to: { ...message.reply_to, message_id: 8 } },
    { ...message, media: [{ ...asset(36), public_url: '/storage/private/chat/36.png' }, asset(32)] }]) {
    data = invalid;
    await assert.rejects(send, /Invalid direct message response/);
  }
  data = { ...message, reactions: [{ emoji: '👍', count: 1, reacted_by_me: true }] };
  assert.deepEqual(await api.v2SetDirectMessageReaction(11, 9, '👍', true), data);
  assert.deepEqual(requests.at(-1), { path: '/api/v2/chat/direct-conversations/11/messages/9/reactions', method: 'POST', body: { emoji: '👍' } });
  await assert.rejects(api.v2SetDirectMessageReaction(11, 9, '👍', false), /Invalid direct reaction receipt/);
  data = { ...message, reactions: [{ emoji: '👍', count: 1, reacted_by_me: false }] };
  assert.deepEqual(await api.v2SetDirectMessageReaction(11, 9, '👍', false), data);
  assert.equal(requests.at(-1).method, 'DELETE');
  assert.deepEqual(await api.v2ReadDirectMessage(11, 9), data);
  assert.equal(requests.at(-1).path, '/api/v2/chat/direct-conversations/11/messages/9');
  data = { ...message, message_id: 10 };
  await assert.rejects(api.v2ReadDirectMessage(11, 9), /Invalid direct message receipt/);
});

test('direct history opts out of reads and explicit cursors confirm the caller and participant positions', async () => {
  const requests = [];
  const status = { conversation_id: 11, last_read_message_id: 70, participant_last_read_message_id: 52, unread_count: 3 };
  let data = status;
  globalThis.channelTransport = (path, options) => {
    requests.push({ path, ...options });
    return { code:200, data: path.endsWith('/messages') ? [] : data, meta: { page:1, page_size:20, total:0, has_next:false } };
  };
  const filters = {q:'hello',sender_id:21,start_at:'2026-09-21T00:00:00.000Z',end_at:'2026-09-22T00:00:00.000Z'};
  await api.v2ListDirectMessages(11, { page:1, page_size:20, mark_read:false, ...filters });
  await api.v2ListChatMessages(8, { page:1, page_size:20, ...filters });
  assert.deepEqual(requests[0].query,{page:1,page_size:20,mark_read:false,...filters});
  assert.deepEqual(requests[1].query,{page:1,page_size:20,...filters});
  assert.deepEqual(await api.v2GetDirectReadStatus(11), status);
  assert.deepEqual(await api.v2SetDirectReadStatus(11, 67), status);
  assert.deepEqual(requests.at(-1), { path:'/api/v2/chat/direct-conversations/11/read-status', method:'PUT', body:{last_read_message_id:67} });
  await assert.rejects(api.v2SetDirectReadStatus(11, 71), /Invalid direct read status/);
  data = { ...status, conversation_id: 12 };
  await assert.rejects(api.v2GetDirectReadStatus(11), /Invalid direct read status/);
});
test('channel writes confirm response identity and deletion before updating UI', async () => {
  const channel = { channel_id: 7, group_id: 42 };
  const deleted = { code: 200, message: 'chat channel deleted', data: null, meta: null };
  let receipt;
  globalThis.channelTransport = () => receipt;
  const create = () => api.v2CreateChatChannel(42, { name: 'team' });
  const update = () => api.v2UpdateChatChannel(7, { category: '', is_private: true });
  const remove = () => api.v2DeleteChatChannel(7);

  receipt = { data: channel };
  assert.deepEqual(await create(), channel);
  assert.deepEqual(await update(), channel);
  receipt = { data: { ...channel, group_id: 8 } };
  await assert.rejects(create, /Invalid chat channel create response/);
  receipt = { data: { ...channel, channel_id: '7' } };
  await assert.rejects(update, /Invalid chat channel update response/);
  receipt = deleted;
  await remove();
  for (const invalid of [{ ...deleted, message: 'success' }, { ...deleted, data: {} }, { ...deleted, meta: undefined }]) {
    receipt = invalid;
    await assert.rejects(remove, /Invalid chat channel delete response/);
  }
});

test('channel message writes confirm identity, edited content, pin state and deletion', async () => {
  const message = { message_id: 5, channel_id: 7, group_id: 42, is_deleted: false, content: 'new', is_pinned: true };
  let receipt = { data: message };
  globalThis.channelTransport = () => receipt;
  const edit = () => api.v2UpdateChatMessage(5, { content: ' new ' });
  const pin = () => api.v2SetChatMessagePinStatus(5, { is_pinned: true });
  assert.deepEqual(await edit(), message);
  assert.deepEqual(await pin(), message);
  receipt = { data: { ...message, is_pinned: false, content: 'old' } };
  await assert.rejects(edit, /Invalid chat message edit response/);
  await assert.rejects(pin, /Invalid chat message pin response/);
  receipt = { data: { ...message, message_id: 6 } };
  await assert.rejects(edit, /Invalid chat message edit response/);
  receipt = { code: 200, message: 'chat message deleted', data: null, meta: null };
  await api.v2DeleteChatMessage(5);
  receipt = { ...receipt, meta: undefined };
  await assert.rejects(api.v2DeleteChatMessage(5), /Invalid chat message delete response/);
});

test('reaction writes require the selected state and valid counts', async () => {
  const reaction = { emoji: '👍', count: 2, reacted_by_me: true };
  const message = { message_id: 5, channel_id: 7, group_id: 42, is_deleted: false };
  let reactions = [reaction];
  globalThis.channelTransport = () => ({ data: { ...message, reactions } });
  const add = () => api.v2CreateChatReaction(5, { emoji: '👍' });
  const remove = () => api.v2DeleteChatReaction(5, { emoji: '👍' });
  assert.deepEqual((await add()).reactions, [reaction]);
  await assert.rejects(remove, /Invalid chat reaction response/);
  for (const invalid of [[{ ...reaction, count: 0 }], [reaction, reaction], [{ ...reaction, reacted_by_me: 1 }]]) {
    reactions = invalid;
    await assert.rejects(add, /Invalid chat reaction response/);
  }
  reactions = [];
  assert.deepEqual((await remove()).reactions, []);
});
