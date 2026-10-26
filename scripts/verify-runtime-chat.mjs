// Actual HTTP + Redis + WebSocket delivery between two disposable fixture accounts.
import assert from 'node:assert/strict';
const base = process.env.NEKO_RUNTIME_TEST_BASE;
const wsBase = process.env.NEKO_RUNTIME_TEST_WS_BASE;
const password = process.env.NEKO_RUNTIME_TEST_PASSWORD;
const peerPassword = process.env.NEKO_RUNTIME_TEST_PEER_PASSWORD;
if (process.env.NEKO_RUNTIME_TEST_DISPOSABLE !== 'true' || !base || !wsBase || !password || !peerPassword) {
  throw new Error('Explicit disposable HTTP/WS origins and both fixture passwords are required.');
}
async function request(path, token, method = 'GET', body, expectedStatus = 200) {
  const response = await fetch(new URL(path, base), {
    method, signal: AbortSignal.timeout(20000), headers: { Accept: 'application/json',
      ...(body ? { 'Content-Type': 'application/json' } : {}), ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {})
  });
  const value = await response.json();
  assert.equal(response.status, expectedStatus, `${method} ${path}: ${value.message ?? value.statusMessage}`);
  if (expectedStatus === 200) assert.equal(value.code, 200);
  return value.data;
}
const sender = await request('/api/v2/auth/tokens', null, 'POST', { account: 'runtime_t16', password });
const receiver = await request('/api/v2/auth/tokens', null, 'POST', { account: 'runtime_t16_peer', password: peerPassword });
const settings = await request('/api/v2/users/me/settings', receiver.tokens.access_token);
const url = new URL('/_ws', wsBase);
assert(['ws:', 'wss:'].includes(url.protocol) && !url.username && !url.password);
url.searchParams.set('token', receiver.tokens.access_token);
const socket = new WebSocket(url);
const events = [];
const listeners = new Set();
socket.addEventListener('message', event => {
  try { events.push(JSON.parse(event.data)); for (const listener of listeners) listener(); }
  catch { /* Malformed frames cannot satisfy any expected event. */ }
});
function waitFor(predicate) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { listeners.delete(check); reject(new Error('Expected realtime event timed out')); }, 15000);
    function check() {
      const found = events.find(predicate);
      if (found) { clearTimeout(timer); listeners.delete(check); resolve(found); }
    }
    listeners.add(check); check();
  });
}
try {
  await waitFor(event => event.type === 'system_notification' && event.data?.message === 'WebSocket connected');
  if (!settings.allow_dm_from_strangers) {
    await request('/api/v2/chat/direct-conversations', sender.tokens.access_token, 'POST', { target_user_id: receiver.user.user_id }, 403);
  }
  await request('/api/v2/users/me/settings', receiver.tokens.access_token, 'PATCH', { allow_dm_from_strangers: true });
  const conversation = await request('/api/v2/chat/direct-conversations', sender.tokens.access_token, 'POST', { target_user_id: receiver.user.user_id });
  const content = `T16 realtime fixture ${Date.now()}`;
  const message = await request(`/api/v2/chat/direct-conversations/${conversation.conversation_id}/messages`, sender.tokens.access_token, 'POST', { content });
  const delivered = await waitFor(event => event.type === 'direct_message' && event.data?.direct_message?.message_id === message.message_id);
  assert.equal(delivered.data.direct_message.content, content);
  const notification = await waitFor(event => event.type === 'notification_created' && event.data?.notification?.resource_id === message.message_id);
  assert.equal(notification.data.notification.resource_type, 'direct_message');
  const inbox = await request(`/api/v2/chat/direct-conversations/${conversation.conversation_id}/messages`, receiver.tokens.access_token);
  assert(inbox.some(item => item.message_id === message.message_id && item.content === content));
  console.log(JSON.stringify({ base: new URL(base).origin, webSocketBase: url.origin, conversationId: conversation.conversation_id,
    messageId: message.message_id, observations: ['receiver authenticated WebSocket', 'stranger privacy enforced before fixture opt-in', 'sender HTTP message persisted',
      'receiver got matching realtime direct_message', 'receiver got matching notification_created', 'receiver HTTP inbox contains same message'] }));
} finally {
  socket.close();
  await request('/api/v2/users/me/settings', receiver.tokens.access_token, 'PATCH', { allow_dm_from_strangers: settings.allow_dm_from_strangers });
  for (const session of [sender, receiver]) await request('/api/v2/auth/tokens/current', session.tokens.access_token, 'DELETE', { refresh_token: session.tokens.refresh_token });
}
