import oracledb from 'oracledb';
import fs from 'fs';
import path from 'path';

export default defineEventHandler(async event => {
  // 获取当前登录用户信息
  const user: Auth = event.context.auth as Auth;
  // 获取 tweetId 路径参数
  const tweetId = getRouterParam(event, 'tweetId');
  const mediaId = getRouterParam(event, 'mediaId');

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

  if (!mediaId) {
    throw createError({
      statusCode: 400,
      message: '缺少媒体ID',
      data: {
        success: false,
        message: '缺少媒体ID',
        code: 400,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  }

  const getOracleConnection =
    event.context.getOracleConnection;
  const connection = await getOracleConnection();

  try {
    const checkSql = `
      SELECT COUNT(*) AS count
      FROM n_tweets
      WHERE tweet_id = :tweetId AND author_id = :userId
    `;
    // 检查用户是否有权限删除媒体
    const checkCount = await connection.execute(checkSql, {
      userId: user.userId,
      tweetId: tweetId
    });

    // 提取总数
    const totalCount: number = checkCount
      .rows[0][0] as number;

    if (totalCount === 0) {
      throw createError({
        statusCode: 403,
        message: '无权删除媒体',
        data: {
          success: false,
          message: '无权删除媒体',
          code: 403,
          timestamp: new Date().toISOString()
        } as ErrorResponse
      });
    }

    // 获取媒体文件信息，用于删除物理文件
    const getMediaSql = `
      SELECT file_path, thumbnail_path
      FROM n_media
      WHERE media_id = :mediaId AND user_id = :userId
    `;

    const mediaResult = await connection.execute(
      getMediaSql,
      {
        mediaId: mediaId,
        userId: user.userId
      }
    );

    if (
      !mediaResult.rows ||
      mediaResult.rows.length === 0
    ) {
      throw createError({
        statusCode: 404,
        message: '媒体文件不存在',
        data: {
          success: false,
          message: '媒体文件不存在',
          code: 404,
          timestamp: new Date().toISOString()
        } as ErrorResponse
      });
    }

    // 获取文件路径
    const mediaRow = mediaResult.rows[0] as any[];
    const filePath = mediaRow[0]; // file_path
    const thumbnailPath = mediaRow[1]; // thumbnail_path

    console.log('准备删除文件:', {
      filePath,
      thumbnailPath
    });

    // 删除数据库记录
    const deleteMediaSql = `
      DELETE FROM n_media
      WHERE user_id = :userId AND media_id = :mediaId
    `;

    const deleteResult = await connection.execute(
      deleteMediaSql,
      {
        userId: user.userId,
        mediaId: mediaId
      },
      {
        autoCommit: true
      }
    );

    // 检查是否成功删除记录
    if (deleteResult.rowsAffected === 0) {
      throw createError({
        statusCode: 404,
        message: '媒体文件不存在或已被删除',
        data: {
          success: false,
          message: '媒体文件不存在或已被删除',
          code: 404,
          timestamp: new Date().toISOString()
        } as ErrorResponse
      });
    }

    // 删除物理文件
    const filesToDelete = [];

    // 主文件路径
    if (filePath) {
      const fullFilePath = path.join(
        process.cwd(),
        'public',
        filePath
      );
      filesToDelete.push(fullFilePath);
    }

    // 缩略图路径
    if (thumbnailPath) {
      const fullThumbnailPath = path.join(
        process.cwd(),
        'public',
        thumbnailPath
      );
      filesToDelete.push(fullThumbnailPath);
    }

    // 删除文件
    for (const fileToDelete of filesToDelete) {
      try {
        await fs.promises.access(
          fileToDelete,
          fs.constants.F_OK
        );
        await fs.promises.unlink(fileToDelete);
        console.log(`成功删除文件: ${fileToDelete}`);
      } catch (error) {
        console.error(
          `删除文件失败: ${fileToDelete}`,
          error
        );
        // 文件删除失败不阻断流程，因为数据库记录已经删除
      }
    }

    // 返回成功响应
    return {
      success: true,
      message: '媒体删除成功',
      data: {
        deletedMediaId: mediaId,
        deletedFiles: filesToDelete.length,
        timestamp: new Date().toISOString()
      },
      code: 200
    };
  } catch (error: any) {
    console.error('删除媒体时出错:', error);

    // 如果是已经抛出的错误，直接重新抛出
    if (error.statusCode) {
      throw error;
    }

    // 其他未知错误
    throw createError({
      statusCode: 500,
      message: '删除媒体时发生错误',
      data: {
        success: false,
        message: '删除媒体时发生错误',
        code: 500,
        timestamp: new Date().toISOString()
      } as ErrorResponse
    });
  } finally {
    await connection.close();
  }
});
