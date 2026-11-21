import jwt from 'jsonwebtoken';

const decimalUserId = /^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$/;

export function verifyV2SessionToken(
  token: string,
  secret: string,
  kind: V2AuthPayload['type'],
  { allowLegacyRefresh = false }: { allowLegacyRefresh?: boolean } = {}
): V2AuthPayload | null {
  if (!secret) return null;
  try {
    const decoded = jwt.verify(token, secret, {
      algorithms: ['HS256', 'HS384', 'HS512']
    });
    if (!decoded || typeof decoded !== 'object' || Array.isArray(decoded)) return null;
    const payload: Record<string, unknown> = decoded;
    const { userName, sessionId, jti, iat, exp, nbf } = payload;
    const rawId = typeof payload.userId === 'string'
      ? payload.userId.replace(/^[ \t\r\n\f\v]+|[ \t\r\n\f\v]+$/g, '')
      : payload.userId;
    const userId = typeof rawId === 'string' && decimalUserId.test(rawId) ? Number(rawId) : rawId;
    if (typeof userId !== 'number' || !Number.isSafeInteger(userId) || userId <= 0 ||
        payload.type !== kind || typeof sessionId !== 'string' || !sessionId ||
        ((kind === 'access' || !allowLegacyRefresh) && (typeof jti !== 'string' || !jti)) ||
        (exp !== undefined && (typeof exp !== 'number' || !Number.isFinite(exp))) ||
        (nbf !== undefined && (typeof nbf !== 'number' || !Number.isFinite(nbf)))) return null;
    return {
      userId, sessionId, type: kind,
      userName: typeof userName === 'string' ? userName : undefined,
      jti: typeof jti === 'string' ? jti : undefined,
      iat: typeof iat === 'number' ? iat : undefined,
      exp: typeof exp === 'number' ? exp : undefined
    };
  } catch {
    return null;
  }
}
