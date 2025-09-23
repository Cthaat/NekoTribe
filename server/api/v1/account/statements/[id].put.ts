import { updateStatement } from '@/server/utils/statementsStore';

/**
 * 更新某条账户状态的状态值
 * - 支持 action: mark_read | mark_unread | resolve | dismiss
 * - 转换为具体的 status 并保存
 */

export default defineEventHandler(async event => {
  const auth: Auth = event.context.auth as Auth;
  const id = getRouterParam(event, 'id') as string;
  const body = await readBody<{
    action:
      | 'mark_read'
      | 'mark_unread'
      | 'resolve'
      | 'dismiss';
  }>(event);

  let status: any;
  switch (body.action) {
    case 'mark_read':
      status = 'read';
      break;
    case 'mark_unread':
      status = 'unread';
      break;
    case 'resolve':
      status = 'resolved';
      break;
    case 'dismiss':
      status = 'dismissed';
      break;
    default:
      throw createError({
        statusCode: 400,
        statusMessage: 'Invalid action'
      });
  }

  const updated = await updateStatement(auth.userId, id, {
    status
  });

  return {
    success: true,
    message: '状态更新成功',
    data: { statement: updated },
    code: 200,
    timestamp: new Date().toISOString()
  };
});
