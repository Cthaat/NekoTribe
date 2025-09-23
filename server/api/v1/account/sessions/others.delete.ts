import { revokeAllExcept } from '@/server/utils/sessionsStore';

/** 注销除当前设备外的所有会话 */

export default defineEventHandler(async event => {
  const auth: Auth = event.context.auth as Auth;
  const token =
    getCookie(event, 'access_token') ||
    (getHeader(event, 'authorization') || '')
      .toString()
      .replace(/^Bearer\s+/i, '')
      .trim();
  const suffix = token ? token.slice(-6) : undefined;
  await revokeAllExcept(auth.userId, suffix);
  return {
    success: true,
    message: '已注销其他所有会话',
    data: {},
    code: 200,
    timestamp: new Date().toISOString()
  };
});
