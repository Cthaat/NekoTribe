import type oracledb from 'oracledb';
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
  v2One
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
        WHEN NVL(us.show_online_status, 1) = 0 THEN 'hidden'
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
  return {
    user_id: userId,
    online_status: row.ONLINE_STATUS as V2OnlineStatus,
    last_seen_at: showOnlineStatus
      ? v2DateString(row.LAST_SEEN_AT)
      : null
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
  const message: WSMessage = {
    type: 'presence_update',
    data: {
      ...presence,
      server_id: WS_SERVER_ID
    },
    timestamp: Date.now()
  };

  sendWsToAll(message);
  await publishMessage(REDIS_CHANNELS.PRESENCE, message);
  return presence;
}

export function v2IsUserOnlineInCurrentServer(userId: number): boolean {
  return sessionManager.isUserOnline(userId);
}
