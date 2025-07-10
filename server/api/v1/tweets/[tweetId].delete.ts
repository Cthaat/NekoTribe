import oracledb from 'oracledb';

export default defineEventHandler(async event => {
  // 获取当前登录用户信息
  const user = event.context.auth;
  // 获取 tweetId 路径参数
  const tweetId = getRouterParam(event, 'tweetId');

  if (!tweetId) {
    throw createError({
      statusCode: 400,
      message: '缺少推文ID',
      data: {
        success: false,
        message: '缺少推文ID',
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
    FROM n_tweets v
    WHERE v.tweet_id = :tweet_id
      AND v.author_id = :user_id
    `;

    const checkResult = await connection.execute(checkSql, {
      tweet_id: tweetId,
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
        sp_delete_tweet(
          :p_tweet_id,
          :p_user_id,
          :p_result
        );
      END;
    `;
    // 调用存储过程
    const result = await connection.execute(
      deleteSql,
      {
        p_tweet_id: Number(tweetId),
        p_user_id: user.userId,
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
