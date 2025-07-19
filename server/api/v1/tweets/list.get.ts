import oracledb from 'oracledb';

export default defineEventHandler(async event => {
  const user: Auth = event.context.auth as Auth;

  // 获取 query 参数
  const query: TweetListPayload = getQuery(
    event
  ) as TweetListPayload;

  // 提取参数
  const { type, page, pageSize, userId } = query;

  const getOracleConnection =
    event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    // 推文列表
    let tweets: TweetItem[] = [];

    // 文章总数
    let totalCount: number = 0;

    // 根据 type 获取不同的推文列表
    switch (type) {
      case 'home':
        // 获取首页推文
        const homeSql = `
        SELECT *
        FROM (
            SELECT
                v.tweet_id,
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
                ROW_NUMBER() OVER (
                    ORDER BY v.created_at DESC
                ) AS rn,
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
            FROM v_comprehensive_timeline v
            WHERE (v.author_id = :user_id OR v.is_from_following = 1)
              AND fn_can_view_tweet(:user_id, v.tweet_id) = 1
        )
        WHERE rn > (:page - 1) * :pagesize 
          AND rn <= :page * :pagesize
        ORDER BY created_at DESC
        `;

        // 获取首页推文总数
        const homeCountSql = `
        SELECT COUNT(*)
        FROM v_comprehensive_timeline v
        WHERE (v.author_id = :user_id OR v.is_from_following = 1)
          AND fn_can_view_tweet(:user_id, v.tweet_id) = 1
        `;

        // 获取首页推文
        const homeResult = await connection.execute(
          homeSql,
          {
            user_id: user.userId,
            page,
            pagesize: pageSize
          }
        );

        // 获取总数
        const homeCountResult = await connection.execute(
          homeCountSql,
          {
            user_id: user.userId
          }
        );

        // 提取总数
        totalCount = homeCountResult.rows[0][0];

        // 处理推文数据
        tweets = await Promise.all(
          homeResult.rows.map(async (row: TweetRow) => {
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
              rn: row[18],
              isLikedByUser: row[19],
              isBookmarkedByUser: row[20]
            } as TweetItem;
          })
        );
        break;
      case 'user':
        // 检查 userId 是否存在
        if (!userId) {
          throw createError({
            statusCode: 400,
            message: 'User ID is required for user tweets',
            data: {
              success: false,
              message:
                'User ID is required for user tweets',
              code: 400,
              timestamp: new Date().toISOString()
            } as ErrorResponse
          });
        }

        // 获取用户推文
        const userSql = `
        SELECT *
        FROM (
            SELECT
                v.tweet_id,
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
                ROW_NUMBER() OVER (
                    ORDER BY v.created_at DESC
                ) AS rn,
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
            FROM v_comprehensive_timeline v
            WHERE v.author_id = :target_user_id
              AND fn_can_view_tweet(:user_id, v.tweet_id) = 1
        )
        WHERE rn > (:page - 1) * :pagesize 
          AND rn <= :page * :pagesize
        ORDER BY created_at DESC
        `;

        // 获取用户推文总数
        const userCountSql = `
          SELECT COUNT(*)
          FROM v_comprehensive_timeline v
          WHERE v.author_id = :target_user_id
            AND fn_can_view_tweet(:user_id, v.tweet_id) = 1
        `;

        // 获取用户推文
        const userResult = await connection.execute(
          userSql,
          {
            user_id: user.userId,
            target_user_id: userId,
            page,
            pagesize: pageSize
          }
        );

        // 获取用户推文总数
        const userCountResult = await connection.execute(
          userCountSql,
          {
            user_id: user.userId,
            target_user_id: userId
          }
        );

        // 提取总数
        totalCount = userCountResult.rows[0][0];

        // 处理推文数据
        tweets = await Promise.all(
          userResult.rows.map(async (row: TweetRow) => {
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
              rn: row[18],
              isLikedByUser: row[19],
              isBookmarkedByUser: row[20]
            } as TweetItem;
          })
        );

        break;
      case 'my_tweets':
        // 获取我的推文
        const myTweetsSql = `
        SELECT *
        FROM (
            SELECT
                v.tweet_id,
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
                ROW_NUMBER() OVER (
                    ORDER BY v.created_at DESC
                ) AS rn,
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
            FROM v_comprehensive_timeline v
            WHERE v.author_id = :user_id
        )
        WHERE rn > (:page - 1) * :pagesize 
          AND rn <= :page * :pagesize
        ORDER BY created_at DESC
        `;

        // 获取我的推文总数
        const myTweetsCountSql = `
          SELECT COUNT(*)
          FROM v_comprehensive_timeline v
          WHERE v.author_id = :user_id
        `;

        // 获取我的推文
        const myTweetsResult = await connection.execute(
          myTweetsSql,
          {
            user_id: user.userId,
            page,
            pagesize: pageSize
          }
        );

        // 获取我的推文总数
        const myTweetsCountResult =
          await connection.execute(myTweetsCountSql, {
            user_id: user.userId
          });

        // 提取总数
        totalCount = myTweetsCountResult.rows[0][0];

        // 处理推文数据
        tweets = await Promise.all(
          myTweetsResult.rows.map(async (row: TweetRow) => {
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
              rn: row[18],
              isLikedByUser: row[19],
              isBookmarkedByUser: row[20]
            } as TweetItem;
          })
        );
        break;
      case 'mention':
        // 获取提及我的推文
        const mentionSql = `
        SELECT *
        FROM (
            SELECT
                v.tweet_id,
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
                ROW_NUMBER() OVER (
                    ORDER BY v.created_at DESC
                ) AS rn,
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

        // 获取提及我的推文总数
        const mentionCountSql = `
          SELECT COUNT(*)
          FROM v_comprehensive_timeline v
          WHERE v.tweet_id IN (
              SELECT tm.tweet_id
              FROM n_tweet_mentions tm
              WHERE tm.mentioned_user_id = :user_id
          )
          AND fn_can_view_tweet(:user_id, v.tweet_id) = 1
        `;

        // 获取提及我的推文
        const mentionResult = await connection.execute(
          mentionSql,
          {
            user_id: user.userId,
            page,
            pagesize: pageSize
          }
        );

        // 获取提及我的推文总数
        const mentionCountResult = await connection.execute(
          mentionCountSql,
          {
            user_id: user.userId
          }
        );

        // 提取总数
        totalCount = mentionCountResult.rows[0][0];

        // 处理推文数据
        tweets = await Promise.all(
          mentionResult.rows.map(async (row: TweetRow) => {
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
              rn: row[18],
              isLikedByUser: row[19],
              isBookmarkedByUser: row[20]
            } as TweetItem;
          })
        );
        break;
      case 'trending':
        // 获取热门推文
        const trendingSql = `
        SELECT *
        FROM (
            SELECT
                v.tweet_id,
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
                ROW_NUMBER() OVER (
                    ORDER BY v.engagement_score DESC, v.created_at DESC
                ) AS rn,
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
            FROM v_comprehensive_timeline v
            WHERE v.visibility = :visibility
              AND v.created_at > SYSDATE - 7 -- 最近7天
        )
        WHERE rn > (:page - 1) * :pagesize 
          AND rn <= :page * :pagesize
        ORDER BY engagement_score DESC, created_at DESC
        `;

        // 获取热门推文总数
        const trendingCountSql = `
        SELECT COUNT(*)
        FROM v_comprehensive_timeline v
        WHERE v.visibility = :visibility
        `;

        // 获取热门推文
        const trendingResult = await connection.execute(
          trendingSql,
          {
            page,
            pagesize: pageSize,
            visibility: 'public' // 只获取公开可见的推文
          }
        );

        // 获取热门推文总数
        const trendingCountResult =
          await connection.execute(trendingCountSql, {
            visibility: 'public' // 只获取公开可见的推文
          });

        // 提取总数
        totalCount = trendingCountResult.rows[0][0];

        // 处理推文数据
        tweets = await Promise.all(
          trendingResult.rows.map(async (row: TweetRow) => {
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
              rn: row[18],
              isLikedByUser: row[19],
              isBookmarkedByUser: row[20]
            } as TweetItem;
          })
        );
        break;
      case 'bookmark':
        // 获取我的推文
        const bookmarkSql = `
        SELECT *
        FROM (
            SELECT
                v.tweet_id,
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
                ROW_NUMBER() OVER (ORDER BY b.created_at DESC) AS rn,
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
            FROM v_comprehensive_timeline v
            JOIN n_bookmarks b ON v.tweet_id = b.tweet_id
            WHERE b.user_id = :user_id
              AND fn_can_view_tweet(:user_id, v.tweet_id) = 1
        )
        WHERE rn > (:page - 1) * :pagesize
          AND rn <= :page * :pagesize
        ORDER BY created_at DESC
        `;

        // 获取我的推文总数
        const bookmarkCountSql = `
          SELECT
            COUNT(*)
            FROM v_comprehensive_timeline v
            JOIN n_bookmarks b ON v.tweet_id = b.tweet_id
            WHERE b.user_id = :user_id
              AND fn_can_view_tweet(:user_id, v.tweet_id) = 1
        `;

        // 获取我的推文
        const bookmarkResult = await connection.execute(
          bookmarkSql,
          {
            user_id: user.userId,
            page,
            pagesize: pageSize
          }
        );

        // 获取我的推文总数
        const bookmarkCountResult =
          await connection.execute(bookmarkCountSql, {
            user_id: user.userId
          });

        // 提取总数
        totalCount = bookmarkCountResult.rows[0][0];

        // 处理推文数据
        tweets = await Promise.all(
          bookmarkResult.rows.map(async (row: TweetRow) => {
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
              rn: row[18],
              isLikedByUser: row[19],
              isBookmarkedByUser: row[20]
            } as TweetItem;
          })
        );
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

    return {
      success: true,
      message: '获取推文列表成功',
      data: {
        type,
        page,
        pageSize,
        tweets,
        totalCount
      },
      code: 200,
      timestamp: new Date().toISOString()
    } as TweetListResponse;
  } finally {
    await connection.close();
  }
});
