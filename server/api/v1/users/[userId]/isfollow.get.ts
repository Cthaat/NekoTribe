export default defineEventHandler(async event => {
  // 获取动态参数 userId
  const userId = getRouterParam(event, 'userId');

  // 获取当前登录用户信息
  const user: Auth = event.context.auth as Auth;

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
    count(*) 
    from n_follows 
    where 
    following_id = :followingID
    AND follower_id = :followerId
    AND follow_type = 'follow'
    AND is_active = 1`;

    const userInfo = await connection.execute(selectSql, {
      followingID: userId,
      followerId: user.userId
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
    const userInfoRow: isFollow =
      (userInfo.rows?.[0] as isFollow) || [];

    return {
      success: true,
      message: '获取用户信息成功',
      data: {
        isFollowing: userInfoRow[0] === 1
      },
      code: 200,
      timestamp: new Date().toISOString()
    } as IsFollowResponse;
  } finally {
    await connection.close();
  }
});
