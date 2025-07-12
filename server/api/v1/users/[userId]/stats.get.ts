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

  const getOracleConnection = event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    const selectSql = `
    SELECT *
    FROM v_user_profile
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
    const userInfoRow: GetOthersStats =
      (userInfo.rows?.[0] as GetOthersStats) || [];

    return {
      success: true,
      message: '获取用户信息成功',
      data: {
        userData: {
          userInfo: {
            userId: userInfoRow[0], // 用户ID
            username: userInfoRow[1], // 用户名
            displayName: userInfoRow[2], // 显示名称
            email: userInfoRow[3], // 邮箱
            avatarUrl: userInfoRow[4], // 头像地址
            bio: userInfoRow[5], // 个人简介
            location: userInfoRow[6], // 所在地
            website: userInfoRow[7], // 个人网站
            isVerified: userInfoRow[8], // 是否认证
            followersCount: userInfoRow[9], // 粉丝数
            followingCount: userInfoRow[10], // 关注数
            tweetsCount: userInfoRow[11], // 推文数
            likesCount: userInfoRow[12], // 点赞数
            createdAt: userInfoRow[13], // 创建时间
            lastLoginAt: userInfoRow[14], // 最后登录时间
            activityStatus: userInfoRow[15] // 活跃状态
          }
        }
      },
      code: 200,
      timestamp: new Date().toISOString()
    } as GetOthersStatsResponse;
  } finally {
    await connection.close();
  }
});
