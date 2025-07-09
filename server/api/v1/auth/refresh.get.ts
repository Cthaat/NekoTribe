import jwt from 'jsonwebtoken';

const runtimeConfig = useRuntimeConfig();

export default defineEventHandler(async event => {
  // 获取refresh token
  const refreshToken = getCookie(event, 'refresh_token');
  const getOracleConnection = event.context.getOracleConnection;

  if (!refreshToken) {
    throw createError({
      statusCode: 401,
      statusMessage: 'Refresh token required',
      data: {
        success: false,
        message: 'Refresh token is missing',
        code: 401,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  const connection = await getOracleConnection();

  try {
    // 验证refresh token
    const decoded = jwt.verify(refreshToken, runtimeConfig.refreshSecret) as {
      userId: string;
      type: string;
    };

    if (decoded.type !== 'refresh') {
      throw createError({
        statusCode: 401,
        statusMessage: 'Invalid token type',
        data: {
          success: false,
          message: 'Invalid token type',
          code: 401,
          timestamp: new Date().toISOString()
        } as ErrorResponse
      });
    }

    // 验证数据库中的refresh token
    const checkSql = `
    SELECT COUNT(*) AS count
    FROM n_user_sessions
    WHERE user_id = :userId AND DBMS_LOB.COMPARE(refresh_token, :refreshToken) = 0 AND is_active = 1`;
    const checkResult = await connection.execute(checkSql, {
      userId: decoded.userId,
      refreshToken: refreshToken
    });
    const checkSessionResultRow: checkSessionResultRow =
      (checkResult.rows?.[0] as checkSessionResultRow) || [];
    const checkSessionCount = checkSessionResultRow[0] || 0;

    // 如果没有找到有效的session
    if (checkSessionCount === 0) {
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

    // 获取用户信息
    const sessionSql = `
    SELECT refresh_token_expires_at, session_id
    FROM n_user_sessions
    WHERE user_id = :userId AND DBMS_LOB.COMPARE(refresh_token, :refreshToken) = 0 AND is_active = 1
    `;
    const sessionResult = await connection.execute(sessionSql, {
      userId: decoded.userId,
      refreshToken: refreshToken
    });
    const sessionResultRow: sessionRow =
      (sessionResult.rows?.[0] as sessionRow) || [];

    // 检查是否过期
    if (new Date() > new Date(sessionResultRow[0])) {
      // 删除过期的token
      const deleteSql = `
      UPDATE n_user_sessions
      SET is_active = 0
      WHERE user_id = :userId AND DBMS_LOB.COMPARE(refresh_token, :refreshToken) = 0
      `;
      await connection.execute(
        deleteSql,
        { userId: decoded.userId, refreshToken: refreshToken },
        { autoCommit: true }
      );

      throw createError({
        statusCode: 401,
        statusMessage: 'Refresh token expired',
        data: {
          success: false,
          message: 'Refresh token expired',
          code: 401,
          timestamp: new Date().toISOString()
        } as ErrorResponse
      });
    }

    const userSql = `SELECT 
    USERNAME
    FROM n_users WHERE user_id = :userId`;

    const userResult = await connection.execute(userSql, {
      userId: decoded.userId
    });

    // 取第一行数据
    const userResultRow: refreshUserRow =
      (userResult.rows?.[0] as refreshUserRow) || [];

    // 生成新的access token
    const newAccessToken = jwt.sign(
      {
        userId: decoded.userId,
        userName: userResultRow[0],
        type: 'access'
      },
      runtimeConfig.accessSecret,
      { expiresIn: Number(runtimeConfig.accessExpiresIn) }
    );

    const newRefreshToken = jwt.sign(
      {
        userId: decoded.userId,
        type: 'refresh'
      },
      runtimeConfig.refreshSecret,
      { expiresIn: Number(runtimeConfig.refreshExpiresIn) } // 30天过期
    );

    // 设置新的access token cookie
    setCookie(event, 'access_token', newAccessToken, {
      httpOnly: true,
      secure: false,
      maxAge: 15 * 60
    });

    // 设置新的refresh token cookie
    setCookie(event, 'refresh_token', newRefreshToken, {
      httpOnly: true,
      secure: false,
      maxAge: 30 * 24 * 60 * 60 // 30天
    });

    // 更新数据库中的access token和refresh token
    // 注意：这里假设session_id是唯一的标识符
    const updateSql = `
    UPDATE n_user_sessions
    SET
    access_token = :accessToken,
    refresh_token = :refreshToken,
    access_token_expires_at = :accessTokenExpiresAt,
    refresh_token_expires_at = :refreshTokenExpiresAt
    WHERE user_id = :userId AND session_id = :sessionId
    `;

    // 执行更新操作
    await connection.execute(
      updateSql,
      {
        accessToken: newAccessToken,
        refreshToken: newRefreshToken,
        userId: decoded.userId,
        sessionId: sessionResultRow[1],
        accessTokenExpiresAt: new Date(
          Date.now() + Number(runtimeConfig.accessExpiresIn) * 1000
        ),
        refreshTokenExpiresAt: new Date(
          Date.now() + Number(runtimeConfig.refreshExpiresIn) * 1000
        )
      },
      { autoCommit: true }
    );

    return {
      success: true,
      message: 'Token refreshed successfully',
      data: {
        accessToken: newAccessToken,
        refreshToken: newRefreshToken
      },
      code: 200,
      timestamp: new Date().toISOString()
    } as RefreshResponse;
  } finally {
    await connection.close();
  }
});
