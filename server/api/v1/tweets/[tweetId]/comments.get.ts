export default defineEventHandler(async event => {
  // 获取当前登录用户信息
  const user: Auth = event.context.auth as Auth;
  // 获取 tweetId 路径参数
  const tweetId = getRouterParam(event, 'tweetId');

  // 获取 query 参数
  const query: TweetCommentsPayload = getQuery(event) as TweetCommentsPayload;

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
    const commentsSql = `
    SELECT *
    FROM (
        SELECT
            v.*,
            c.likes_count,
            ROW_NUMBER() OVER (
                ORDER BY
                    CASE WHEN :sort = 'newest' THEN v.created_at END DESC,
                    CASE WHEN :sort = 'oldest' THEN v.created_at END ASC,
                    CASE WHEN :sort = 'popular' THEN c.likes_count END DESC,
                    CASE WHEN :sort = 'popular' THEN v.created_at END DESC
            ) AS rn
        FROM v_tweet_comments v
        JOIN n_comments c ON v.comment_id = c.comment_id
        WHERE v.tweet_id = :tweet_id
    )
    WHERE rn > (:page - 1) * :pagesize
      AND rn <= :page * :pagesize
    ORDER BY rn;
    `;
    const commentsCountSql = `
    SELECT
      count(*) AS total_count
        FROM v_tweet_comments v
        JOIN n_comments c ON v.comment_id = c.comment_id
        WHERE v.tweet_id = :tweet_id
    `;

    const result = await connection.execute(commentsSql, {
      tweet_id: tweetId,
      page,
      pagesize: pageSize,
      sort: query.sort || 'newest' // 默认排序方式为 'newest'
    });

    // 获取总数
    const countResult = await connection.execute(commentsCountSql, {
      tweet_id: tweetId
    });

    // 提取总数
    const totalCount: number = countResult.rows[0][0] as number;

    // 处理点赞数据
    const likes: TweetGetReLikesItem[] = await Promise.all(
      result.rows.map(
        async (row: TweetGetReLikesRow) =>
          ({
            displayName: row[0],
            avatarUrl: row[1],
            likeType: row[2],
            rn: row[3]
          }) as TweetGetReLikesItem
      )
    );

    // 返回响应
    return {
      success: true,
      message: '获取成功',
      data: {
        page,
        pageSize,
        likes,
        totalCount
      },
      code: 200,
      timestamp: new Date().toISOString()
    } as TweetGetReLikesResponse;
  } finally {
    await connection.close();
  }
});
