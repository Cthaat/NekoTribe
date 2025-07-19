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

  const getOracleConnection =
    event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    const getTweetSql = `
    SELECT
    tweet_id,
    content,
    author_id,
    author_username,
    author_display_name,
    author_avatar,
    author_verified,
    reply_to_tweet_id,
    retweet_of_tweet_id,
    quote_tweet_id,
    is_retweet,
    is_quote_tweet,
    likes_count,
    retweets_count,
    replies_count,
    views_count,
    visibility,
    language,
    created_at,
    engagement_score,
    media_files,
    media_thumbnails,
    CASE
    WHEN EXISTS (SELECT 1 FROM n_likes l WHERE l.tweet_id = v.tweet_id AND l.user_id = :user_id)
    THEN 1
    ELSE 0
    END AS is_liked_by_user,

    CASE
    WHEN EXISTS (SELECT 1 FROM n_bookmarks b WHERE b.tweet_id = v.tweet_id AND b.user_id = :user_id)
    THEN 1
    ELSE 0
    END AS is_booked_by_user
    FROM v_tweet_details v
    WHERE tweet_id = :tweetId
      AND fn_can_view_tweet(:user_id, tweet_id) = 1
    `;

    const result = await connection.execute(getTweetSql, {
      tweetId,
      user_id: user.userId
    });

    const rows: TweetGetRow[] =
      result.rows as TweetGetRow[];
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

    const row: TweetGetRow = rows[0] as TweetGetRow;
    // 读取CLOB内容
    let content = '';
    if (row[1] && typeof row[1].getData === 'function') {
      content = await row[1].getData();
    } else if (typeof row[1] === 'string') {
      content = row[1];
    }

    const tweet: TweetGetItem = {
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
      mediaFiles: row[20], // 媒体文件数组
      mediaThumbnails: row[21], // 媒体缩略图
      isLikedByUser: row[22], // 用户是否点赞
      isBookmarkedByUser: row[23] // 用户是否收藏
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
