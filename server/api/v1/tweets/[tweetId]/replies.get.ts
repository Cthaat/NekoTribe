export default defineEventHandler(async event => {
  // 获取当前登录用户信息
  const user: Auth = event.context.auth as Auth;
  // 获取 tweetId 路径参数
  const tweetId = getRouterParam(event, 'tweetId');

  // 获取 query 参数
  const query: TweetRepliesPayload = getQuery(event) as TweetRepliesPayload;

  // 提取参数
  const { page = 1, pageSize = 10 } = query;

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
    const getReplyTweetSql = `
    SELECT *
    FROM (
        SELECT
            v.*,
            ROW_NUMBER() OVER (ORDER BY v.created_at DESC) AS rn
        FROM v_tweet_details v
        WHERE v.reply_to_tweet_id = :tweetId
          AND fn_can_view_tweet(:user_id, v.tweet_id) = 1
    )
    WHERE rn > (:page - 1) * :pagesize
      AND rn <= :page * :pagesize
    ORDER BY created_at DESC
    `;

    const getReplyTweetCountSql = `
    SELECT COUNT(*)
    FROM v_tweet_details
    WHERE reply_to_tweet_id = :tweetId
      AND fn_can_view_tweet(:user_id, tweet_id) = 1
    `;

    const result = await connection.execute(getReplyTweetSql, {
      tweetId,
      user_id: user.userId,
      page,
      pageSize
    });

    // 获取总数
    const homeCountResult = await connection.execute(getReplyTweetCountSql, {
      tweetId,
      user_id: user.userId
    });

    // 提取总数
    const totalCount: number = homeCountResult.rows[0][0] as number;

    // 处理推文数据
    const tweets = await Promise.all(
      result.rows.map(async (row: TweetGetRepliesRow) => {
        // 读取CLOB内容
        let content = '';
        if (row[1] && typeof row[1].getData === 'function') {
          content = await row[1].getData();
        } else if (typeof row[1] === 'string') {
          content = row[1];
        }

        return {
          tweetId: row[0], // 推文ID
          content: content, // 推文内容（CLOB需转字符串）
          authorId: row[2], // 作者ID
          username: row[3], // 作者用户名
          displayName: row[4], // 作者显示名
          avatarUrl: row[5], // 作者头像
          isVerified: row[6], // 是否认证
          replyToTweetId: row[7], // 回复的推文ID
          retweetOfTweetId: row[8], // 转发的推文ID
          quoteTweetId: row[9], // 引用的推文ID
          isRetweet: row[10], // 是否为转发
          isQuoteTweet: row[11], // 是否为引用
          likesCount: row[12], // 点赞数
          retweetsCount: row[13], // 转发数
          repliesCount: row[14], // 回复数
          viewsCount: row[15], // 浏览量
          visibility: row[16], // 可见性
          language: row[17], // 语言
          createdAt: row[18], // 创建时间
          engagementScore: row[19], // 互动分数
          media: row[20], // 媒体文件数组
          rn: row[21]
        } as TweetGetRepliesItem;
      })
    );

    return {
      success: true,
      message: '推文获取成功',
      data: {
        page,
        pageSize,
        tweets,
        totalCount
      },
      code: 200,
      timestamp: new Date().toISOString()
    } as TweetRepliesResponse;
  } finally {
    await connection.close();
  }
});
