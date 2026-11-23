import type { Peer } from 'crossws';
import { v2VerifyAccessToken } from '~/server/services/v2/auth';
import { v2CanAccessChatChannel, v2CanDeliverDirectMessage, v2CanDeliverDirectRead, v2DirectTypingPeer } from '~/server/services/v2/chat';
import {
  v2PublishUserPresence,
  v2TouchAuthSession
} from '~/server/services/v2/presence';
import { getOracleConnection } from '~/server/utils/oracle';
import { resolveCorsOrigin } from '~/server/utils/cors';
import { attachOracleQueryCacheWithSource } from '~/server/utils/oracle-query-cache';
import type { WSMessage } from '~/server/utils/redis';
import { getRedisClient, publishMessage, REDIS_CHANNELS } from '~/server/utils/redis';
import { createRedisRealtimeTransport } from '~/server/utils/realtime-redis';
import { createRealtimeSubscription } from '~/server/utils/realtime-subscription';
import type { RealtimeSubscription } from '~/server/utils/realtime-subscription';
import type { WSSessionAuthPayload } from '~/server/utils/wsSession';
import {
  WS_SERVER_ID,
  sendWsEventToSession,
  sendWsRawToSession,
  sendWsToRoom,
  sendWsToUser,
  disconnectWsSession,
  revalidateWsSession,
  sessionManager
} from '~/server/utils/wsSession';
import { touchActiveSession } from '~/server/utils/auth-session';
import { isTypingEvent, typingInput, typingMinIntervalMs, type TypingEvent } from '~/server/utils/chat-realtime-details';
import { isCallClientEvent } from '~/server/utils/webrtc-signaling';
import { createWebRtcSocket } from '~/server/services/v2/webrtc-socket';
import { correlationId, observeHttp } from '~/server/utils/observability';
import { logInfo } from '~/server/utils/logging';

type ExtendedPeer = Peer & {
  sessionId?: string;
  connectionClosed?: boolean;
  opening?: boolean;
  failed?: boolean;
  ready?: boolean;
  sessionAuth?: WSSessionAuthPayload;
  realtime?: RealtimeSubscription;
  inboundTail?: Promise<void>;
  pendingInbound?: number;
  lastTyping?: Partial<Record<TypingEvent, number>>;
  call?: ReturnType<typeof createWebRtcSocket>;
};

interface WsPeerRequest {
  url?: string;
  headers?: Headers | Record<string, string | string[] | undefined>;
}

interface ClientMessage {
  type: string;
  data?: unknown;
}

function generateSessionId(): string {
  return `ws_${Date.now()}_${Math.random().toString(36).slice(2, 11)}`;
}

function chatRoomId(channelId: number): string {
  return `chat:channel:${channelId}`;
}

async function getCachedWsOracleConnection(options: {
  authUserId?: number | null;
  path?: string;
} = {}) {
  const connection = await getOracleConnection();
  return attachOracleQueryCacheWithSource(
    {
      redis: getRedisClient(),
      authUserId: options.authUserId ?? null,
      requestId: `ws:${WS_SERVER_ID}`,
      path: options.path ?? '/_ws'
    },
    connection
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return (
    typeof value === 'object' &&
    value !== null &&
    !Array.isArray(value)
  );
}

function headerValue(
  headers: WsPeerRequest['headers'],
  name: string
): string {
  if (!headers) return '';
  if (headers instanceof Headers) {
    return headers.get(name) ?? '';
  }

  const matchedKey = Object.keys(headers).find(
    key => key.toLowerCase() === name.toLowerCase()
  );
  const value = matchedKey ? headers[matchedKey] : undefined;
  return Array.isArray(value) ? value[0] ?? '' : value ?? '';
}

function cookieValue(cookieHeader: string, name: string): string {
  const item = cookieHeader
    .split(';')
    .map(part => part.trim())
    .find(part => part.startsWith(`${name}=`));
  if (!item) return '';

  try {
    return decodeURIComponent(item.slice(name.length + 1));
  } catch {
    return item.slice(name.length + 1);
  }
}

function peerRequest(peer: Peer): WsPeerRequest {
  return peer.request as unknown as WsPeerRequest;
}

function extractRequestToken(request: WsPeerRequest): string {
  const url = new URL(request?.url ?? '/_ws', 'http://localhost');
  const queryToken = url.searchParams.get('token');
  if (queryToken) return queryToken;

  const authorization = headerValue(request?.headers, 'authorization')
    .replace(/^Bearer\s+/i, '')
    .trim();
  if (authorization) return authorization;

  return cookieValue(
    headerValue(request?.headers, 'cookie'),
    'access_token'
  );
}

async function authenticateRequest(request: WsPeerRequest): Promise<WSSessionAuthPayload | null> {
  const token = extractRequestToken(request);
  if (!token) return null;

  const payload = v2VerifyAccessToken(
    token
  ) as WSSessionAuthPayload | null;
  if (!payload || !Number.isSafeInteger(payload.userId) || payload.userId <= 0 ||
      payload.type !== 'access' || typeof payload.sessionId !== 'string' || !payload.sessionId ||
      typeof payload.jti !== 'string' || !payload.jti) {
    return null;
  }

  // Session checks must never use the Oracle query cache: revocation is immediate.
  const connection = await getOracleConnection();
  try {
    const active = await touchActiveSession(connection, {
      userId: payload.userId, sessionId: payload.sessionId, jti: payload.jti
    });
    return active ? payload : null;
  } finally {
    await connection.close();
  }
}

function authenticatePeer(peer: Peer): Promise<WSSessionAuthPayload | null> {
  return authenticateRequest(peerRequest(peer));
}

function handshakeError(status: number, code: number, message: string): Response {
  return new Response(JSON.stringify({code, message, data: null, meta: null}), {
    status, headers: {'content-type': 'application/json', 'cache-control': 'private, no-store'}
  });
}

function parseClientMessage(raw: string): ClientMessage | null {
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!isRecord(parsed) || typeof parsed.type !== 'string') {
      return null;
    }
    if ((isTypingEvent(parsed.type) || isCallClientEvent(parsed.type)) && Object.keys(parsed).length !== 2) return null;
    return {
      type: parsed.type,
      data: parsed.data
    };
  } catch {
    return raw.includes('ping') ? { type: 'ping' } : null;
  }
}

function channelIdFromData(data: unknown): number | null {
  if (!isRecord(data)) return null;
  const raw = data.channelId ?? data.channel_id;
  if (typeof raw !== 'number' && (typeof raw !== 'string' || !/^\+?[0-9]+$/.test(raw))) return null;
  const channelId = Number(raw);
  return Number.isSafeInteger(channelId) && channelId > 0
    ? channelId
    : null;
}

function sendPeer(
  peer: Peer,
  type: WSMessage['type'],
  data: Record<string, unknown>
): void {
  peer.send(
    JSON.stringify({
      type,
      data,
      timestamp: Date.now()
    } satisfies WSMessage)
  );
}

function sendSession(
  sessionId: string, type: WSMessage['type'], data: Record<string, unknown>
): Promise<void> {
  return sendWsEventToSession(sessionId, {type, data, timestamp: Date.now()} satisfies WSMessage);
}

const presenceOfflineTimers = new Map<number, ReturnType<typeof setTimeout>>();
const PRESENCE_OFFLINE_GRACE_MS = 95_000;

async function handleJoinChatChannel(sessionId: string, data: unknown): Promise<void> {
  const session = sessionManager.getSession(sessionId);
  if (!session || session.closing) return;
  const channelId = channelIdFromData(data);
  if (!channelId) {
    await sendSession(sessionId, 'error', {message: 'channelId 参数错误'});
    return;
  }
  let canAccess = false;
  try {
    const connection = await getOracleConnection();
    try { canAccess = await v2CanAccessChatChannel(connection, session.auth.userId, channelId); }
    finally { await connection.close(); }
  } catch {
    await sendSession(sessionId, 'error', {message: '服务暂不可用'});
    return;
  }
  if (sessionManager.getSession(sessionId) !== session || session.closing) return;
  if (!canAccess) {
    await sendSession(sessionId, 'error', {message: '无权访问该聊天频道', channel_id: channelId});
    return;
  }
  const roomId = chatRoomId(channelId);
  if (!sessionManager.joinRoom(sessionId, roomId)) {
    await sendSession(sessionId, 'error', {message: '加入的聊天频道已达上限'});
    return;
  }
  if (!(session.peer as ExtendedPeer).realtime?.joinChat(channelId)) {
    sessionManager.leaveRoom(sessionId, roomId);
    await sendSession(sessionId, 'error', {message: '服务暂不可用'});
    return;
  }
  await sendSession(sessionId, 'system_notification', {message: 'chat channel joined', channel_id: channelId, room: roomId});
}

function handleLeaveChatChannel(sessionId: string, data: unknown): void {
  const session = sessionManager.getSession(sessionId);
  const channelId = channelIdFromData(data);
  if (!session || !channelId) return;
  sessionManager.leaveRoom(sessionId, chatRoomId(channelId));
  (session.peer as ExtendedPeer).realtime?.leaveChat(channelId);
}

async function handleTyping(sessionId: string, type: TypingEvent, data: unknown): Promise<void> {
  const scope = typingInput(data);
  const session = sessionManager.getSession(sessionId);
  if (!scope || !session) return;
  const extended = session.peer as ExtendedPeer;
  const room = 'channel_id' in scope ? chatRoomId(scope.channel_id) : null;
  if (room && !session.joinedRooms.has(room)) return;
  const now = Date.now();
  const last = extended.lastTyping ??= {};
  if (now - (last[type] ?? 0) < typingMinIntervalMs) return;
  last[type] = now;
  const userId = session.auth.userId;
  const frame: WSMessage = {type,data:{...scope,user_id:userId,server_id:WS_SERVER_ID},timestamp:now};
  const active = () => sessionManager.getSession(sessionId) === session && !session.closing;

  try {
    const connection = await getOracleConnection();
    let peer: number | null = null;
    let channelAllowed = false;
    try {
      if ('conversation_id' in scope) {
        peer = await v2DirectTypingPeer(connection, userId, scope.conversation_id);
      } else {
        channelAllowed = await v2CanAccessChatChannel(connection, userId, scope.channel_id);
      }
    } finally { await connection.close(); }
    if (!active()) return;
    if (peer && peer !== userId) {
      await Promise.allSettled([sendWsToUser(peer, frame), publishMessage(REDIS_CHANNELS.USER_MESSAGE + peer, frame)]);
    } else if ('channel_id' in scope && channelAllowed && room && session.joinedRooms.has(room)) {
      await Promise.allSettled([sendWsToRoom(room, frame), publishMessage(REDIS_CHANNELS.CHAT_CHANNEL + scope.channel_id, frame)]);
    }
  } catch { /* Typing state expires on clients when delivery is unavailable. */ }
}

function clearPresenceOfflineTimer(userId: number): void {
  const timer = presenceOfflineTimers.get(userId);
  if (!timer) return;
  clearTimeout(timer);
  presenceOfflineTimers.delete(userId);
}

function schedulePresenceOfflinePublish(userId: number): void {
  clearPresenceOfflineTimer(userId);
  if (presenceOfflineTimers.size >= 1024) {
    const oldest = presenceOfflineTimers.keys().next().value;
    if (oldest !== undefined) clearPresenceOfflineTimer(oldest);
  }
  const timer = setTimeout(async () => {
    presenceOfflineTimers.delete(userId);
    if (sessionManager.isUserOnline(userId)) return;
    try {
      const connection = await getCachedWsOracleConnection({authUserId: userId, path: '/_ws/presence/offline'});
      try { await v2PublishUserPresence(connection, userId); }
      finally { await connection.close(); }
    } catch { console.warn('[ws] delayed presence unavailable'); }
  }, PRESENCE_OFFLINE_GRACE_MS);
  timer.unref?.();
  presenceOfflineTimers.set(userId, timer);
}

export default defineWebSocketHandler({
  async upgrade(request) {
    const startedAt = performance.now();
    const requestId = correlationId(request.headers.get('x-request-id'));
    const complete = (response?: Response) => {
      const status = response?.status ?? 101;
      const elapsed = performance.now() - startedAt;
      observeHttp('GET', status, elapsed / 1000);
      logInfo('http:response', { request_id: requestId, method: 'GET', path: '/_ws', statusCode: status, durationMs: Math.floor(elapsed) });
      if (!response) return { headers: { 'X-Request-Id': requestId } };
      response.headers.set('X-Request-Id', requestId);
      return response;
    };
    const origin = request.headers.get('origin');
    if (origin !== null && !resolveCorsOrigin(origin)) {
      const host = request.headers.get('host');
      let sameOrigin = false;
      try {
        const parsed = new URL(origin);
        const publicBase = (process.env.BASE_URL ?? '').trim().replace(/\/+$/, '');
        sameOrigin = parsed.origin === origin && (
          parsed.protocol === 'https:' && origin === publicBase ||
          parsed.protocol === 'http:' && !!host && origin === `http://${host}`
        );
      } catch { /* Reject malformed or opaque origins. */ }
      if (!sameOrigin) return complete(handshakeError(403, 40301, 'Forbidden'));
    }
    const target: WsPeerRequest = {url: request.url, headers: request.headers};
    if (!extractRequestToken(target)) return complete(handshakeError(401, 40101, '请先登录'));
    try {
      if (!await authenticateRequest(target)) return complete(handshakeError(401, 40101, 'Token无效或已过期'));
    } catch {
      console.warn('[ws] authentication unavailable');
      return complete(handshakeError(401, 40101, 'Token无效或已过期'));
    }
    if (!sessionManager.hasCapacity()) return complete(handshakeError(503, 50301, '服务暂不可用，请稍后重试。'));
    return complete();
  },
  async open(peer) {
    const extended = peer as ExtendedPeer;
    if (extended.opening || extended.connectionClosed || extended.failed) return;
    extended.opening = true;
    let auth: WSSessionAuthPayload | null = null;
    try { auth = await authenticatePeer(peer); }
    catch { console.warn('[ws] authentication unavailable'); }
    if (extended.connectionClosed || extended.failed) return;
    if (!auth) {
      sendPeer(peer, 'error', {message: 'WebSocket 未认证'});
      peer.close();
      return;
    }
    const sessionId = generateSessionId();
    const initialAuth = auth;
    const wasOnline = sessionManager.isUserOnline(auth.userId);
    const registered = sessionManager.addSession(sessionId, peer, initialAuth, async () => {
      const current = await authenticatePeer(peer);
      return !!current && current.userId === initialAuth.userId &&
        current.sessionId === initialAuth.sessionId && current.jti === initialAuth.jti;
    }, () => {
      extended.ready = false;
      extended.realtime?.close();
      extended.realtime = undefined;
    }, {
      authorize: async channel => {
        const connection = await getOracleConnection();
        try { return await v2CanAccessChatChannel(connection, initialAuth.userId, channel); }
        finally { await connection.close(); }
      },
      leave: channel => { extended.realtime?.leaveChat(channel); },
      authorizeDirect: async (conversation, message, deleted) => {
        const connection = await getOracleConnection();
        try { return await v2CanDeliverDirectMessage(connection, initialAuth.userId, conversation, message, deleted); }
        finally { await connection.close(); }
      },
      authorizeDirectTyping: async (conversation, actor) => {
        const connection = await getOracleConnection();
        try { return await v2DirectTypingPeer(connection, initialAuth.userId, conversation) === actor; }
        finally { await connection.close(); }
      },
      authorizeDirectRead: async (conversation, reader, message) => {
        const connection = await getOracleConnection();
        try { return await v2CanDeliverDirectRead(connection, initialAuth.userId, conversation, reader, message); }
        finally { await connection.close(); }
      },
      authorizeCall: (type, data) => extended.call?.authorize(type, data) ?? Promise.resolve(false),
    });
    if (!registered) {
      sendPeer(peer, 'error', {message: '服务暂不可用'});
      peer.close();
      return;
    }
    extended.sessionId = sessionId;
    extended.sessionAuth = initialAuth;
    const active = () => !extended.connectionClosed && !extended.failed &&
      sessionManager.getSession(sessionId)?.peer === peer;
    extended.call = createWebRtcSocket({
      userId: initialAuth.userId, sessionId, isActive: active,
      findPeer: async conversation => {
        const connection = await getOracleConnection();
        try { return await v2DirectTypingPeer(connection, initialAuth.userId, conversation); }
        finally { await connection.close(); }
      },
      reply: frame => sendWsEventToSession(sessionId, frame),
      reject: call_id => sendSession(sessionId, 'error', {message:'通话信令不可用', ...(call_id ? {call_id} : {})}),
    });
    clearPresenceOfflineTimer(auth.userId);
    await sendSession(sessionId, 'system_notification', {
      message: 'WebSocket connected', session_id: sessionId, user_id: auth.userId
    });
    if (!active()) return;
    const realtime = createRealtimeSubscription({
      userId: auth.userId,
      serverId: WS_SERVER_ID,
      createTransport: createRedisRealtimeTransport,
      onState: state => {
        void sendSession(sessionId, 'system_notification', {
          code: 'realtime_status', user_id: initialAuth.userId, server_id: WS_SERVER_ID,
          local_presence: true, remote_events: state
        });
      },
      onMessage: raw => { void sendWsRawToSession(sessionId, raw); },
      onChatReady: channel => {
        const room = chatRoomId(channel);
        if (!sessionManager.getSession(sessionId)?.joinedRooms.has(room)) return;
        void sendSession(sessionId, 'system_notification', {code:'chat_channel_ready', channel_id:channel, room});
      }
    });
    extended.realtime = realtime;
    if (!active()) { realtime.close(); extended.realtime = undefined; return; }
    extended.ready = true;
    if (!wasOnline) {
      try {
        const connection = await getCachedWsOracleConnection({authUserId: auth.userId, path: '/_ws/presence/online'});
        try { if (active()) await v2PublishUserPresence(connection, auth.userId); }
        finally { await connection.close(); }
      } catch { console.warn('[ws] presence unavailable'); }
    }
  },

  async message(peer, message) {
    const extended = peer as ExtendedPeer;
    const sessionId = extended.sessionId;
    if (!sessionId || !extended.ready || extended.connectionClosed || extended.failed) return;
    let raw: string;
    try { raw = message.text(); }
    catch { disconnectWsSession(sessionId); return; }
    if (raw.length > 65536 || new TextEncoder().encode(raw).byteLength > 65536) {
      disconnectWsSession(sessionId); return;
    }
    const pending = extended.pendingInbound ?? 0;
    if (pending >= 16) { disconnectWsSession(sessionId); return; }
    extended.pendingInbound = pending + 1;
    const dispatch = (extended.inboundTail ?? Promise.resolve()).then(async () => {
      const session = sessionManager.getSession(sessionId);
      if (!session || session.peer !== peer || session.closing || !await revalidateWsSession(sessionId)) return;
      sessionManager.updateActivity(sessionId);
      const parsed = parseClientMessage(raw);
      if (!parsed) { await sendSession(sessionId, 'error', {message: '消息格式错误'}); return; }
      if (isCallClientEvent(parsed.type)) {
        await extended.call?.handle(parsed.type, parsed.data);
        return;
      }
      switch (parsed.type) {
        case 'chat_join_channel': await handleJoinChatChannel(sessionId, parsed.data); break;
        case 'chat_leave_channel': handleLeaveChatChannel(sessionId, parsed.data); break;
        case 'typing_start':
        case 'typing_stop': await handleTyping(sessionId, parsed.type, parsed.data); break;
        case 'ping': await sendSession(sessionId, 'pong', {timestamp: Date.now()}); break;
        default: await sendSession(sessionId, 'error', {message: '不支持的 WebSocket 消息类型', type: parsed.type});
      }
    }).catch(() => {
      disconnectWsSession(sessionId);
    }).finally(() => {
      extended.pendingInbound = (extended.pendingInbound ?? 1) - 1;
    });
    extended.inboundTail = dispatch;
    await dispatch;
  },

  async close(peer) {
    const extended = peer as ExtendedPeer;
    if (extended.connectionClosed) return;
    extended.connectionClosed = true;
    extended.ready = false;
    const removed = extended.sessionId ? sessionManager.removeSession(extended.sessionId) : null;
    const auth = removed?.auth ?? extended.sessionAuth;
    extended.sessionAuth = undefined;
    extended.realtime?.close();
    extended.realtime = undefined;
    await extended.call?.close();
    extended.call = undefined;
    if (!auth?.userId || !auth.sessionId) return;
    try {
      const connection = await getCachedWsOracleConnection({authUserId: auth.userId, path: '/_ws/close'});
      try { await v2TouchAuthSession(connection, auth.sessionId); }
      finally { await connection.close(); }
    } catch { console.warn('[ws] close presence unavailable'); }
    if (!sessionManager.isUserOnline(auth.userId)) schedulePresenceOfflinePublish(auth.userId);
  },

  error(peer) {
    const extended = peer as ExtendedPeer;
    if (extended.failed) return;
    extended.failed = true;
    console.warn('[ws] connection unavailable');
    if (extended.sessionId) disconnectWsSession(extended.sessionId);
    else { try { peer.close(); } catch { /* Already closed. */ } }
  }
});
