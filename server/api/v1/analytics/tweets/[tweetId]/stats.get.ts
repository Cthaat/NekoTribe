function rowToTweetInteractionItem(
  row: TweetInteractionRow
): TweetInteractionItem {
  return {
    tweetId: row[0],
    content: row[1],
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

  const getOracleConnection = event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    const userEngagementStatsSql = `
    SELECT
      user_id,
      username,
      display_name,
      total_tweets,
      tweets_this_week,
      tweets_this_month,
      total_likes_received,
      avg_likes_per_tweet,
      total_likes_given,
      total_comments_made,
      engagement_score
    from  v_user_engagement_stats
    WHERE user_id = :userId
    `;

    // 执行查询
    const result = await connection.execute(userEngagementStatsSql, {
      userId: user.userId
    });

    // 处理查询结果
    const rows = result.rows as UserEngagementStatsRow[];
    const userEngagementStats = rows.map(row =>
      rowToUserEngagementStatsItem(row)
    );

    // 返回成功响应
    return {
      success: true,
      message: '获取用户互动统计成功',
      data: {
        user: userEngagementStats[0]
      },
      code: 200,
      timestamp: new Date().toISOString()
    } as UserEngagementStatsSuccessResponse;
  } catch (error) {
    throw createError({
      statusCode: 500,
      message: '获取用户互动统计失败',
      data: {
        success: false,
        message: (error as Error).message,
        code: 500,
        timestamp: new Date().toISOString()
      } as UserEngagementStatsErrorResponse
    });
  } finally {
    await connection.close();
  }
});
