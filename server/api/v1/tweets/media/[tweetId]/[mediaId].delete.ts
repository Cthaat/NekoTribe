import {
  deleteStorageReference
} from '~/server/storage';

function deleteError(
  statusCode: number,
  message: string,
  code = statusCode
) {
  return createError({
    statusCode,
    statusMessage:
      statusCode >= 500
        ? 'Internal Server Error'
        : 'Bad Request',
    data: {
      success: false,
      message,
      code,
      timestamp: new Date().toISOString()
    } as ErrorResponse
  });
}

export default defineEventHandler(async event => {
  const user: Auth = event.context.auth as Auth;
  const tweetId = getRouterParam(event, 'tweetId');
  const mediaId = getRouterParam(event, 'mediaId');

  if (!tweetId) {
    throw deleteError(400, '缺少推文ID');
  }

  if (!mediaId) {
    throw deleteError(400, '缺少媒体ID');
  }

  const getOracleConnection =
    event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    const ownershipResult = await connection.execute(
      `
      SELECT COUNT(*) AS count
      FROM n_tweets
      WHERE tweet_id = :tweetId AND author_id = :userId
      `,
      {
        tweetId,
        userId: user.userId
      }
    );

    const ownsTweet = Number(
      ownershipResult.rows?.[0]?.[0] || 0
    );
    if (ownsTweet === 0) {
      throw deleteError(403, '无权删除媒体', 403);
    }

    const mediaResult = await connection.execute(
      `
      SELECT file_path, thumbnail_path
      FROM n_media
      WHERE media_id = :mediaId AND user_id = :userId
      `,
      {
        mediaId,
        userId: user.userId
      }
    );

    if (!mediaResult.rows || mediaResult.rows.length === 0) {
      throw deleteError(404, '媒体文件不存在', 404);
    }

    const mediaRow = mediaResult.rows[0] as [
      string | null,
      string | null
    ];
    const deleteResult = await connection.execute(
      `
      DELETE FROM n_media
      WHERE user_id = :userId AND media_id = :mediaId
      `,
      {
        userId: user.userId,
        mediaId
      },
      {
        autoCommit: true
      }
    );

    if (
      !deleteResult.rowsAffected ||
      deleteResult.rowsAffected === 0
    ) {
      throw deleteError(
        404,
        '媒体文件不存在或已被删除',
        404
      );
    }

    await deleteStorageReference({
      publicUrl: mediaRow[0]
    });
    await deleteStorageReference({
      publicUrl: mediaRow[1]
    });

    return {
      success: true,
      message: '媒体删除成功',
      data: {
        deletedMediaId: mediaId,
        deletedFiles: mediaRow.filter(Boolean).length,
        timestamp: new Date().toISOString()
      },
      code: 200
    };
  } catch (error) {
    if (
      typeof error === 'object' &&
      error !== null &&
      'statusCode' in error
    ) {
      throw error;
    }

    throw deleteError(500, '删除媒体时发生错误', 500);
  } finally {
    await connection.close();
  }
});
