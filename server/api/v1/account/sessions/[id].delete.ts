import { revokeSession } from '@/server/utils/sessionsStore';

/** 注销指定会话（按会话 ID） */

export default defineEventHandler(async event => {
  const auth: Auth = event.context.auth as Auth;
  const id = getRouterParam(event, 'id') as string;
  await revokeSession(auth.userId, id);
  return {
    success: true,
    message: '会话已注销',
    data: {},
    code: 200,
    timestamp: new Date().toISOString()
  };
});
