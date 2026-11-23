import { createHash } from 'node:crypto';

const session = 'user_id = :user_id AND session_id = :session_id AND device_info = :device_info';
const active = `${session} AND revoked_at IS NULL
  AND access_token_expires_at > LOCALTIMESTAMP AND refresh_token_expires_at > LOCALTIMESTAMP
  AND access_jti = :access_jti AND refresh_token_hash = :refresh_hash`;
const post = 'post_id = :post_id AND author_id = :user_id AND DBMS_LOB.COMPARE(content, TO_CLOB(:content)) = 0';
const likes = 'SELECT COUNT(*) FROM n_post_likes WHERE post_id = :post_id AND user_id = :user_id';

const statements = Object.freeze({
  sessionActive: `SELECT COUNT(*) FROM n_auth_sessions WHERE ${active}`,
  sessionRotated: `SELECT COUNT(*) FROM n_auth_sessions WHERE ${active}
    AND refresh_token_hash <> :original_hash AND access_jti <> :original_jti`,
  sessionRevoked: `SELECT COUNT(*) FROM n_auth_sessions WHERE ${session} AND revoked_at IS NOT NULL`,
  postCreated: `SELECT COUNT(*) FROM n_posts WHERE ${post}
    AND is_deleted = 0 AND post_type = 'post' AND visibility = 'public'`,
  postDeleted: `SELECT COUNT(*) FROM n_posts WHERE ${post} AND is_deleted = 1`,
  likePresent: likes,
  likeAbsent: likes,
});
const recoverStatement = `SELECT post_id FROM n_posts WHERE author_id = :user_id AND is_deleted = 0
  AND DBMS_LOB.COMPARE(content, TO_CLOB(:content)) = 0 FETCH FIRST 2 ROWS ONLY`;

export const positiveId = value => Number.isSafeInteger(value) && value > 0;

export function readTokenClaims(token) {
  if (typeof token !== 'string' || token.length > 8192) return null;
  const parts = token.split('.');
  if (parts.length !== 3 || parts.some(part => !/^[A-Za-z0-9_-]+$/u.test(part))) return null;
  try {
    const claims = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
    if (typeof claims.jti !== 'string' || !claims.jti || claims.jti.length > 128) return null;
    return claims;
  } catch {
    return null;
  }
}

function hash(token) {
  return typeof token === 'string' && token.length > 0
    ? createHash('sha256').update(token).digest('hex')
    : null;
}

function condition(name, fixture) {
  if (!positiveId(fixture.userId) || !Object.hasOwn(statements, name)) return null;
  const binds = { user_id: fixture.userId };
  if (name.startsWith('session')) {
    if (typeof fixture.sessionId !== 'string' || !fixture.sessionId || fixture.sessionId.length > 128 ||
        typeof fixture.sessionMarker !== 'string' || !fixture.sessionMarker) return null;
    binds.session_id = fixture.sessionId;
    binds.device_info = fixture.sessionMarker;
    if (name !== 'sessionRevoked') {
      const claims = readTokenClaims(fixture.accessToken);
      const refreshHash = hash(name === 'sessionActive' ? fixture.refreshToken : fixture.rotatedRefreshToken);
      if (!claims || !refreshHash) return null;
      binds.access_jti = claims.jti;
      binds.refresh_hash = refreshHash;
      if (name === 'sessionRotated') {
        const previous = readTokenClaims(fixture.originalAccessToken);
        const originalHash = hash(fixture.refreshToken);
        if (!previous || !originalHash) return null;
        binds.original_jti = previous.jti;
        binds.original_hash = originalHash;
      }
    }
  } else {
    if (!positiveId(fixture.postId)) return null;
    binds.post_id = fixture.postId;
    if (name.startsWith('post')) {
      if (typeof fixture.postContent !== 'string' || !fixture.postContent) return null;
      binds.content = fixture.postContent;
    }
  }
  return binds;
}

function bounded(operation, timeoutMs) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error('oracle-timeout')), timeoutMs);
  });
  return Promise.race([operation, timeout]).finally(() => clearTimeout(timer));
}

export async function openOracleState(config, { timeoutMs }, { driver } = {}) {
  if (!config || ![config.user, config.password, config.connectString].every(value => typeof value === 'string' && value)) {
    throw new Error('oracle-configuration-missing');
  }
  let connection;
  try {
    const db = driver ?? (await import('oracledb')).default;
    const opening = Promise.resolve().then(() => db.getConnection({
      user: config.user,
      password: config.password,
      connectString: config.connectString,
      connectTimeout: Math.max(1, Math.ceil(timeoutMs / 1000)),
    }));
    try {
      connection = await bounded(opening, timeoutMs);
    } catch {
      // A connector that completes just after the deadline must release its connection.
      void opening.then(conn => conn.close()).catch(() => {});
      throw new Error('oracle-connect-failed');
    }
    connection.callTimeout = timeoutMs;
    const execute = async (sql, binds) => {
      try {
        const result = await bounded(Promise.resolve().then(() =>
          connection.execute(sql, binds, { outFormat: db.OUT_FORMAT_ARRAY, maxRows: 2 })), timeoutMs);
        if (!Array.isArray(result?.rows)) throw new Error('oracle-invalid-rows');
        return result.rows;
      } catch {
        throw new Error('oracle-select-failed');
      }
    };
    return {
      async assert(name, fixture) {
        const binds = condition(name, fixture);
        if (!binds) throw new Error('oracle-bindings-missing');
        const rows = await execute(statements[name], binds);
        return rows.length === 1 && rows[0]?.[0] === (name === 'likeAbsent' ? 0 : 1);
      },
      async findPost(fixture) {
        if (!positiveId(fixture.userId) || typeof fixture.postContent !== 'string' || !fixture.postContent) return null;
        const rows = await execute(recoverStatement, { user_id: fixture.userId, content: fixture.postContent });
        if (rows.length === 0) return null;
        if (rows.length !== 1 || !positiveId(rows[0]?.[0])) throw new Error('oracle-post-ambiguous');
        return rows[0][0];
      },
      async close() {
        try {
          await bounded(Promise.resolve().then(() => connection.close()), timeoutMs);
        } catch {
          throw new Error('oracle-close-failed');
        }
      },
    };
  } catch {
    if (connection) void Promise.resolve().then(() => connection.close()).catch(() => {});
    throw new Error('oracle-open-failed');
  }
}
