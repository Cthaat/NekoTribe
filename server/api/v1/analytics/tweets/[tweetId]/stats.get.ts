async function rowToTweetInteractionItem(
  row: TweetInteractionRow
): Promise<TweetInteractionItem> {
  let content = '';
  if (row[1] && typeof row[1].getData === 'function') {
    content = await row[1].getData();
  } else if (typeof row[1] === 'string') {
    content = row[1];
  }

  return {
    tweetId: row[0],
    content: content,
    authorId: row[2],
    author: row[3],
    createdAt: row[4],
    likedByUsers: row[5],
    retweetedByUsers: row[6],
    commentsCount: row[7]
  };
}

export default defineEventHandler(async event => {
  // 获取当前登录用户信息
  const user: Auth = event.context.auth as Auth;

  const tweetId = getRouterParam(event, 'tweetId');

  const getOracleConnection =
    event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    const userEngagementStatsSql = `
    SELECT
      tweet_id,
      content,
      author_id,
      author,
      created_at,
      liked_by_users,
      retweeted_by_users,
      comments_count
    from  v_tweet_interactions
    WHERE tweet_id = :tweetId
    `;

    // 执行查询
    const result = await connection.execute(
      userEngagementStatsSql,
      {
        tweetId: tweetId
      }
    );

    // 处理查询结果
    const rows = result.rows as TweetInteractionRow[];
    const tweetInteractionStats = await Promise.all(
      rows.map(row => rowToTweetInteractionItem(row))
    );

    // 返回成功响应
    return {
      success: true,
      message: '获取用户互动统计成功',
      data: {
        tweets: tweetInteractionStats[0]
      },
      code: 200,
      timestamp: new Date().toISOString()
    } as TweetInteractionsSuccessResponse;
  } catch (error) {
    throw createError({
      statusCode: 500,
      message: '获取用户互动统计失败',
      data: {
        success: false,
        message: (error as Error).message,
        code: 500,
        timestamp: new Date().toISOString()
      } as TweetInteractionsErrorResponse
    });
  } finally {
    await connection.close();
  }
});
