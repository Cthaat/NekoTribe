import oracledb from 'oracledb';

export default defineEventHandler(async event => {
  // 获取body
  const body: FollowActionPayload = await readBody(event);
  // 获取当前登录用户信息
  const user: Auth = event.context.auth as Auth;

  const getOracleConnection = event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    const actionSql = `
    BEGIN
      fn_follow_action(
        :user_id,
        :target_user_id,
        :action
      );
    END;  
    `;

    const result = await connection.execute(
      actionSql,
      {
        user_id: user.userId,
        target_user_id: body.userId,
        action: body.action,
        p_result: {
          dir: oracledb.BIND_OUT,
          type: oracledb.STRING,
          maxSize: 200
        }
      },
      { autoCommit: true }
    );

    return {
      success: true,
      message: result.outBinds.p_result,
      data: {
        tweetId: result.outBinds.p_tweet_id
      },
      code: 200,
      timestamp: new Date().toISOString()
    } as FollowActionResponse;
  } catch (err) {
    const error = err as any;
    throw createError({
      statusCode: error.code || 500,
      message: '操作失败',
      data: {
        success: false,
        message: '操作失败，请稍后重试或联系管理员',
        code: error.code || 500,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  } finally {
    await connection.close();
  }
});
