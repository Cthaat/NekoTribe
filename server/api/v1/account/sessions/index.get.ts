import { getSessions } from '@/server/utils/sessionsStore';

/**
 * 获取当前用户的会话列表
 * - 通过 Cookie 或 Authorization Bearer 获取 access_token
 * - 使用 token 末尾 6 位作为 tokenSuffix 标注当前设备
 */

export default defineEventHandler(async event => {
  const auth: Auth = event.context.auth as Auth;
  // 从 Cookie/Authorization 的 token 末尾 6 位作为标记（避免明文存 token）
  const token =
    getCookie(event, 'access_token') ||
    (getHeader(event, 'authorization') || '')
      .toString()
      .replace(/^Bearer\s+/i, '')
      .trim();
  const suffix = token ? token.slice(-6) : undefined;
  const sessions = await getSessions({
    userId: auth.userId,
    tokenSuffix: suffix
  });

  return {
    success: true,
    message: '获取会话列表成功',
    data: { sessions },
    code: 200,
    timestamp: new Date().toISOString()
  };
});
