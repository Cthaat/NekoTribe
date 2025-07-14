// 获取话题统计信息的API
export default defineEventHandler(
  async (
    event
  ): Promise<HashtagStatisticsSuccessResponse> => {
    const query = getQuery(event);
    const type = (query.type as string) || 'all'; // all, trending, statistics
    const limit = Math.min(
      100,
      Math.max(1, parseInt(query.limit as string) || 20)
    );

    // 验证参数
    if (!['all', 'trending', 'statistics'].includes(type)) {
      throw createError({
        statusCode: 400,
        message: '无效的查询类型',
        data: {
          success: false,
          message:
            '查询类型必须是 all, trending 或 statistics',
          code: 400,
          timestamp: new Date().toISOString()
        } as HashtagStatisticsErrorResponse
      });
    }

    const getOracleConnection =
      event.context.getOracleConnection;
    const connection = await getOracleConnection();

    try {
      let sql = '';
      let countSql = '';
      let params = { limit };

      switch (type) {
        case 'trending':
          sql = `
          SELECT * FROM v_hashtag_trends 
          WHERE trend_category IN ('viral', 'hot', 'trending')
          ORDER BY momentum_rank
          FETCH FIRST :limit ROWS ONLY
        `;
          countSql = `
          SELECT COUNT(*) as total FROM v_hashtag_trends 
          WHERE trend_category IN ('viral', 'hot', 'trending')
        `;
          break;

        case 'statistics':
          sql = `
          SELECT * FROM v_hashtag_statistics 
          ORDER BY total_tweets DESC
          FETCH FIRST :limit ROWS ONLY
        `;
          countSql = `
          SELECT COUNT(*) as total FROM v_hashtag_statistics
        `;
          break;

        default:
          sql = `
          SELECT * FROM v_hashtag_statistics 
          ORDER BY daily_hotness_score DESC
          FETCH FIRST :limit ROWS ONLY
        `;
          countSql = `
          SELECT COUNT(*) as total FROM v_hashtag_statistics
        `;
      }

      // 同时执行数据查询和总数查询
      const [result, countResult] = await Promise.all([
        connection.execute(sql, params),
        connection.execute(countSql, {})
      ]);

      // 处理数据
      let hashtags:
        | HashtagStatisticsItem[]
        | HashtagTrendsItem[] = [];

      if (type === 'trending') {
        hashtags =
          result.rows?.map((row: HashtagTrendsRow) => ({
            hashtagId: row[0],
            tagName: row[1],
            tagNameLower: row[2],
            isTrending: row[3],
            tweetsLast24h: row[4],
            tweetsLast7d: row[5],
            tweetsLast30d: row[6],
            likesLast24h: row[7],
            retweetsLast24h: row[8],
            repliesLast24h: row[9],
            uniqueAuthorsLast24h: row[10],
            uniqueAuthorsLast7d: row[11],
            dailyVelocity: row[12],
            weeklyVelocity: row[13],
            momentumScore: row[14],
            dailyRank: row[15],
            weeklyRank: row[16],
            momentumRank: row[17],
            trendCategory: row[18],
            calculatedAt: row[19]
          })) || [];
      } else {
        hashtags =
          result.rows?.map((row: HashtagStatisticsRow) => ({
            hashtagId: row[0],
            tagName: row[1],
            tagNameLower: row[2],
            usageCount: row[3],
            trendingScore: row[4],
            isTrending: row[5],
            createdAt: row[6],
            updatedAt: row[7],
            totalTweets: row[8],
            totalAuthors: row[9],
            totalLikes: row[10],
            totalRetweets: row[11],
            totalReplies: row[12],
            totalViews: row[13],
            avgEngagementScore: row[14],
            tweetsToday: row[15],
            tweetsThisWeek: row[16],
            tweetsThisMonth: row[17],
            likesToday: row[18],
            retweetsToday: row[19],
            repliesToday: row[20],
            activeAuthorsToday: row[21],
            activeAuthorsThisWeek: row[22],
            weeklyGrowthRate: row[23],
            avgLikeRate: row[24],
            avgRetweetRate: row[25],
            dailyHotnessScore: row[26],
            latestTweetId: row[27],
            latestTweetCreatedAt: row[28],
            latestTweetAuthorId: row[29],
            hottestTweetId: row[30],
            hottestTweetEngagementScore: row[31]
          })) || [];
      }

      const total =
        (countResult.rows?.[0]?.[0] as number) || 0;

      return {
        success: true,
        message: '获取话题统计信息成功',
        data: {
          hashtags,
          type,
          limit,
          total
        },
        code: 200,
        timestamp: new Date().toISOString()
      };
    } catch (error: any) {
      console.error('获取话题统计信息失败:', error);

      throw createError({
        statusCode: 500,
        message: '获取话题统计信息失败',
        data: {
          success: false,
          message: error.message || '服务器内部错误',
          code: 500,
          timestamp: new Date().toISOString()
        } as HashtagStatisticsErrorResponse
      });
    } finally {
      await connection.close();
    }
  }
);
