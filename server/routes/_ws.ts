import type { Peer } from 'crossws';
import { v2VerifyAccessToken } from '~/server/services/v2/auth';
import { v2CanAccessChatChannel } from '~/server/services/v2/chat';
import {
  v2PublishUserPresence,
  v2TouchAuthSession
} from '~/server/services/v2/presence';
import { getOracleConnection } from '~/server/utils/oracle';
import {
  REDIS_CHANNELS,
  subscribeToChannel,
  type WSMessage
} from '~/server/utils/redis';
import {
  WS_SERVER_ID,
  sendWsToAll,
  sendWsToRoom,
  sendWsToUser,
  sessionManager,
  type WSSessionAuthPayload
} from '~/server/utils/wsSession';
import { v2Execute, v2One } from '~/server/utils/v2';

type ExtendedPeer = Peer & {
  sessionId?: string;
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

function chatRedisChannel(channelId: number): string {
  return `${REDIS_CHANNELS.CHAT_CHANNEL}${channelId}`;
}

function userRedisChannel(userId: number): string {
  return `${REDIS_CHANNELS.USER_MESSAGE}${userId}`;
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

function extractPeerToken(peer: Peer): string {
  const request = peerRequest(peer);
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

async function authenticatePeer(
  peer: Peer
): Promise<WSSessionAuthPayload | null> {
  const token = extractPeerToken(peer);
  if (!token) return null;

  const payload = v2VerifyAccessToken(
    token
  ) as WSSessionAuthPayload | null;
  if (!payload?.userId || !payload.sessionId || !payload.jti) {
    return null;
  }

  const connection = await getOracleConnection();
  try {
    const session = await v2One(
      connection,
      `
      SELECT session_id
      FROM n_auth_sessions
      WHERE user_id = :user_id
        AND session_id = :session_id
        AND access_jti = :access_jti
        AND revoked_at IS NULL
        AND access_token_expires_at > CURRENT_TIMESTAMP
      `,
      {
        user_id: payload.userId,
        session_id: payload.sessionId,
        access_jti: payload.jti
      }
    );
    if (!session) return null;

    await v2Execute(
      connection,
      `
      UPDATE n_auth_sessions
      SET last_accessed_at = CURRENT_TIMESTAMP
      WHERE session_id = :session_id
      `,
      { session_id: payload.sessionId }
    );
    return payload;
  } finally {
    await connection.close();
  }
}

function parseClientMessage(raw: string): ClientMessage | null {
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!isRecord(parsed) || typeof parsed.type !== 'string') {
      return null;
    }
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
  const channelId =
    typeof raw === 'number' ? raw : Number(String(raw ?? ''));
  return Number.isFinite(channelId) && channelId > 0
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

const subscribedChatChannels = new Set<number>();
const subscribedUsers = new Set<number>();
const subscribedGlobalChannels = new Set<string>();
const presenceOfflineTimers = new Map<number, ReturnType<typeof setTimeout>>();
const PRESENCE_OFFLINE_GRACE_MS = 95_000;

async function initializeRedisSubscriptions(): Promise<void> {
  if (!subscribedGlobalChannels.has(REDIS_CHANNELS.BROADCAST)) {
    const subscribed = await subscribeToChannel(
      REDIS_CHANNELS.BROADCAST,
      message => {
        sendWsToAll(message);
      }
    );
    if (subscribed) {
      subscribedGlobalChannels.add(REDIS_CHANNELS.BROADCAST);
    }
  }

  if (
    !subscribedGlobalChannels.has(
      REDIS_CHANNELS.SYSTEM_NOTIFICATION
    )
  ) {
    const subscribed = await subscribeToChannel(
      REDIS_CHANNELS.SYSTEM_NOTIFICATION,
      message => {
        sendWsToAll(message);
      }
    );
    if (subscribed) {
      subscribedGlobalChannels.add(
        REDIS_CHANNELS.SYSTEM_NOTIFICATION
      );
    }
  }

  if (!subscribedGlobalChannels.has(REDIS_CHANNELS.PRESENCE)) {
    const subscribed = await subscribeToChannel(
      REDIS_CHANNELS.PRESENCE,
      message => {
        const data = isRecord(message.data) ? message.data : {};
        if (data.server_id === WS_SERVER_ID) return;
        sendWsToAll(message);
      }
    );
    if (subscribed) {
      subscribedGlobalChannels.add(REDIS_CHANNELS.PRESENCE);
    }
  }
}

async function ensureChatRedisSubscription(
  channelId: number
): Promise<void> {
  if (subscribedChatChannels.has(channelId)) return;

  const subscribed = await subscribeToChannel(
    chatRedisChannel(channelId),
    (message: WSMessage) => {
      const data = isRecord(message.data) ? message.data : {};
      if (data.server_id === WS_SERVER_ID) return;
      sendWsToRoom(chatRoomId(channelId), message);
    }
  );
  if (subscribed) {
    subscribedChatChannels.add(channelId);
  }
}

async function ensureUserRedisSubscription(
  userId: number
): Promise<void> {
  if (subscribedUsers.has(userId)) return;

  const subscribed = await subscribeToChannel(
    userRedisChannel(userId),
    (message: WSMessage) => {
      const data = isRecord(message.data) ? message.data : {};
      if (data.server_id === WS_SERVER_ID) return;
      sendWsToUser(userId, message);
    }
  );
  if (subscribed) {
    subscribedUsers.add(userId);
  }
}

async function handleJoinChatChannel(
  sessionId: string,
  data: unknown
): Promise<void> {
  const session = sessionManager.getSession(sessionId);
  if (!session) return;

  const channelId = channelIdFromData(data);
  if (!channelId) {
    sendPeer(session.peer, 'error', {
      message: 'channelId 参数错误'
    });
    return;
  }

  const connection = await getOracleConnection();
  try {
    const canAccess = await v2CanAccessChatChannel(
      connection,
      session.auth.userId,
      channelId
    );
    if (!canAccess) {
      sendPeer(session.peer, 'error', {
        message: '无权访问该聊天频道',
        channel_id: channelId
      });
      return;
    }
  } finally {
    await connection.close();
  }

  const roomId = chatRoomId(channelId);
  sessionManager.joinRoom(sessionId, roomId);
  await ensureChatRedisSubscription(channelId);
  sendPeer(session.peer, 'system_notification', {
    message: 'chat channel joined',
    channel_id: channelId,
    room: roomId
  });
}

function handleLeaveChatChannel(
  sessionId: string,
  data: unknown
): void {
  const session = sessionManager.getSession(sessionId);
  if (!session) return;

  const channelId = channelIdFromData(data);
  if (!channelId) return;
  sessionManager.leaveRoom(sessionId, chatRoomId(channelId));
}

async function touchWsSession(sessionId: string): Promise<void> {
  const session = sessionManager.getSession(sessionId);
  const authSessionId = session?.auth.sessionId;
  if (!authSessionId) return;

  const connection = await getOracleConnection();
  try {
    await v2TouchAuthSession(connection, authSessionId);
  } finally {
    await connection.close();
  }
}

function clearPresenceOfflineTimer(userId: number): void {
  const timer = presenceOfflineTimers.get(userId);
  if (!timer) return;
  clearTimeout(timer);
  presenceOfflineTimers.delete(userId);
}

function schedulePresenceOfflinePublish(userId: number): void {
  clearPresenceOfflineTimer(userId);
  presenceOfflineTimers.set(
    userId,
    setTimeout(async () => {
      presenceOfflineTimers.delete(userId);
      if (sessionManager.isUserOnline(userId)) return;

      const connection = await getOracleConnection();
      try {
        await v2PublishUserPresence(connection, userId);
      } catch (error) {
        console.error('[ws] publish delayed presence failed', {
          userId,
          error
        });
      } finally {
        await connection.close();
      }
    }, PRESENCE_OFFLINE_GRACE_MS)
  );
}

export default defineWebSocketHandler({
  async open(peer) {
    const extendedPeer = peer as ExtendedPeer;
    let auth: WSSessionAuthPayload | null = null;
    try {
      auth = await authenticatePeer(extendedPeer);
    } catch (error) {
      console.error('[ws] authenticate error', error);
    }
    if (!auth) {
      sendPeer(peer, 'error', { message: 'WebSocket 未认证' });
      peer.close();
      return;
    }

    const sessionId = generateSessionId();
    const wasOnline = sessionManager.isUserOnline(auth.userId);
    extendedPeer.sessionId = sessionId;
    await initializeRedisSubscriptions();
    sessionManager.addSession(sessionId, peer, auth);
    await ensureUserRedisSubscription(auth.userId);
    clearPresenceOfflineTimer(auth.userId);
    if (!wasOnline) {
      const connection = await getOracleConnection();
      try {
        await v2PublishUserPresence(connection, auth.userId);
      } finally {
        await connection.close();
      }
    }
    sendPeer(peer, 'system_notification', {
      message: 'WebSocket connected',
      session_id: sessionId,
      user_id: auth.userId
    });
  },

  async message(peer, message) {
    const sessionId = (peer as ExtendedPeer).sessionId;
    if (!sessionId) return;

    sessionManager.updateActivity(sessionId);
    const parsed = parseClientMessage(message.text());
    if (!parsed) {
      sendPeer(peer, 'error', { message: '消息格式错误' });
      return;
    }

    switch (parsed.type) {
      case 'chat_join_channel':
        await handleJoinChatChannel(sessionId, parsed.data);
        break;
      case 'chat_leave_channel':
        handleLeaveChatChannel(sessionId, parsed.data);
        break;
      case 'ping':
        await touchWsSession(sessionId);
        sendPeer(peer, 'pong', { timestamp: Date.now() });
        break;
      default:
        sendPeer(peer, 'error', {
          message: '不支持的 WebSocket 消息类型',
          type: parsed.type
        });
    }
  },

  async close(peer) {
    const sessionId = (peer as ExtendedPeer).sessionId;
    if (sessionId) {
      const removedSession = sessionManager.removeSession(sessionId);
      const userId = removedSession?.auth.userId;
      const authSessionId = removedSession?.auth.sessionId;
      if (userId && authSessionId) {
        const connection = await getOracleConnection();
        try {
          await v2TouchAuthSession(connection, authSessionId);
          if (!sessionManager.isUserOnline(userId)) {
            schedulePresenceOfflinePublish(userId);
          }
        } finally {
          await connection.close();
        }
      }
    }
  },

  error(peer, error) {
    const sessionId = (peer as ExtendedPeer).sessionId;
    console.error('[ws] error', { sessionId, error });
  }
});
