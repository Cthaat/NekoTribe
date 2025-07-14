export default defineEventHandler(async event => {
  const body = await readBody<UpdateUserInfoPayload>(event);
  const user: Auth = event.context.auth as Auth;
  const getOracleConnection =
    event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    const updateSql = `
    UPDATE n_users
    SET display_name = :display_name,
        bio = :bio,
        location = :location,
        website = :website,
        birth_date = TO_DATE(:birth_date, 'YYYY-MM-DD'),
        phone = :phone
    WHERE user_id = :user_id AND username = :username`;

    const userInfo = await connection.execute(
      updateSql,
      {
        display_name: body.displayName,
        bio: body.bio,
        location: body.location,
        website: body.website,
        birth_date: body.birthDate,
        phone: body.phone,
        user_id: user.userId,
        username: user.userName
      },
      {
        autoCommit: true
      }
    );

    if (userInfo.rows?.length === 0) {
      throw createError({
        statusCode: 400,
        statusMessage: 'Bad Request',
        data: {
          success: false,
          message:
            '用户信息更新失败，可能是用户不存在或数据不合法',
          code: 400,
          timestamp: new Date().toISOString()
        } as ErrorResponse
      });
    }

    return {
      success: true,
      message: '用户信息更新成功',
      data: {},
      code: 200,
      timestamp: new Date().toISOString()
    } as UpdateUserInfoResponse;
  } finally {
    // 5. 关闭数据库连接
    await connection.close();
  }
});
