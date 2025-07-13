import jwt from 'jsonwebtoken';

const runtimeConfig = useRuntimeConfig();

export default defineEventHandler(async event => {
  const refreshToken = getCookie(event, 'refresh_token');
  const getOracleConnection =
    event.context.getOracleConnection;

  if (refreshToken) {
    const connection = await getOracleConnection();
    try {
      // 1. 验证refresh token
      const decoded = jwt.verify(
        refreshToken,
        runtimeConfig.refreshSecret
      ) as {
        userId: string;
      };

      if (!decoded || !decoded.userId) {
        throw createError({
          statusCode: 401,
          statusMessage: 'Invalid refresh token',
          data: {
            success: false,
            message: 'Invalid refresh token',
            code: 401,
            timestamp: new Date().toISOString()
          } as ErrorResponse
        });
      }

      // 2. 删除数据库中的refresh token
      const deleteSql = `
      UPDATE n_user_sessions SET IS_ACTIVE = 0
      WHERE USER_ID = :userId AND DBMS_LOB.COMPARE(refresh_token, :refreshToken) = 0`;
      const count = await connection.execute(
        deleteSql,
        {
          userId: decoded.userId,
          refreshToken: refreshToken
        },
        { autoCommit: true }
      );
    } finally {
      // 5. 关闭数据库连接
      await connection.close();
    }
  }

  // 清除双Cookie
  setCookie(event, 'access_token', '', {
    httpOnly: true,
    secure: false,
    maxAge: -1
  });

  setCookie(event, 'refresh_token', '', {
    httpOnly: true,
    secure: false,
    maxAge: -1
  });

  return {
    success: true,
    message: 'Logged out successfully',
    code: 200,
    timestamp: new Date().toISOString()
  } as LogoutResponse;
});
