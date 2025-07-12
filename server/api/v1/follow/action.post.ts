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
        sp_manage_follow(
            p_follower_id => :user_id,
            p_following_id => :target_user_id,
            p_action => :action,
            p_result => :p_result
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

    const msg = result.outBinds.p_result as string;

    if (msg.startsWith('SUCCESS')) {
      return {
        success: true,
        message: result.outBinds.p_result,
        code: 200,
        timestamp: new Date().toISOString()
      } as FollowActionResponse;
    } else {
      throw createError({
        statusCode: 400,
        message: msg,
        data: {
          success: false,
          message: msg,
          code: 400,
          timestamp: new Date().toISOString()
        } as ErrorResponse
      });
    }
  } catch (err: any) {
    throw createError({
      statusCode: err.statusCode || 500,
      message: err.message || '关注操作失败',
      data: {
        success: false,
        message: err.message,
        code: err.statusCode || 500,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  } finally {
    await connection.close();
  }
});
