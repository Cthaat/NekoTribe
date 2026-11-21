import type oracledb from 'oracledb';

export const ACTIVE_SESSION_ACCOUNT_SQL = `EXISTS (
  SELECT 1 FROM n_users u
  WHERE u.user_id = n_auth_sessions.user_id
    AND u.is_active = 1 AND u.status = 'active'
)`;

export async function touchActiveSession(
  connection: oracledb.Connection,
  claims: { userId: number; sessionId: string; jti: string }
): Promise<boolean> {
  const result = await connection.execute(
    `UPDATE n_auth_sessions
     SET last_accessed_at = CURRENT_TIMESTAMP
     WHERE user_id = :userId AND session_id = :sessionId AND access_jti = :accessJti
       AND revoked_at IS NULL AND access_token_expires_at > CURRENT_TIMESTAMP
       AND ${ACTIVE_SESSION_ACCOUNT_SQL}`,
    { userId: claims.userId, sessionId: claims.sessionId, accessJti: claims.jti },
    { autoCommit: true }
  );
  return result.rowsAffected === 1;
}
