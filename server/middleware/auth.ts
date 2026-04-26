import jwt from 'jsonwebtoken';
import type { JwtPayload } from 'jsonwebtoken';
import type oracledb from 'oracledb';
import {
  createError,
  defineEventHandler,
  getCookie,
  getHeader,
  getRequestURL
} from 'h3';
import { useRuntimeConfig } from '#imports';

const runtimeConfig = useRuntimeConfig();

interface CommonAuthPayload {
  userId: number;
  userName?: string;
  sessionId?: string;
  jti?: string;
  type?: string;
  iat?: number;
  exp?: number;
}

interface AuthVersionPolicy {
  version: 'v1' | 'v2';
  prefix: string;
  publicRoutes: RegExp[];
  updateSession: (
    connection: oracledb.Connection,
    payload: CommonAuthPayload,
    token: string
  ) => Promise<void>;
}

interface AuthEventContext {
  auth?: CommonAuthPayload;
  getOracleConnection: () => Promise<oracledb.Connection>;
}

const AUTH_POLICIES: AuthVersionPolicy[] = [
  {
    version: 'v1',
    prefix: '/api/v1/',
    publicRoutes: [/^\/api\/v1\/auth\//],
    async updateSession(connection, payload, token) {
      await connection.execute(
        `
        UPDATE n_user_sessions
        SET last_accessed_at = SYSDATE
        WHERE user_id = :userId
          AND DBMS_LOB.COMPARE(access_token, :accessToken) = 0
        `,
        {
          userId: payload.userId,
          accessToken: token
        },
        { autoCommit: true }
      );
    }
  },
  {
    version: 'v2',
    prefix: '/api/v2/',
    publicRoutes: [
      /^\/api\/v2\/auth\/otp$/,
      /^\/api\/v2\/auth\/otp\/verification$/,
      /^\/api\/v2\/auth\/registration$/,
      /^\/api\/v2\/auth\/tokens$/,
      /^\/api\/v2\/auth\/tokens\/current$/,
      /^\/api\/v2\/auth\/password-reset$/
    ],
    async updateSession(connection, payload) {
      if (!payload.sessionId || !payload.jti) return;
      await connection.execute(
        `
        UPDATE n_auth_sessions
        SET last_accessed_at = CURRENT_TIMESTAMP
        WHERE user_id = :userId
          AND session_id = :sessionId
          AND access_jti = :accessJti
          AND revoked_at IS NULL
        `,
        {
          userId: payload.userId,
          sessionId: payload.sessionId,
          accessJti: payload.jti
        },
        { autoCommit: true }
      );
    }
  }
];

function getAuthPolicy(
  pathname: string
): AuthVersionPolicy | null {
  return (
    AUTH_POLICIES.find(policy =>
      pathname.startsWith(policy.prefix)
    ) ?? null
  );
}

function isPublicRoute(
  policy: AuthVersionPolicy,
  pathname: string
): boolean {
  return policy.publicRoutes.some(pattern =>
    pattern.test(pathname)
  );
}

function extractToken(
  event: Parameters<typeof getCookie>[0]
): string | null {
  const cookieToken = getCookie(event, 'access_token');
  if (cookieToken) return cookieToken;

  const authHeader =
    getHeader(event, 'authorization') ||
    getHeader(event, 'Authorization');
  if (!authHeader) return null;

  const token = String(authHeader)
    .replace(/^Bearer\s+/i, '')
    .trim();
  return token || null;
}

function normalizeAuthPayload(
  decoded: string | JwtPayload
): CommonAuthPayload | null {
  if (typeof decoded !== 'object' || decoded === null)
    return null;
  const userId =
    typeof decoded.userId === 'number'
      ? decoded.userId
      : Number(decoded.userId);
  if (!Number.isFinite(userId) || userId <= 0) return null;

  return {
    userId,
    userName:
      typeof decoded.userName === 'string'
        ? decoded.userName
        : undefined,
    sessionId:
      typeof decoded.sessionId === 'string'
        ? decoded.sessionId
        : undefined,
    jti:
      typeof decoded.jti === 'string'
        ? decoded.jti
        : undefined,
    type:
      typeof decoded.type === 'string'
        ? decoded.type
        : undefined,
    iat:
      typeof decoded.iat === 'number'
        ? decoded.iat
        : undefined,
    exp:
      typeof decoded.exp === 'number'
        ? decoded.exp
        : undefined
  };
}

function authError(
  policy: AuthVersionPolicy,
  message: string
) {
  return createError({
    statusCode: 401,
    statusMessage: message,
    data:
      policy.version === 'v2'
        ? {
            code: 40101,
            message,
            data: null,
            meta: null
          }
        : {
            success: false,
            message,
            code: 401,
            timestamp: new Date().toISOString()
          }
  });
}

export default defineEventHandler(async event => {
  const pathname = getRequestURL(event).pathname;
  const policy = getAuthPolicy(pathname);

  if (!policy || isPublicRoute(policy, pathname)) return;

  const token = extractToken(event);
  if (!token) throw authError(policy, '请先登录');

  let connection: oracledb.Connection | null = null;
  try {
    const decoded = jwt.verify(
      token,
      String(runtimeConfig.accessSecret)
    );
    const payload = normalizeAuthPayload(decoded);
    if (!payload)
      throw authError(policy, 'Token无效或已过期');

    const context =
      event.context as unknown as AuthEventContext;
    context.auth = payload;
    connection = await context.getOracleConnection();
    await policy.updateSession(connection, payload, token);
  } catch (error) {
    throw authError(policy, 'Token无效或已过期');
  } finally {
    if (connection) await connection.close();
  }
});
