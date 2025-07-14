export default defineEventHandler(async event => {
  // 获取当前登录用户信息
  const user: Auth = event.context.auth as Auth;
  // 获取 tweetId 路径参数
  const tag = getRouterParam(event, 'tag');

  // 获取 query 参数
  const query: TweetListPayload = getQuery(
    event
  ) as TweetListPayload;

  const {
    page = 1,
    pageSize = 10,
    sort = 'popular'
  } = query;

  if (!tag) {
    throw createError({
      statusCode: 400,
      message: '缺少推文tag',
      data: {
        success: false,
        message: '缺少推文tag',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  const getOracleConnection =
    event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    const tagSql = `
        SELECT *
        FROM (
            SELECT
                v.*,
                ROW_NUMBER() OVER (
                    ORDER BY
                            CASE WHEN :sort = 'newest' THEN v.created_at END DESC,
                            CASE WHEN :sort = 'oldest' THEN v.created_at END ASC,
                            CASE WHEN :sort = 'popular' THEN v.engagement_score END DESC,
                            CASE WHEN :sort = 'popular' THEN v.created_at END DESC
                ) AS rn
            FROM v_comprehensive_timeline v
            JOIN n_tweet_hashtags nth ON v.tweet_id = nth.tweet_id
            JOIN n_hashtags h ON nth.hashtag_id = h.hashtag_id
            WHERE h.hashtag_id= LOWER(:tag)
              AND (v.visibility = :visibility OR v.visibility IS NULL)
              AND v.created_at > SYSDATE - 7
        )
        WHERE rn > (:page - 1) * :pagesize
          AND rn <= :page * :pagesize
        `;

    // 获取首页推文总数
    const tagCountSql = `
        SELECT COUNT(*)
        FROM v_comprehensive_timeline v
        JOIN n_tweet_hashtags nth ON v.tweet_id = nth.tweet_id
        JOIN n_hashtags h ON nth.hashtag_id = h.hashtag_id
        WHERE h.hashtag_id = LOWER(:tag)
          AND (v.visibility = :visibility OR v.visibility IS NULL)
        `;

    // 获取首页推文
    const tagResult = await connection.execute(tagSql, {
      sort: sort || 'popular',
      tag,
      visibility: 'public',
      page,
      pagesize: pageSize
    });

    // 获取总数
    const tagCountResult = await connection.execute(
      tagCountSql,
      {
        tag,
        visibility: 'public'
      }
    );

    // 提取总数
    const totalCount = tagCountResult.rows[0][0];

    // 处理推文数据
    const tweets = await Promise.all(
      tagResult.rows.map(async (row: TweetRow) => {
        return {
          tweetId: row[0],
          authorId: row[1],
          username: row[2],
          displayName: row[3],
          avatarUrl: row[4],
          isVerified: row[5],
          likesCount: row[6],
          retweetsCount: row[7],
          repliesCount: row[8],
          viewsCount: row[9],
          visibility: row[10],
          createdAt: row[11],
          replyToTweetId: row[12],
          retweetOfTweetId: row[13],
          quoteTweetId: row[14],
          engagementScore: row[15],
          timelineType: row[16],
          isFromFollowing: row[17],
          rn: row[18]
        } as TweetItem;
      })
    );

    return {
      success: true,
      message: '获取推文列表成功',
      data: {
        sort: sort || 'popular',
        page,
        pageSize,
        tweets,
        totalCount
      },
      code: 200,
      timestamp: new Date().toISOString()
    } as TagTweetListResponse;
  } finally {
    await connection.close();
  }
});
