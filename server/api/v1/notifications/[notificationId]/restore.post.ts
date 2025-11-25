export default defineEventHandler(async event => {
  // 获取 notificationId 路径参数
  const notificationId = getRouterParam(
    event,
    'notificationId'
  );
  // 获取当前登录用户信息
  const user: Auth = event.context.auth as Auth;

  const getOracleConnection =
    event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    // 恢复通知：设置 is_deleted = 0
    const restoreSql = `
      UPDATE n_notifications
      SET is_deleted = 0
      WHERE notification_id = :notification_id
        AND user_id = :user_id
        AND is_deleted = 1
    `;

    const result = await connection.execute(
      restoreSql,
      {
        notification_id: notificationId,
        user_id: user.userId
      },
      { autoCommit: true }
    );

    if (result.rowsAffected === 0) {
      throw createError({
        statusCode: 404,
        message: '通知未找到或未在垃圾桶中',
        data: {
          success: false,
          message: '通知未找到或未在垃圾桶中',
          code: 404,
          timestamp: new Date().toISOString()
        } as ErrorResponse
      });
    }
    return {
      success: true,
      message: '通知已从垃圾桶恢复',
      data: {},
      code: 200,
      timestamp: new Date().toISOString()
    };
  } catch (err: any) {
    throw createError({
      statusCode: err.statusCode || 500,
      message: err.message || '恢复通知失败',
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
