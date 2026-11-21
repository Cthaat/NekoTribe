import jwt from 'jsonwebtoken';
import type { JwtPayload } from 'jsonwebtoken';
import type oracledb from 'oracledb';
import {
  createError,
  defineEventHandler,
  getCookie,
  getHeader,
  getRequestURL,
  setResponseHeader
} from 'h3';
import { useRuntimeConfig } from '#imports';
import { touchActiveSession } from '../utils/auth-session';
import { verifyV2SessionToken } from '../utils/auth-session-token';

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
  publicRoutes: AuthPublicRoute[];
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

type AuthPublicRoute = RegExp | { pattern: RegExp; methods: string[] };

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
      /^\/api\/v2\/auth\/two-factor\/challenges(?:\/[^/]+)?$/,
      /^\/api\/v2\/auth\/tokens\/current$/,
      /^\/api\/v2\/auth\/password-reset$/,
      /^\/api\/v2\/integrations\/sentiment-flow(?:\/|$)/,
      { pattern: /^\/api\/v2\/posts$/, methods: ['GET'] },
      { pattern: /^\/api\/v2\/posts\/(?:[1-9]\d*|trending)$/, methods: ['GET'] }
    ],
    async updateSession(connection, payload) {
      if (payload.type !== 'access' || !payload.sessionId || !payload.jti) {
        throw new Error('Invalid access session payload');
      }
      const active = await touchActiveSession(connection, {
        userId: payload.userId, sessionId: payload.sessionId, jti: payload.jti
      });
      if (!active) throw new Error('Access session is no longer active');
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

function getPublicRoute(
  policy: AuthVersionPolicy,
  pathname: string,
  method: string
): AuthPublicRoute | undefined {
  return policy.publicRoutes.find(route => route instanceof RegExp
    ? route.test(pathname)
    : route.pattern.test(pathname) && route.methods.includes(method));
}

function isLegacyV1ApiEnabled(): boolean {
  return ['1', 'true', 'yes', 'on'].includes(
    String(process.env.ENABLE_V1_API ?? '')
      .trim()
      .toLowerCase()
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
  // Browser and proxy caches must not retain API payloads across backend switches.
  if (pathname === '/api/v2' || pathname.startsWith('/api/v2/')) {
    setResponseHeader(event, 'Cache-Control', 'private, no-store');
  }
  const policy = getAuthPolicy(pathname);

  if (!policy) return;
  if (policy.version === 'v1' && !isLegacyV1ApiEnabled()) {
    throw createError({
      statusCode: 410,
      statusMessage: 'Legacy API is disabled'
    });
  }
  const publicRoute = getPublicRoute(policy, pathname, event.method);
  // Login/refresh/logout own credential handling; stale access cookies must not
  // prevent those flows. Public posts authenticate credentials when supplied.
  if (publicRoute instanceof RegExp) return;

  const token = extractToken(event);
  if (!token) {
    if (publicRoute) return;
    throw authError(policy, '请先登录');
  }

  let connection: oracledb.Connection | null = null;
  let verifiedPayload: CommonAuthPayload | null = null;
  try {
    const secret = String(runtimeConfig.accessSecret ?? '');
    const payload = policy.version === 'v2'
      ? verifyV2SessionToken(token, secret, 'access')
      : normalizeAuthPayload(jwt.verify(token, secret));
    if (!payload) throw authError(policy, 'Token无效或已过期');

    const context =
      event.context as unknown as AuthEventContext;
    connection = await context.getOracleConnection();
    await policy.updateSession(connection, payload, token);
    verifiedPayload = payload;
  } catch (error) {
    throw authError(policy, 'Token无效或已过期');
  } finally {
    if (connection) {
      try { await connection.close(); }
      catch { throw authError(policy, 'Token无效或已过期'); }
    }
  }
  if (verifiedPayload) {
    (event.context as unknown as AuthEventContext).auth = verifiedPayload;
  }
});
