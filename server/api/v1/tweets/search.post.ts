export default defineEventHandler(
  async (event): Promise<TweetSearchSuccessResponse> => {
    // 获取当前登录用户信息
    const user: Auth = event.context.auth as Auth;

    // 获取 query 参数
    const query: TweetSearchPayload = getQuery(event) as TweetSearchPayload;

    const { q, page = 1, pageSize = 10, sort = 'popular' } = query;

    // 验证搜索关键词
    if (!q || q.trim() === '') {
      throw createError({
        statusCode: 400,
        message: '缺少搜索关键词',
        data: {
          success: false,
          message: '缺少搜索关键词',
          code: 400,
          timestamp: new Date().toISOString()
        } as TweetSearchErrorResponse
      });
    }

    // 验证分页参数
    const validPage = Math.max(1, parseInt(page.toString()) || 1);
    const validPageSize = Math.min(
      50,
      Math.max(1, parseInt(pageSize.toString()) || 10)
    );

    // 验证排序参数
    const validSort = ['popular', 'newest', 'oldest'].includes(sort)
      ? sort
      : 'popular';

    const getOracleConnection = event.context.getOracleConnection;
    const connection = await getOracleConnection();

    try {
      // 构建排序子句
      let orderByClause = '';
      switch (validSort) {
        case 'newest':
          orderByClause = 'ORDER BY created_at DESC';
          break;
        case 'oldest':
          orderByClause = 'ORDER BY created_at ASC';
          break;
        case 'popular':
        default:
          orderByClause = 'ORDER BY engagement_score DESC, created_at DESC';
          break;
      }

      // 搜索推文的SQL - 添加CLOB转换
      const tweetSearchSql = `
      SELECT *
      FROM (
          SELECT
                v.tweet_id,
                TO_CHAR(v.content) as content,  -- 将CLOB转换为VARCHAR2
                v.author_id,
                v.username,
                v.display_name,
                v.avatar_url,
                v.is_verified,
                v.likes_count,
                v.retweets_count,
                v.replies_count,
                v.views_count,
                v.visibility,
                v.created_at,
                v.reply_to_tweet_id,
                v.retweet_of_tweet_id,
                v.quote_tweet_id,
                v.engagement_score,
                v.timeline_type,
                v.is_from_following,
                v.is_deleted,
              ROW_NUMBER() OVER (${orderByClause}) AS rn
          FROM v_comprehensive_timeline v
          WHERE (
              v.visibility = 'public' OR v.visibility IS NULL
          )
          AND v.is_deleted = 0
          AND (
              LOWER(TO_CHAR(v.content)) LIKE LOWER('%' || :q || '%')  -- CLOB转换后搜索
              OR EXISTS (
                  SELECT 1
                  FROM n_tweet_hashtags nth
                  JOIN n_hashtags h ON nth.hashtag_id = h.hashtag_id
                  WHERE nth.tweet_id = v.tweet_id
                  AND h.tag_name_lower LIKE LOWER('%' || :q || '%')
              )
              OR LOWER(v.display_name) LIKE LOWER('%' || :q || '%')
              OR LOWER(v.username) LIKE LOWER('%' || :q || '%')
          )
      )
      WHERE rn > (:page - 1) * :pageSize
        AND rn <= :page * :pageSize
      ${orderByClause}
    `;

      // 获取搜索结果总数的SQL - 同样添加CLOB转换
      const countSql = `
      SELECT COUNT(*) as total
      FROM v_comprehensive_timeline v
      WHERE (
          v.visibility = 'public' OR v.visibility IS NULL
      )
      AND v.is_deleted = 0
      AND (
          LOWER(TO_CHAR(v.content)) LIKE LOWER('%' || :q || '%')  -- CLOB转换后搜索
          OR EXISTS (
              SELECT 1
              FROM n_tweet_hashtags nth
              JOIN n_hashtags h ON nth.hashtag_id = h.hashtag_id
              WHERE nth.tweet_id = v.tweet_id
              AND h.tag_name_lower LIKE LOWER('%' || :q || '%')
          )
          OR LOWER(v.display_name) LIKE LOWER('%' || :q || '%')
          OR LOWER(v.username) LIKE LOWER('%' || :q || '%')
      )
    `;

      // 执行查询
      const [tweetResult, countResult] = await Promise.all([
        connection.execute(tweetSearchSql, {
          q: q.trim(),
          page: validPage,
          pageSize: validPageSize
        }),
        connection.execute(countSql, {
          q: q.trim()
        })
      ]);

      // 处理搜索结果
      const tweets: TweetSearchItem[] =
        tweetResult.rows?.map((row: TweetSearchRow) => ({
          tweetId: row[0].toString(), // TWEET_ID
          content: row[1], // CONTENT (已转换为字符串)
          authorId: row[2].toString(), // AUTHOR_ID
          username: row[3], // USERNAME
          displayName: row[4], // DISPLAY_NAME
          avatarUrl: row[5], // AVATAR_URL
          isVerified: row[6], // IS_VERIFIED
          likesCount: row[7], // LIKES_COUNT
          retweetsCount: row[8], // RETWEETS_COUNT
          repliesCount: row[9], // REPLIES_COUNT
          viewsCount: row[10], // VIEWS_COUNT
          visibility: row[11], // VISIBILITY
          createdAt: row[12], // CREATED_AT
          replyToTweetId: row[13] ? row[13].toString() : '', // REPLY_TO_TWEET_ID
          retweetOfTweetId: row[14] ? row[14].toString() : '', // RETWEET_OF_TWEET_ID
          quoteTweetId: row[15] ? row[15].toString() : '', // QUOTE_TWEET_ID
          engagementScore: row[16], // ENGAGEMENT_SCORE
          timelineType: row[17], // TIMELINE_TYPE
          isFromFollowing: row[18], // IS_FROM_FOLLOWING
          rn: row[20] // RN (注意索引位置)
        })) || [];

      const totalCount = (countResult.rows?.[0]?.[0] as number) || 0;

      return {
        success: true,
        message: '搜索推文成功',
        data: {
          sort: validSort,
          page: validPage,
          pageSize: validPageSize,
          tweets,
          totalCount,
          query: q.trim()
        },
        code: 200,
        timestamp: new Date().toISOString()
      };
    } catch (error: any) {
      console.error('搜索推文失败:', error);

      throw createError({
        statusCode: 500,
        message: '搜索推文失败',
        data: {
          success: false,
          message: error.message || '服务器内部错误',
          code: 500,
          timestamp: new Date().toISOString()
        } as TweetSearchErrorResponse
      });
    } finally {
      await connection.close();
    }
  }
);
