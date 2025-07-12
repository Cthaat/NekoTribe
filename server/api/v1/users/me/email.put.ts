import { verifyCode } from '~/server/utils/auth/verifyCode';
import Redis from 'ioredis';

export default defineEventHandler(
  async (event): Promise<ResetEmailResponse> => {
    // 获取当前登录用户信息
    const user: Auth = event.context.auth as Auth;
    const body = await readBody<ResetEmailPayload>(event);

    const getOracleConnection = event.context.getOracleConnection;

    if (!body || !body.resettoken) {
      throw createError({
        statusCode: 400,
        message: '请求体不能为空或缺少重置令牌',
        statusMessage: 'Bad Request',
        data: {
          success: false,
          message: '请求体不能为空或缺少重置令牌',
          code: 400,
          timestamp: new Date().toISOString()
        } as ErrorResponse
      });
    }

    if (!body.newEmail) {
      throw createError({
        statusCode: 400,
        message: '邮箱不能为空',
        statusMessage: 'Bad Request',
        data: {
          success: false,
          message: '邮箱不能为空',
          code: 400,
          timestamp: new Date().toISOString()
        } as ErrorResponse
      });
    }

    await verifyCode(
      body.newEmail,
      body.resettoken,
      event.context.redis as Redis
    );

    const connection = await getOracleConnection();

    try {
      const updateSql = `
      UPDATE n_users
      SET email = :email
      WHERE user_id = :userId AND username = :username
      `;
      await connection.execute(
        updateSql,
        {
          email: body.newEmail,
          userId: user.userId,
          username: user.userName
        },
        { autoCommit: true }
      );

      return {
        success: true,
        message: '邮箱重置成功',
        data: {
          newEmail: body.newEmail
        },
        code: 200,
        timestamp: new Date().toISOString()
      } as ResetEmailResponse;
    } finally {
      // 5. 关闭数据库连接
      await connection.close();
    }
  }
);
