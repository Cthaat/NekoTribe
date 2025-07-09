// server/utils/auth.ts

/**
 * 伪造的 JWT 验证函数
 * 在真实应用中，使用 'jsonwebtoken' 库并验证签名
 * @param token - 客户端传来的令牌
 * @returns 如果令牌有效，返回 userId，否则返回 null
 */
export function verifyTokenAndGetUserId(token: string): string | null {
  if (typeof token !== 'string' || !token.startsWith('fake-jwt-for-user-')) {
    return null;
  }
  // 简单地从令牌中提取 userId
  const userId = token.split('-').pop();
  return userId || null;
}

/**
 * 伪造的 JWT 生成函数
 * @param userId - 用户ID
 * @returns 一个模拟的 JWT
 */
export function generateFakeToken(userId: string): string {
  return `fake-jwt-for-user-${userId}`;
}
