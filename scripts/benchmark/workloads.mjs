import { randomUUID } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import WebSocket from 'ws';
import { expectStatus, login, requestJson } from './http.mjs';

const posts = '/api/v2/posts';
const conversations = '/api/v2/ai/conversations';
const currentSession = '/api/v2/auth/tokens/current';
const sessions = '/api/v2/auth/sessions';
const workloadNames = ['feed', 'profile', 'createPost', 'likePost', 'refresh', 'websocketBroadcast', 'aiWriting'];
const uuidPattern = /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const badReceipt = () => new Error('The benchmark operation did not return the expected receipt.');

function id(value) {
  if (!Number.isSafeInteger(value) || value <= 0) throw badReceipt();
  return value;
}

function makeRequest(target, timeoutMs, token) {
  return async (method, path, body) => {
    const envelope = expectStatus(await requestJson(target, { method, path, body, token, timeoutMs }));
    if (envelope?.code !== 200 || !Object.hasOwn(envelope, 'data')) throw badReceipt();
    return envelope.data;
  };
}

async function concurrent(count, concurrency, work) {
  const workers = Math.min(count, concurrency);
  await Promise.all(Array.from({ length: workers }, async (_, worker) => {
    for (let index = worker; index < count; index += workers) await work(index, worker);
  }));
}

function summarize(samples, elapsedMs, latencies = []) {
  latencies.sort((a, b) => a - b);
  const percentile = fraction => latencies.length ? latencies[Math.ceil(fraction * latencies.length) - 1] : null;
  return {
    samples,
    successful: latencies.length,
    errors: samples - latencies.length,
    qps: elapsedMs > 0 ? 1000 * latencies.length / elapsedMs : 0,
    p50Ms: percentile(0.5),
    p95Ms: percentile(0.95),
    p99Ms: percentile(0.99),
    cleanupErrors: 0,
  };
}

async function measure({ requests, concurrency }, operation) {
  const latencies = [];
  const phaseStarted = performance.now();
  await concurrent(requests, concurrency, async (index, worker) => {
    const started = performance.now();
    try {
      const receiptMs = await operation(index, worker, started);
      latencies.push(receiptMs ?? performance.now() - started);
    } catch {
      // Failed operations count toward the phase and the error rate, with no latency percentile.
    }
  });
  return summarize(requests, performance.now() - phaseStarted, latencies);
}

async function prepare(count, concurrency, provision) {
  const fixtures = Array(count);
  await concurrent(count, concurrency, async index => {
    try { fixtures[index] = await provision(index); }
    catch { /* The corresponding workload sample will be counted as failed. */ }
  });
  return fixtures;
}

async function cleanup(fixtures, concurrency, remove) {
  const list = [...fixtures].filter(value => value !== undefined);
  let cleanupErrors = 0;
  await concurrent(list.length, concurrency, async index => {
    try { await remove(list[index]); }
    catch { cleanupErrors++; }
  });
  return cleanupErrors;
}

async function postWorkload(request, options, label, like) {
  const postIds = new Set();
  const create = async index => {
    const content = `${label} ${index + 1}`;
    const data = await request('POST', posts, { content, visibility: 'public' });
    const postId = id(data?.post_id);
    if (data.content !== content || postIds.has(postId)) throw badReceipt();
    postIds.add(postId);
    return postId;
  };
  const prepared = like ? await prepare(options.requests, options.concurrency, create) : null;
  const result = await measure(options, async index => {
    if (!like) {
      await create(index);
      return;
    }
    const postId = id(prepared[index]);
    const data = await request('POST', `${posts}/${postId}/likes`);
    if (data?.post_id !== postId || data.is_liked !== true) throw badReceipt();
  });
  if (like) {
    result.cleanupErrors += await cleanup(postIds, options.concurrency,
      postId => request('DELETE', `${posts}/${postId}/likes`));
  }
  result.cleanupErrors += await cleanup(postIds, options.concurrency, postId => request('DELETE', `${posts}/${postId}`));
  return result;
}

async function refreshWorkload(target, request, options, primarySessionId) {
  const workers = Math.min(options.requests, options.concurrency);
  const sessionIds = new Set([primarySessionId]);
  const workerSessions = await prepare(workers, workers, async () => {
    const session = await login(target, options.timeoutMs);
    if (sessionIds.has(session.sessionId)) throw badReceipt();
    sessionIds.add(session.sessionId);
    return session;
  });
  const send = makeRequest(target, options.timeoutMs);
  const result = await measure(options, async (_, worker) => {
    const session = workerSessions[worker];
    if (!session) throw badReceipt();
    const data = await send('PATCH', currentSession, { refresh_token: session.refreshToken });
    if (data?.session_id !== session.sessionId || typeof data.refresh_token !== 'string' ||
        !data.refresh_token || data.refresh_token === session.refreshToken ||
        typeof data.access_token !== 'string' || !data.access_token || data.access_token === session.accessToken) {
      throw badReceipt();
    }
    session.refreshToken = data.refresh_token;
    session.accessToken = data.access_token;
  });
  // Revoking the known session ID also works after a refresh response is lost.
  result.cleanupErrors = await cleanup(workerSessions, options.concurrency,
    session => request('DELETE', `${sessions}/${encodeURIComponent(session.sessionId)}`));
  return result;
}

async function writingWorkload(request, options, label) {
  const conversationIds = new Set();
  const prepared = await prepare(options.requests, options.concurrency, async index => {
    const title = `${label} ${index + 1}`;
    const data = await request('POST', conversations, { purpose: 'writing', title });
    const conversationId = data?.conversation_id;
    if (typeof conversationId !== 'string' || !uuidPattern.test(conversationId) ||
        data.title !== title || conversationIds.has(conversationId)) throw badReceipt();
    conversationIds.add(conversationId);
    if (data.purpose !== 'writing') throw badReceipt();
    const path = `${conversations}/${conversationId}`;
    const note = await request('POST', `${path}/messages`, {
      content: 'Rewrite this note as one concise sentence: The meeting will be at noon tomorrow.',
    });
    const sequence = id(note?.sequence_no);
    if (note.conversation_id !== conversationId || note.role !== 'user') throw badReceipt();
    return { conversationId, path, sequence };
  });
  const result = await measure(options, async index => {
    const fixture = prepared[index];
    if (!fixture) throw badReceipt();
    const reply = await request('POST', `${fixture.path}/generate`, { expected_sequence: fixture.sequence });
    if (reply?.conversation_id !== fixture.conversationId || reply.role !== 'assistant' ||
        id(reply.sequence_no) !== fixture.sequence + 1 || typeof reply.message_id !== 'string' ||
        !uuidPattern.test(reply.message_id)) {
      throw badReceipt();
    }
  });
  result.cleanupErrors = await cleanup(conversationIds, options.concurrency,
    conversationId => request('DELETE', `${conversations}/${conversationId}`));
  return result;
}

class BroadcastSocket {
  constructor(baseUrl, accessToken, timeoutMs) {
    const url = new URL('/_ws', baseUrl);
    url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
    this.socket = new WebSocket(url, {
      headers: { Authorization: `Bearer ${accessToken}` },
      handshakeTimeout: timeoutMs,
      maxPayload: 262144,
    });
    this.waiters = new Set();
    this.timeoutMs = timeoutMs;
    this.socket.on('message', (raw, binary) => {
      const receivedAt = performance.now();
      if (binary) return;
      let frame;
      try { frame = JSON.parse(raw.toString()); } catch { return; }
      for (const waiter of this.waiters) {
        if (waiter.matches(frame, receivedAt)) waiter.finish(receivedAt);
      }
    });
    const abandon = () => {
      for (const waiter of this.waiters) waiter.finish(null);
    };
    this.socket.on('close', abandon);
    this.socket.on('error', abandon);
  }

  wait(matches) {
    let finish;
    const promise = new Promise(resolve => {
      const waiter = { matches, finish: result => {
        clearTimeout(timer);
        this.waiters.delete(waiter);
        resolve(result);
      } };
      finish = waiter.finish;
      const timer = setTimeout(() => finish(null), this.timeoutMs);
      if (this.socket.readyState >= WebSocket.CLOSING) finish(null);
      else this.waiters.add(waiter);
    });
    return { promise, cancel: () => finish(null) };
  }

  async join(channel, userId) {
    const welcome = await this.wait(frame => frame?.type === 'system_notification' &&
      frame.data?.message === 'WebSocket connected' && frame.data?.user_id === userId).promise;
    if (!welcome) throw badReceipt();
    const ready = this.wait(frame => frame?.type === 'system_notification' &&
      frame.data?.code === 'chat_channel_ready' && frame.data.channel_id === channel);
    try {
      this.socket.send(JSON.stringify({ type: 'chat_join_channel', data: { channelId: channel } }));
      if (!await ready.promise) throw badReceipt();
    } finally {
      ready.cancel();
    }
  }

  close() {
    if (this.socket.readyState !== WebSocket.CLOSED) this.socket.terminate();
  }
}

async function broadcastWorkload(target, session, request, options, label) {
  let subscriber;
  let result = summarize(options.requests, 0);
  const messageIds = new Set();
  try {
    let channel;
    try {
      channel = id(target.chatChannelId);
      subscriber = new BroadcastSocket(target.baseUrl, session.accessToken, options.timeoutMs);
      await subscriber.join(channel, session.userId);
    } catch {
      return result;
    }
    result = await measure(options, async (index, _, started) => {
      const content = `${label} ${index + 1}`;
      const earlyReceipts = new Map();
      let messageId;
      const receipt = subscriber.wait((frame, receivedAt) => {
        const delivered = frame?.data?.message;
        if (frame?.type !== 'chat_message' || frame.data?.channel_id !== channel ||
            delivered?.content !== content || delivered.channel_id !== channel) return false;
        const deliveredId = delivered.message_id;
        if (messageId !== undefined) return deliveredId === messageId;
        // Some backends emit the frame before returning the REST response.
        if (earlyReceipts.size < 8 && !earlyReceipts.has(deliveredId)) earlyReceipts.set(deliveredId, receivedAt);
        return false;
      });
      try {
        const created = await request('POST', `/api/v2/chat/channels/${channel}/messages`, { content });
        messageId = id(created?.message_id);
        if (created.channel_id !== channel || created.content !== content || messageIds.has(messageId)) throw badReceipt();
        messageIds.add(messageId);
        const receivedAt = earlyReceipts.get(messageId) ?? await receipt.promise;
        if (receivedAt === null) throw badReceipt();
        return receivedAt - started;
      } finally {
        receipt.cancel();
      }
    });
    return result;
  } finally {
    try { subscriber?.close(); } catch { result.cleanupErrors++; }
    result.cleanupErrors += await cleanup(messageIds, options.concurrency,
      messageId => request('DELETE', `/api/v2/chat/messages/${messageId}`));
  }
}

export async function runWorkloads(target, options) {
  let session;
  try { session = await login(target, options.timeoutMs); }
  catch { return Object.fromEntries(workloadNames.map(name => [name, summarize(options.requests, 0)])); }
  const request = makeRequest(target, options.timeoutMs, session.accessToken);
  const label = `benchmark ${randomUUID()}`;
  const result = {};
  try {
    result.feed = await measure(options, async () => {
      const page = await request('GET', `${posts}?timeline=home&page_size=20`);
      if (!Array.isArray(page)) throw badReceipt();
    });
    result.profile = await measure(options, async () => {
      const profile = await request('GET', `/api/v2/users/${session.userId}`);
      if (profile?.user_id !== session.userId) throw badReceipt();
    });
    result.createPost = await postWorkload(request, options, `${label} create`, false);
    result.likePost = await postWorkload(request, options, `${label} like`, true);
    result.refresh = await refreshWorkload(target, request, options, session.sessionId);
    result.websocketBroadcast = await broadcastWorkload(target, session, request, options, `${label} chat`);
    result.aiWriting = await writingWorkload(request, options, `${label} writing`);
    return result;
  } finally {
    const errors = await cleanup([session], 1, item => request('DELETE', `${sessions}/${encodeURIComponent(item.sessionId)}`));
    if (result.refresh) result.refresh.cleanupErrors += errors;
  }
}
