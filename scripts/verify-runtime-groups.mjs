// Writes only fixture groups/messages; explicitly authorize a disposable stack.
import assert from 'node:assert/strict';

const base = new URL(process.env.NEKO_RUNTIME_TEST_BASE ?? 'http://invalid');
const wsBase = new URL(process.env.NEKO_RUNTIME_TEST_WS_BASE ?? 'ws://invalid');
const password = process.env.NEKO_RUNTIME_TEST_PASSWORD;
const peerPassword = process.env.NEKO_RUNTIME_TEST_PEER_PASSWORD;
assert.equal(process.env.NEKO_RUNTIME_TEST_DISPOSABLE, 'true');
assert(['http:', 'https:'].includes(base.protocol) && base.pathname === '/' && !base.username && !base.password);
assert(['ws:', 'wss:'].includes(wsBase.protocol) && !wsBase.username && !wsBase.password);
assert(password && peerPassword, 'Both disposable fixture passwords are required');

async function request(path, token, method = 'GET', body, status = 200) {
  const response = await fetch(new URL(path, base), {
    method, signal: AbortSignal.timeout(20000),
    headers: { Accept: 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body ? { 'Content-Type': 'application/json' } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {})
  });
  const value = await response.json();
  assert.equal(response.status, status, `${method} ${path}: ${value.message ?? value.statusMessage}`);
  if (status === 200) assert.equal(value.code, 200);
  return value.data;
}

const sessions = [];
let socket;
try {
  for (const [account, fixturePassword] of [
    [process.env.NEKO_RUNTIME_TEST_ACCOUNT ?? 'runtime_t16', password],
    [process.env.NEKO_RUNTIME_TEST_PEER_ACCOUNT ?? 'runtime_t16_peer', peerPassword]
  ]) sessions.push(await request('/api/v2/auth/tokens', null, 'POST', { account, password: fixturePassword }));
  const [owner, peer] = sessions.map(session => session.tokens.access_token);
  const group = await request('/api/v2/groups', owner, 'POST', {
    name: `T16 fixture group ${Date.now()}`, privacy: 'public', join_approval: false,
    description: 'Disposable runtime verification', category: 'tech', tags: ['runtime-test']
  });
  const channel = await request(`/api/v2/chat/groups/${group.group_id}/channels`, owner, 'POST', { name: 'runtime-test', type: 'text' });
  const messagesPath = `/api/v2/chat/channels/${channel.channel_id}/messages`;
  await request(messagesPath, peer, 'GET', undefined, 403);
  const url = new URL('/_ws', wsBase);
  url.searchParams.set('token', peer);
  socket = new WebSocket(url);
  const events = [];
  const listeners = new Set();
  socket.addEventListener('message', event => {
    let parsed;
    try { parsed = JSON.parse(event.data); } catch { return; }
    events.push(parsed);
    for (const listener of listeners) listener();
  });
  function waitFor(predicate) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { listeners.delete(check); reject(new Error('Expected group realtime event timed out')); }, 15000);
      function check() {
        const found = events.find(predicate);
        if (found) { clearTimeout(timer); listeners.delete(check); resolve(found); }
      }
      listeners.add(check); check();
    });
  }
  const join = () => socket.send(JSON.stringify({ type: 'chat_join_channel', data: { channel_id: channel.channel_id } }));
  await waitFor(event => event.type === 'system_notification' && event.data?.message === 'WebSocket connected');
  join();
  await waitFor(event => event.type === 'error' && event.data?.channel_id === channel.channel_id);
  await request(`/api/v2/groups/${group.group_id}/members/current`, peer, 'POST', {});
  const members = await request(`/api/v2/chat/groups/${group.group_id}/members`, owner);
  assert(members.some(member => member.user_id === sessions[1].user.user_id));
  await request(`/api/v2/chat/groups/${group.group_id}/channels`, peer, 'POST', { name: 'forbidden' }, 403);
  join();
  await waitFor(event => event.type === 'system_notification' && event.data?.message === 'chat channel joined' && event.data.channel_id === channel.channel_id);
  const content = `T16 group message ${Date.now()}`;
  const message = await request(messagesPath, owner, 'POST', { content });
  const delivered = await waitFor(event => event.type === 'chat_message' && event.data?.message?.message_id === message.message_id);
  assert.equal(delivered.data.message.content, content);
  assert((await request(messagesPath, peer)).some(item => item.message_id === message.message_id && item.content === content));
  await request(`/api/v2/chat/messages/${message.message_id}`, peer, 'PATCH', { content: 'forbidden edit' }, 403);
  const editedContent = `${content} edited`;
  await request(`/api/v2/chat/messages/${message.message_id}`, owner, 'PATCH', { content: editedContent });
  const edited = await waitFor(event => event.type === 'chat_message_updated' && event.data?.message?.message_id === message.message_id);
  assert.equal(edited.data.message.content, editedContent);
  console.log(JSON.stringify({ base: base.origin, webSocketBase: wsBase.origin, groupId: group.group_id,
    channelId: channel.channel_id, messageId: message.message_id, observations: [
      'group and text channel created', 'nonmember HTTP and WebSocket access denied', 'member joined and listed',
      'ordinary member channel creation denied', 'authenticated channel subscribed', 'message persisted and delivered by WebSocket',
      'peer HTTP history matches', 'editing another author denied', 'author edit delivered by WebSocket'
    ] }));
} finally {
  socket?.close();
  for (const session of sessions) await request('/api/v2/auth/tokens/current', session.tokens.access_token, 'DELETE', { refresh_token: session.tokens.refresh_token });
}
