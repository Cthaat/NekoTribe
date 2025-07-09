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
        )
        WHERE rn > (:page - 1) * :pagesize 
          AND rn <= :page * :pagesize
        ORDER BY created_at DESC
        `;
        // 获取首页推文
        const result = await connection.execute(homeSql, {
          user_id: user.userId,
          page,
          pagesize: pageSize
        });
        console.log('Home Tweets Result:', result.rows);

        const tweets = result.rows.map(async (row: TweetRow) => {
          // 读取CLOB内容
          let content = '';
          if (row[1] && typeof row[1].getData === 'function') {
            content = await row[1].getData();
          } else if (typeof row[1] === 'string') {
            content = row[1];
          }
          return {
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
          } as TweetItem;
        });
        return {
          success: true,
          message: 'Home tweets fetched successfully',
          data: {
            tweets: await Promise.all(tweets)
          },
          code: 200,
          timestamp: new Date().toISOString()
        } as TweetListResponse;
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
        FROM (
            SELECT
                v.*,
                ROW_NUMBER() OVER (
                    ORDER BY v.created_at DESC
                ) AS rn
            FROM v_comprehensive_timeline v
            WHERE v.author_id = :target_user_id
              AND fn_can_view_tweet(:user_id, v.tweet_id) = 1
        )
        WHERE rn > (:page - 1) * :pagesize 
          AND rn <= :page * :pagesize
        ORDER BY created_at DESC
        `;
        // 获取用户推文
        break;
      case 'my_tweets':
        // 获取我的推文
        const myTweetsSql = `
        SELECT *
        FROM (
            SELECT
                v.*,
                ROW_NUMBER() OVER (
                    ORDER BY v.created_at DESC
                ) AS rn
            FROM v_comprehensive_timeline v
            WHERE v.author_id = :user_id
        )
        WHERE rn > (:page - 1) * :pagesize 
          AND rn <= :page * :pagesize
        ORDER BY created_at DESC
        `;
        break;
      case 'mention':
        // 获取提及我的推文
        const mentionSql = `
        SELECT *
        FROM (
            SELECT
                v.*,
                ROW_NUMBER() OVER (
                    ORDER BY v.created_at DESC
                ) AS rn
            FROM v_comprehensive_timeline v
            WHERE v.tweet_id IN (
                SELECT tm.tweet_id
                FROM n_tweet_mentions tm
                WHERE tm.mentioned_user_id = :user_id
            )
            AND fn_can_view_tweet(:user_id, v.tweet_id) = 1
        )
        WHERE rn > (:page - 1) * :pagesize 
          AND rn <= :page * :pagesize
        ORDER BY created_at DESC
        `;
        break;
      case 'trending':
        // 获取热门推文
        const trendingSql = `
        SELECT *
        FROM (
            SELECT
                v.*,
                ROW_NUMBER() OVER (
                    ORDER BY v.engagement_score DESC, v.created_at DESC
                ) AS rn
            FROM v_comprehensive_timeline v
            WHERE fn_can_view_tweet(:user_id, v.tweet_id) = 1
              AND v.created_at > SYSDATE - 7 -- 最近7天
        )
        WHERE rn > (:page - 1) * :pagesize 
          AND rn <= :page * :pagesize
        ORDER BY engagement_score DESC, created_at DESC
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
