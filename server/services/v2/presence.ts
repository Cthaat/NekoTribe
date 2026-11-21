import type oracledb from 'oracledb';
import { ACTIVE_SESSION_ACCOUNT_SQL } from '../../utils/auth-session';
import type { WSMessage } from '~/server/utils/redis';
import {
  REDIS_CHANNELS,
  publishMessage
} from '~/server/utils/redis';
import {
  WS_SERVER_ID,
  sendWsToAll,
  sessionManager
} from '~/server/utils/wsSession';
import {
  v2Boolean,
  v2DateString,
  v2Execute,
  v2One,
  v2ServerError
} from '~/server/utils/v2';

export type V2OnlineStatus = 'online' | 'offline' | 'hidden';

export interface V2PresenceState {
  user_id: number;
  online_status: V2OnlineStatus;
  last_seen_at: string | null;
}

const ONLINE_WINDOW_SECONDS = 90;

export async function v2TouchAuthSession(
  connection: oracledb.Connection,
  sessionId: string
): Promise<void> {
  await v2Execute(
    connection,
    `
    UPDATE n_auth_sessions
    SET last_accessed_at = CURRENT_TIMESTAMP
    WHERE session_id = :session_id
      AND revoked_at IS NULL
      AND ${ACTIVE_SESSION_ACCOUNT_SQL}
    `,
    { session_id: sessionId }
  );
}

export async function v2GetUserPresence(
  connection: oracledb.Connection,
  userId: number
): Promise<V2PresenceState> {
  const row = await v2One(
    connection,
    `
    SELECT
      NVL(us.show_online_status, 1) AS show_online_status,
      (
        SELECT MAX(s.last_accessed_at)
        FROM n_auth_sessions s
        WHERE s.user_id = u.user_id
          AND s.revoked_at IS NULL
      ) AS last_seen_at,
      CASE
        WHEN NVL(us.show_online_status, 1) <> 1 THEN 'hidden'
        WHEN EXISTS (
          SELECT 1
          FROM n_auth_sessions s
          WHERE s.user_id = u.user_id
            AND s.revoked_at IS NULL
            AND s.last_accessed_at >=
              CURRENT_TIMESTAMP - NUMTODSINTERVAL(:online_window_seconds, 'SECOND')
        ) THEN 'online'
        ELSE 'offline'
      END AS online_status
    FROM n_users u
    LEFT JOIN n_user_settings us ON us.user_id = u.user_id
    WHERE u.user_id = :user_id
    `,
    {
      user_id: userId,
      online_window_seconds: ONLINE_WINDOW_SECONDS
    }
  );

  if (!row) {
    return {
      user_id: userId,
      online_status: 'offline',
      last_seen_at: null
    };
  }

  const showOnlineStatus = v2Boolean(row.SHOW_ONLINE_STATUS);
  const status = row.ONLINE_STATUS;
  if (status !== 'online' && status !== 'offline' && status !== 'hidden') v2ServerError();
  return {
    user_id: userId,
    online_status: showOnlineStatus ? status : 'hidden',
    last_seen_at: showOnlineStatus && status !== 'hidden'
      ? v2DateString(row.LAST_SEEN_AT)
      : null
  };
}

export function v2PresenceMessage(
  presence: V2PresenceState,
  serverId: string,
  timestamp: number
): WSMessage {
  if (!presence || !Number.isSafeInteger(presence.user_id) || presence.user_id <= 0 ||
      !['online', 'offline', 'hidden'].includes(presence.online_status) ||
      typeof serverId !== 'string' || serverId.length === 0 ||
      !Number.isSafeInteger(timestamp) || timestamp < 0 ||
      (presence.online_status !== 'hidden' && presence.last_seen_at !== null && typeof presence.last_seen_at !== 'string')) {
    throw new Error('Invalid presence event');
  }
  return {
    type: 'presence_update',
    data: {
      user_id: presence.user_id,
      online_status: presence.online_status,
      last_seen_at: presence.online_status === 'hidden' ? null : presence.last_seen_at,
      server_id: serverId
    },
    timestamp
  };
}

export async function v2PublishUserPresence(
  connection: oracledb.Connection,
  userId: number,
  overrideStatus?: Exclude<V2OnlineStatus, 'hidden'>
): Promise<V2PresenceState> {
  const current = await v2GetUserPresence(connection, userId);
  const presence: V2PresenceState =
    current.online_status === 'hidden' || !overrideStatus
      ? current
      : {
          ...current,
          online_status: overrideStatus
        };
  let message: WSMessage;
  try {
    message = v2PresenceMessage(presence, WS_SERVER_ID, Date.now());
  } catch {
    console.warn('presence delivery unavailable');
    return presence;
  }
  // The settings transaction is already committed. Each transport is best
  // effort; one failure must not suppress the other or replay the mutation.
  try {
    sendWsToAll(message);
  } catch {
    console.warn('presence delivery unavailable');
  }
  try {
    await publishMessage(REDIS_CHANNELS.PRESENCE, message);
  } catch {
    console.warn('presence delivery unavailable');
  }
  return presence;
}

export function v2IsUserOnlineInCurrentServer(userId: number): boolean {
  return sessionManager.isUserOnline(userId);
}
