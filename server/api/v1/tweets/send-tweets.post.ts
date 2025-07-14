import oracledb from 'oracledb';

export default defineEventHandler(async event => {
  const body = await readBody<TweetSendPayload>(event);
  const user: Auth = event.context.auth as Auth;

  const getOracleConnection =
    event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    const spSql = `
    BEGIN
        sp_create_tweet(
          :p_author_id,
          :p_content,
          :p_reply_to_tweet_id,
          :p_retweet_of_tweet_id,
          :p_quote_tweet_id,
          :p_visibility,
          :p_hashtags,
          :p_mentions,
          :p_tweet_id,
          :p_result
        );
      END;
    `;
    // 调用存储过程
    const result = await connection.execute(
      spSql,
      {
        p_author_id: user.userId,
        p_content: body.content,
        p_reply_to_tweet_id: body.replyToTweetId ?? null,
        p_retweet_of_tweet_id:
          body.retweetOfTweetId ?? null,
        p_quote_tweet_id: body.quoteTweetId ?? null,
        p_visibility: body.visibility ?? 'public',
        p_hashtags: body.hashtags ?? null,
        p_mentions: body.mentions ?? null,
        p_tweet_id: {
          dir: oracledb.BIND_OUT,
          type: oracledb.NUMBER
        },
        p_result: {
          dir: oracledb.BIND_OUT,
          type: oracledb.STRING,
          maxSize: 200
        }
      },
      { autoCommit: true }
    );

    return {
      success: true,
      message: result.outBinds.p_result,
      data: {
        tweetId: result.outBinds.p_tweet_id
      },
      code: 200,
      timestamp: new Date().toISOString()
    };
  } catch (err) {
    const error = err as any;
    throw createError({
      statusCode: error.code || 500,
      message: '推文发布失败',
      data: {
        success: false,
        message: '推文发布失败，请稍后重试或联系管理员',
        code: error.code || 500,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  } finally {
    await connection.close();
  }
});
