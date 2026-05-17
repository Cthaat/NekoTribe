// server/utils/jwt.ts
import jwt from 'jsonwebtoken';
import type { Secret, SignOptions } from 'jsonwebtoken';

const runtimeConfig = useRuntimeConfig();

function jwtSecret(): Secret {
  const secret = String(runtimeConfig.accessSecret || '');
  if (!secret) {
    throw new Error('ACCESS_SECRET is not configured');
  }

  return secret;
}

/**
 * 用户信息接口
 */
export interface UserPayload {
  userId: string;
  username: string;
  email?: string;
  roles?: string[];
}

/**
 * 生成 JWT Token
 */
export function generateToken(
  payload: UserPayload
): string {
  return jwt.sign(payload, jwtSecret(), {
    expiresIn: '7d',
    issuer: 'NekoTribe',
    audience: 'NekoTribe-Users'
  });
}

/**
 * 验证 JWT Token
 */
export function verifyToken(
  token: string
): UserPayload | null {
  try {
    const decoded = jwt.verify(token, jwtSecret(), {
      issuer: 'NekoTribe',
      audience: 'NekoTribe-Users'
    }) as UserPayload;
    return decoded;
  } catch (error) {
    console.error('JWT 验证失败:', error);
    return null;
  }
}

/**
 * 从请求头中提取 Token
 */
export function extractTokenFromHeader(
  authHeader: string | undefined
): string | null {
  if (!authHeader) return null;

  // 支持 "Bearer <token>" 格式
  const match = authHeader.match(/^Bearer\s+(.+)$/i);
  if (match) {
    return match[1] ?? null;
  }

  // 也支持直接传递 token
  return authHeader;
}

/**
 * 从查询参数中提取 Token (用于 WebSocket 连接)
 */
export function extractTokenFromQuery(
  query: Record<string, unknown>
): string | null {
  const token = query.token ?? query.access_token;
  return typeof token === 'string' ? token : null;
}

/**
 * 生成刷新 Token
 */
export function generateRefreshToken(
  payload: UserPayload
): string {
  const refreshPayload = { ...payload, type: 'refresh' };
  const options: SignOptions = {
    expiresIn: '30d',
    issuer: 'NekoTribe',
    audience: 'NekoTribe-Users'
  };

  return jwt.sign(refreshPayload, jwtSecret(), options);
}

/**
 * 验证刷新 Token
 */
export function verifyRefreshToken(
  token: string
): UserPayload | null {
  try {
    const decoded = jwt.verify(token, jwtSecret(), {
      issuer: 'NekoTribe',
      audience: 'NekoTribe-Users'
    }) as UserPayload & { type: string };

    if (decoded.type !== 'refresh') {
      return null;
    }

    // 移除 type 字段返回用户信息
    const { type, ...userPayload } = decoded;
    return userPayload as UserPayload;
  } catch (error) {
    console.error('刷新 Token 验证失败:', error);
    return null;
  }
}
