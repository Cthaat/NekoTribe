import oracledb from 'oracledb';

export default defineEventHandler(async event => {
  const user: Auth = event.context.auth as Auth;

  // 获取 query 参数
  const query: TweetListPayload = getQuery(event) as TweetListPayload;

  // 提取参数
  const { type, page, pageSize, userId } = query;

  const getOracleConnection = event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    switch (type) {
      case 'home':
        // 获取首页推文
        const homeSql = `
        SELECT *
        FROM (
            SELECT
                v.*,
                ROW_NUMBER() OVER (
                    ORDER BY v.created_at DESC
                ) AS rn
            FROM v_comprehensive_timeline v
            WHERE (v.author_id = :user_id OR v.is_from_following = 1)
              AND fn_can_view_tweet(:user_id, v.tweet_id) = 1
              AND is_deleted = 0
        )
        WHERE rn <= 50 -- 分页限制
        ORDER BY created_at DESC;
        `;
        break;
      case 'user':
        if (!userId) {
          throw createError({
            statusCode: 400,
            message: 'User ID is required for user tweets',
            data: {
              success: false,
              message: 'User ID is required for user tweets',
              code: 400,
              timestamp: new Date().toISOString()
            } as ErrorResponse
          });
        }
        const userSql = `
        SELECT *
        FROM v_comprehensive_timeline v
        WHERE v.author_id = :target_user_id
          AND fn_can_view_tweet(:user_id, v.tweet_id) = 1
          AND is_deleted = 0
        ORDER BY v.created_at DESC;
        `;
        // 获取用户推文
        break;
      case 'my_tweets':
        // 获取我的推文
        const myTweetsSql = `
        SELECT *
        FROM v_comprehensive_timeline v
        WHERE v.author_id = :user_id
            AND is_deleted = 0
        ORDER BY v.created_at DESC;
        `;
        break;
      case 'mention':
        // 获取提及我的推文
        const mentionSql = `
        SELECT *
        FROM v_comprehensive_timeline v
        WHERE v.tweet_id IN (
            SELECT c.tweet_id
            FROM n_comments c
            WHERE c.user_id = :user_id
            AND fn_can_view_tweet(:user_id, v.tweet_id) = 1
            AND is_deleted = 0
        )
        ORDER BY v.created_at DESC;
        `;
        break;
      case 'trending':
        // 获取热门推文
        const trendingSql = `
        SELECT *
        FROM v_comprehensive_timeline v
        WHERE fn_can_view_tweet(:user_id, v.tweet_id) = 1
          AND v.created_at > SYSDATE - 7 -- 最近7天
        ORDER BY v.engagement_score DESC, v.created_at DESC
        FETCH FIRST 50 ROWS ONLY;
        `;
        break;
      default:
        throw createError({
          statusCode: 400,
          message: 'Invalid tweet type',
          data: {
            success: false,
            message: 'Invalid tweet type',
            code: 400,
            timestamp: new Date().toISOString()
          } as ErrorResponse
        });
    }
  } finally {
    await connection.close();
  }
});
