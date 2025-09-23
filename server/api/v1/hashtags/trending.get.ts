export default defineEventHandler(
  async (
    event
  ): Promise<TrendingHashtagsSuccessResponse> => {
    const getOracleConnection =
      event.context.getOracleConnection;
    const connection = await getOracleConnection();

    try {
      // 获取热门话题
      const result = await connection.execute(
        `SELECT hashtag_id, tag_name, usage_count, trending_score
       FROM n_hashtags 
       WHERE is_trending = 1 
       ORDER BY trending_score DESC
       FETCH FIRST 15 ROWS ONLY`
      );

      // 类型转换，确保数据结构正确
      const trendingHashtags: TrendingHashtag[] =
        result.rows?.map(
          (row: TrendingHashtagsDataRow) => ({
            hashtag_id: row[0] as number,
            tag_name: row[1] as string,
            usage_count: row[2] as number,
            trending_score: row[3] as number
          })
        ) || [];

      return {
        success: true,
        message: '获取热门话题成功',
        data: {
          trending_hashtags: trendingHashtags,
          updated_at: new Date().toISOString()
        },
        code: 200
      } as TrendingHashtagsSuccessResponse;
    } catch (error: any) {
      console.error('获取热门话题失败:', error);

      throw createError({
        statusCode: 500,
        message: '获取热门话题失败',
        data: {
          success: false,
          message: error.message || '服务器内部错误',
          code: 500
        } as TrendingHashtagsErrorResponse
      });
    } finally {
      await connection.close();
    }
  }
);
