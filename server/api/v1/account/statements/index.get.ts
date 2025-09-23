import { getStatements } from '@/server/utils/statementsStore';

/**
 * 获取账户状态列表
 * - 支持 query：page, pageSize, status, type
 * - 返回分页后的 items/total/page/pageSize
 */

export default defineEventHandler(async event => {
  const auth: Auth = event.context.auth as Auth;
  const {
    page = '1',
    pageSize = '10',
    status = 'all',
    type = 'all'
  } = getQuery(event) as Record<string, string>;

  const result = await getStatements({
    userId: auth.userId,
    page: Number(page),
    pageSize: Number(pageSize),
    status: status as any,
    type: type as any
  });

  return {
    success: true,
    message: '获取账户状态成功',
    data: result,
    code: 200,
    timestamp: new Date().toISOString()
  };
});
