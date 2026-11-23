import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import test from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { WebSocketServer } from 'ws';
import { runWorkloads } from './workloads.mjs';

const userId = 42;
const channel = 7;
const workloadNames = ['feed', 'profile', 'createPost', 'likePost', 'refresh', 'websocketBroadcast', 'aiWriting'];

async function isolatedBackend(t, { fail = false } = {}) {
  const sessionState = new Map();
  const postState = new Map();
  const chatState = new Map();
  const aiState = new Map();
  const seen = { feedRunning: 0, feedPeak: 0, refresh: [], liked: [], created: [], generated: [], chat: [] };
  const handlerErrors = [];
  let sequence = 100;
  let listener;
  const reply = (res, status, data) => {
    res.writeHead(status, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ code: status, data, meta: null }));
  };
  function issueSession(sessionId, rotation) {
    const tokens = {
      session_id: sessionId, access_token: `test-access-${sessionId}-${rotation}`,
      refresh_token: `test-refresh-${sessionId}-${rotation}`,
    };
    sessionState.set(sessionId, { tokens, rotation });
    return tokens;
  }
  const server = createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://localhost');
      const path = url.pathname;
      const method = req.method;
      let raw = '';
      for await (const part of req) raw += part;
      const body = raw ? JSON.parse(raw) : undefined;
      if (method === 'POST' && path === '/api/v2/auth/tokens') {
        assert.deepEqual(body, { account: 'isolated-fixture', password: 'fixture-password', remember_me: true });
        return reply(res, 200, { user: { user_id: userId }, tokens: issueSession(`test-session-${++sequence}`, 0) });
      }
      if (method === 'PATCH' && path === '/api/v2/auth/tokens/current') {
        const session = [...sessionState.values()].find(item => item.tokens.refresh_token === body?.refresh_token);
        assert.ok(session, 'each worker must rotate its own current token');
        const sessionId = session.tokens.session_id;
        seen.refresh.push(sessionId);
        return reply(res, 200, issueSession(sessionId, session.rotation + 1));
      }
      const authenticated = [...sessionState.values()].some(item => req.headers.authorization === `Bearer ${item.tokens.access_token}`);
      assert.ok(authenticated, 'benchmark request was not authenticated by a current session');

      if (method === 'GET' && path === '/api/v2/posts') {
        assert.equal(url.search, '?timeline=home&page_size=20');
        seen.feedRunning++;
        seen.feedPeak = Math.max(seen.feedPeak, seen.feedRunning);
        await delay(20);
        seen.feedRunning--;
        return reply(res, 200, []);
      }
      if (method === 'GET' && path === `/api/v2/users/${userId}`) return reply(res, 200, { user_id: userId });
      if (method === 'POST' && path === '/api/v2/posts') {
        assert.equal(body?.visibility, 'public');
        const post = { post_id: ++sequence, content: body.content, likes: false };
        seen.created.push(post.post_id);
        postState.set(post.post_id, post);
        return reply(res, 200, post);
      }
      const like = path.match(/^\/api\/v2\/posts\/(\d+)\/likes$/);
      if (like) {
        const post = postState.get(Number(like[1]));
        assert.ok(post);
        if (method === 'POST') {
          assert.equal(post.likes, false, 'a benchmark like reused an already-liked post');
          post.likes = true;
          seen.liked.push(post.post_id);
          if (fail && post.content.endsWith(' 2')) return reply(res, 503, null);
        } else {
          assert.equal(method, 'DELETE');
          post.likes = false;
        }
        return reply(res, 200, { post_id: post.post_id, is_liked: post.likes, likes_count: Number(post.likes) });
      }
      const postDelete = path.match(/^\/api\/v2\/posts\/(\d+)$/);
      if (method === 'DELETE' && postDelete) {
        const post = postState.get(Number(postDelete[1]));
        assert.ok(post && !post.likes, 'a benchmark like was left attached to a deleted fixture');
        if (fail && post.content.endsWith('create 1')) return reply(res, 503, null);
        postState.delete(post.post_id);
        return reply(res, 200, null);
      }
      const revoke = path.match(/^\/api\/v2\/auth\/sessions\/([a-z0-9-]+)$/);
      if (method === 'DELETE' && revoke) {
        assert.ok(sessionState.delete(revoke[1]), 'revocation must use an ID captured in this run');
        return reply(res, 200, null);
      }
      if (method === 'POST' && path === `/api/v2/chat/channels/${channel}/messages`) {
        assert.ok(listener, 'measured send started before WebSocket subscription');
        const message = { message_id: ++sequence, content: body.content, channel_id: channel };
        chatState.set(message.message_id, message);
        seen.chat.push(message.message_id);
        const broadcast = (mention, channelId = channel) => listener.send(JSON.stringify({ type: 'chat_message',
          data: { channel_id: channelId, message: mention } }));
        // These distractors differ from the REST receipt by channel or message ID.
        broadcast(message, channel + 1);
        broadcast({ ...message, message_id: message.message_id + 1000 });
        if (!fail || !message.content.endsWith(' 2')) broadcast(message);
        await delay(120);
        return reply(res, 200, message);
      }
      const chatDelete = path.match(/^\/api\/v2\/chat\/messages\/(\d+)$/);
      if (method === 'DELETE' && chatDelete) {
        assert.ok(chatState.delete(Number(chatDelete[1])));
        return reply(res, 200, null);
      }
      if (method === 'POST' && path === '/api/v2/ai/conversations') {
        assert.equal(body?.purpose, 'writing');
        const conversation = { conversation_id: randomUUID(), purpose: 'writing', title: body.title };
        aiState.set(conversation.conversation_id, conversation);
        return reply(res, 200, conversation);
      }
      const conversationPath = path.match(/^\/api\/v2\/ai\/conversations\/([a-z0-9-]+)(\/messages|\/generate)?$/);
      if (conversationPath) {
        const conversation = aiState.get(conversationPath[1]);
        assert.ok(conversation);
        if (method === 'DELETE' && !conversationPath[2]) {
          aiState.delete(conversation.conversation_id);
          return reply(res, 200, null);
        }
        if (method === 'POST' && conversationPath[2] === '/messages') {
          if (fail && conversation.title.endsWith(' 2')) return reply(res, 503, null);
          assert.match(body.content, /Rewrite this note/);
          conversation.sequence = 1;
          return reply(res, 200, { conversation_id: conversation.conversation_id, role: 'user', sequence_no: 1 });
        }
        if (method === 'POST' && conversationPath[2] === '/generate') {
          assert.equal(conversation.sequence, 1);
          assert.deepEqual(body, { expected_sequence: 1 });
          conversation.sequence = 2;
          seen.generated.push(conversation.conversation_id);
          return reply(res, 200, { conversation_id: conversation.conversation_id, message_id: randomUUID(),
            role: 'assistant', sequence_no: 2 });
        }
      }
      throw new Error('Unexpected fixture operation.');
    } catch (error) {
      handlerErrors.push(error);
      reply(res, 500, null);
    }
  });
  const sockets = new WebSocketServer({ noServer: true });
  server.on('upgrade', (req, socket, head) => {
    try {
      assert.equal(req.url, '/_ws', 'WebSocket credential must never be in the URL');
      assert.ok([...sessionState.values()].some(item => req.headers.authorization === `Bearer ${item.tokens.access_token}`));
      sockets.handleUpgrade(req, socket, head, conn => {
        conn.send(JSON.stringify({ type: 'system_notification', data: { message: 'WebSocket connected', user_id: userId } }));
        conn.on('message', raw => {
          try {
            assert.deepEqual(JSON.parse(raw.toString()), { type: 'chat_join_channel', data: { channelId: channel } });
            listener = conn;
            conn.send(JSON.stringify({ type: 'system_notification', data: { code: 'chat_channel_ready', channel_id: channel } }));
          } catch (error) {
            handlerErrors.push(error);
            conn.terminate();
          }
        });
      });
    } catch (error) {
      handlerErrors.push(error);
      socket.destroy();
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    for (const socket of sockets.clients) socket.terminate();
    await Promise.all([new Promise(resolve => sockets.close(resolve)), new Promise(resolve => server.close(resolve))]);
    assert.deepEqual(handlerErrors, []);
  });
  return { seen, sessionState, postState, aiState, chatState, target: {
    baseUrl: `http://127.0.0.1:${server.address().port}`,
    account: 'isolated-fixture', password: 'fixture-password', chatChannelId: channel,
  } };
}

test('runs native workloads, measures matching early broadcasts and cleans captured fixtures', async t => {
  const fixture = await isolatedBackend(t);
  const rows = await runWorkloads(fixture.target, { requests: 4, concurrency: 2, timeoutMs: 1000 });
  assert.deepEqual(Object.keys(rows), workloadNames);
  for (const row of Object.values(rows)) {
    assert.equal(row.samples, 4);
    assert.equal(row.successful, 4);
    assert.equal(row.errors, 0);
    assert.equal(row.cleanupErrors, 0);
    assert.ok(row.qps > 0 && 0 <= row.p50Ms && row.p50Ms <= row.p95Ms && row.p95Ms <= row.p99Ms);
  }
  assert.equal(fixture.seen.feedPeak, 2);
  assert.equal(new Set(fixture.seen.refresh).size, 2, 'each refresh worker owns a session');
  assert.equal(new Set(fixture.seen.liked).size, 4);
  assert.equal(new Set(fixture.seen.generated).size, 4);
  assert.equal(fixture.seen.chat.length, 4);
  assert.ok(rows.websocketBroadcast.p95Ms < 100,
    'matching early receipt must not inherit the delayed HTTP response time');
  assert.equal(fixture.sessionState.size, 0);
  assert.equal(fixture.postState.size, 0);
  assert.equal(fixture.aiState.size, 0);
  assert.equal(fixture.chatState.size, 0);
});

test('reports failed setup, unmatched broadcast and cleanup separately from latency samples', async t => {
  const fixture = await isolatedBackend(t, { fail: true });
  const rows = await runWorkloads(fixture.target, { requests: 2, concurrency: 2, timeoutMs: 350 });
  for (const name of ['likePost', 'websocketBroadcast', 'aiWriting']) {
    assert.equal(rows[name].samples, 2);
    assert.equal(rows[name].successful, 1);
    assert.equal(rows[name].errors, 1);
    assert.equal(rows[name].cleanupErrors, 0);
    assert.ok(rows[name].p99Ms >= 0);
  }
  assert.equal(rows.createPost.successful, 2);
  assert.equal(rows.createPost.errors, 0);
  assert.equal(rows.createPost.cleanupErrors, 1);
  assert.equal(fixture.sessionState.size, 0);
  assert.equal(fixture.postState.size, 1);
  assert.equal(fixture.aiState.size, 0);
  assert.equal(fixture.chatState.size, 0);
});
