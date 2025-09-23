import { createAppeal } from '@/server/utils/statementsStore';

/**
 * 提交对某条账户状态的申诉
 * - 需要 body.message（长度 >= 10）
 * - 创建后标记该条状态为 appealed，appeal.status = pending
 */

export default defineEventHandler(async event => {
  const auth: Auth = event.context.auth as Auth;
  const id = getRouterParam(event, 'id') as string;
  const body = await readBody<{ message: string }>(event);

  if (!body?.message || body.message.trim().length < 10) {
    throw createError({
      statusCode: 400,
      statusMessage: 'Appeal message too short'
    });
  }

  const updated = await createAppeal(
    auth.userId,
    id,
    body.message.trim()
  );

  return {
    success: true,
    message: '申诉已提交',
    data: { statement: updated },
    code: 200,
    timestamp: new Date().toISOString()
  };
});
