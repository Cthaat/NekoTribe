export default defineEventHandler(async event => {
  // 获取access token
  const user = event.context.auth;
  const getOracleConnection = event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    const selectSql = `
    SELECT * FROM n_users
    WHERE user_id = :user_id AND username = :username`;

    const userInfo = await connection.execute(selectSql, {
      user_id: user.userId,
      username: user.userName
    });
    // 取第一行数据
    const userInfoRow: GetUserInfo = (userInfo.rows?.[0] as GetUserInfo) || [];

    return {
      success: true,
      message: '获取用户信息成功',
      data: {
        userData: {
          userInfo: {
            userId: userInfoRow[0], // 用户ID
            email: userInfoRow[1], // 邮箱
            username: userInfoRow[2], // 用户名
            passwordHash: userInfoRow[3], // 密码哈希
            avatarUrl: userInfoRow[4], // 头像地址
            displayName: userInfoRow[5], // 显示名称
            bio: userInfoRow[6], // 个人简介
            location: userInfoRow[7], // 所在地
            website: userInfoRow[8], // 个人网站
            birthDate: userInfoRow[9], // 出生日期
            phone: userInfoRow[10], // 手机号
            isVerified: userInfoRow[11], // 是否认证
            isActive: userInfoRow[12], // 是否激活
            followersCount: userInfoRow[13], // 粉丝数
            followingCount: userInfoRow[14], // 关注数
            tweetsCount: userInfoRow[15], // 推文数
            likesCount: userInfoRow[16], // 点赞数
            createdAt: userInfoRow[17], // 创建时间
            updatedAt: userInfoRow[18], // 更新时间
            lastLoginAt: userInfoRow[19], // 最后登录时间
            createdBy: userInfoRow[20], // 创建人
            updatedBy: userInfoRow[21] // 更新人
          }
        }
      },
      code: 200,
      timestamp: new Date().toISOString()
    } as GetUserInfoResponse;
  } finally {
    // 5. 关闭数据库连接
    await connection.close();
  }
});
