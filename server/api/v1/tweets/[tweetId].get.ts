export default defineEventHandler(async event => {
  // 获取当前登录用户信息
  const user: Auth = event.context.auth as Auth;
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
    const getTweetSql = `
    SELECT
    *
    FROM
      n_tweets t
    WHERE
      t.tweet_id = :tweetId
      AND fn_can_view_tweet(:user_id, :tweetId) = 1
    `;

    const result = await connection.execute(getTweetSql, {
      tweetId,
      user_id: user.userId
    });

    const rows = result.rows as TweetGetRow[];
    if (rows.length === 0) {
      throw createError({
        statusCode: 404,
        message: '推文未找到',
        data: {
          success: false,
          message: '推文未找到',
          code: 404,
          timestamp: new Date().toISOString()
        } as ErrorResponse
      });
    }

    const row = rows[0];
    // 读取CLOB内容
    let content = '';
    if (row[1] && typeof row[1].getData === 'function') {
      content = await row[1].getData();
    } else if (typeof row[1] === 'string') {
      content = row[1];
    }

    const tweet: TweetGetItem = {
      tweetId: row[0],
      content,
      authorId: row[2],
      username: row[3],
      displayName: row[4],
      avatarUrl: row[5],
      isVerified: row[6],
      likesCount: row[7],
      retweetsCount: row[8],
      repliesCount: row[9],
      viewsCount: row[10],
      visibility: row[11],
      createdAt: row[12],
      replyToTweetId: row[13],
      retweetOfTweetId: row[14],
      quoteTweetId: row[15],
      engagementScore: row[16],
      timelineType: row[17],
      isFromFollowing: row[18],
      rn: row[19]
    } as TweetGetItem;

    return {
      success: true,
      message: '推文获取成功',
      data: {
        tweet
      } as TweetGetResponse['data'],
      code: 200,
      timestamp: new Date().toISOString()
    } as TweetGetResponse;
  } finally {
    await connection.close();
  }
});
