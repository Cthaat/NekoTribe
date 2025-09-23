export default defineEventHandler(async event => {
  // 获取动态参数 userId
  const userId = getRouterParam(event, 'userId');

  if (!userId) {
    throw createError({
      statusCode: 400,
      message: '缺少用户ID',
      data: {
        success: false,
        message: '缺少用户ID',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  const getOracleConnection =
    event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    const selectSql = `
    SELECT
      user_id,
      avatar_url,
      display_name,
      bio,
      location,
      website,
      birth_date
    FROM n_users
    WHERE user_id = :user_id`;

    const userInfo = await connection.execute(selectSql, {
      user_id: userId
    });

    if (!userInfo.rows || userInfo.rows.length === 0) {
      throw createError({
        statusCode: 404,
        message: '用户信息未找到',
        data: {
          success: false,
          message: '用户信息未找到',
          code: 404,
          timestamp: new Date().toISOString()
        } as ErrorResponse
      });
    }

    // 取第一行数据
    const userInfoRow: GetOthersInfo =
      (userInfo.rows?.[0] as GetOthersInfo) || [];

    return {
      success: true,
      message: '获取用户信息成功',
      data: {
        userData: {
          userInfo: {
            userId: userInfoRow[0],
            avatarUrl: userInfoRow[1],
            displayName: userInfoRow[2] || '',
            bio: userInfoRow[3] || '',
            location: userInfoRow[4] || '',
            website: userInfoRow[5] || '',
            birthDate: userInfoRow[6]
              ? new Date(userInfoRow[6]).toISOString()
              : null
          }
        }
      },
      code: 200,
      timestamp: new Date().toISOString()
    } as GetOthersInfoResponse;
  } finally {
    await connection.close();
  }
});
