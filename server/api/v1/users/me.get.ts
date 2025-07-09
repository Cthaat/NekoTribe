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
    console.log('用户信息', userInfoRow);
  } finally {
    // 5. 关闭数据库连接
    await connection.close();
  }
});
