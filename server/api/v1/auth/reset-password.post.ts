import { verifyCode } from '~/server/utils/auth/verifyCode';
import Redis from 'ioredis';
import bcrypt from 'bcrypt';

export default defineEventHandler(async event => {
  const body = await readBody<ResetPasswordPayload>(event);

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

  if (!body.newPassword) {
    throw createError({
      statusCode: 400,
      message: '密码不能为空',
      statusMessage: 'Bad Request',
      data: {
        success: false,
        message: '密码不能为空',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  if (body.newPassword.length < 6) {
    throw createError({
      statusCode: 400,
      message: '密码长度不能少于6个字符',
      statusMessage: 'Bad Request',
      data: {
        success: false,
        message: '密码长度不能少于6个字符',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  await verifyCode(body.email, body.resettoken, event.context.redis as Redis);

  const hashedPassword: string = await bcrypt.hash(body.newPassword, 10);

  const connection = await getOracleConnection();

  try {
    const updataSql = `
      UPDATE n_users
      SET password_hash = :password_hash
      WHERE email = :email
      `;
    await connection.execute(
      updataSql,
      {
        password_hash: hashedPassword,
        email: body.email
      },
      { autoCommit: true }
    );

    return {
      success: true,
      message: '密码重置成功',
      code: 200,
      timestamp: new Date().toISOString()
    } as ResetPasswordResponse;
  } finally {
    // 5. 关闭数据库连接
    await connection.close();
  }
});
