import oracledb from 'oracledb';

export default defineEventHandler(async event => {
  // 获取当前登录用户信息
  const user: Auth = event.context.auth as Auth;
  // 获取 tweetId 路径参数
  const commentId = getRouterParam(event, 'commentId');

  if (!commentId) {
    throw createError({
      statusCode: 400,
      message: '缺少评论ID',
      data: {
        success: false,
        message: '缺少评论ID',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  const getOracleConnection = event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    // 检查用户是否有权限删除推文
    const checkSql = `
    SELECT COUNT(*)
    FROM n_comments c
    WHERE c.comment_id = :comment_id
      AND c.user_id = :user_id
    `;

    const checkResult = await connection.execute(checkSql, {
      comment_id: commentId,
      user_id: user.userId
    });

    const count = checkResult.rows[0][0] as number;

    if (count === 0) {
      throw createError({
        statusCode: 403,
        message: '您没有权限删除此推文',
        data: {
          success: false,
          message: '您没有权限删除此推文',
          code: 403,
          timestamp: new Date().toISOString()
        } as ErrorResponse
      });
    }

    const deleteSql = `
    BEGIN
        sp_delete_comment(
          :p_user_id,
          :p_comment_id,
          :p_result
        );
      END;
    `;
    // 调用存储过程
    const result = await connection.execute(
      deleteSql,
      {
        p_user_id: user.userId,
        p_comment_id: Number(commentId),
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
        message: msg,
        code: 200,
        timestamp: new Date().toISOString()
      };
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
      message: '推文删除失败',
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
