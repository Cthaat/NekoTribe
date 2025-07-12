export default defineEventHandler(async event => {
  // 获取当前登录用户信息
  const user: Auth = event.context.auth as Auth;

  // 获取 query 参数
  const query: SearchPayload = getQuery(event) as SearchPayload;

  const { q, limit = 10 } = query;

  if (!q) {
    throw createError({
      statusCode: 400,
      message: '缺少搜索关键词',
      data: {
        success: false,
        message: '缺少搜索关键词',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  const getOracleConnection = event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    const tagSearchSql = `
        SELECT
            hashtag_id,
            tag_name,
            tag_name_lower,
            usage_count,
            trending_score,
            is_trending,
            created_at,
            updated_at,
            CASE
                WHEN tag_name_lower = LOWER(:q) THEN 100
                WHEN tag_name_lower LIKE LOWER(:q || '%') THEN 90
                WHEN tag_name_lower LIKE LOWER('%' || :q || '%') THEN 80
                ELSE 0
            END AS relevance_score
        FROM n_hashtags
        WHERE (
            tag_name_lower = LOWER(:q)
            OR tag_name_lower LIKE LOWER(:q || '%')
            OR tag_name_lower LIKE LOWER('%' || :q || '%')
        )
        ORDER BY
            relevance_score DESC,
            is_trending DESC,
            usage_count DESC,
            trending_score DESC,
            created_at DESC
        FETCH FIRST :limit ROWS ONLY
        `;

    // 获取首页推文
    const tagResult = await connection.execute(tagSearchSql, {
      q,
      limit
    });

    // 处理搜索结果
    const hashtags =
      (await Promise.all(
        tagResult.rows.map(async (row: HashtagSearchItemRow) => {
          return {
            hashtagId: row[0],
            tagName: row[1],
            tagNameLower: row[2],
            usageCount: row[3],
            trendingScore: row[4],
            isTrending: row[5],
            createdAt: row[6],
            updatedAt: row[7],
            relevanceScore: row[8]
          } as HashtagSearchItem;
        })
      )) || [];

    return {
      success: true,
      message: '搜索成功',
      data: {
        hashtags,
        query: q,
        limit
      },
      code: 200,
      timestamp: new Date().toISOString()
    } as HashtagSearchResponse;
  } finally {
    await connection.close();
  }
});
