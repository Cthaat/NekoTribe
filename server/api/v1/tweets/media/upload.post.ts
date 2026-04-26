import path from 'node:path';
import type { File, Files, Fields } from 'formidable';
import formidable from 'formidable';
import {
  deleteStorageReference,
  ensureStorageTempDir,
  STORAGE_MEDIA_MAX_SIZE,
  storePostMediaFile
} from '~/server/storage';

function uploadError(
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

function firstField(fields: Fields<string>, key: string): string {
  return fields[key]?.[0] ?? '';
}

function collectFiles(files: Files<string>): File[] {
  const fileField = files.file ?? files.media ?? [];
  return Array.isArray(fileField) ? fileField : [fileField];
}

export default defineEventHandler(async event => {
  const user: Auth = event.context.auth as Auth;
  const getOracleConnection =
    event.context.getOracleConnection;
  const connection = await getOracleConnection();
  const tempDir = await ensureStorageTempDir();
  const form = formidable({
    multiples: true,
    uploadDir: tempDir,
    keepExtensions: true,
    maxFileSize: STORAGE_MEDIA_MAX_SIZE,
    maxFiles: 4
  });

  return await new Promise((resolve, reject) => {
    form.parse(
      event.node.req,
      async (error: Error | null, fields, files) => {
        const storedFiles: Array<
          Awaited<ReturnType<typeof storePostMediaFile>>
        > = [];

        try {
          if (error) {
            reject(uploadError(400, '上传文件解析失败'));
            return;
          }

          const tweetId = firstField(fields, 'tweetId');
          const altText = firstField(fields, 'altText');
          const description = firstField(fields, 'description');

          if (!tweetId) {
            reject(uploadError(400, 'tweetId 参数是必需的'));
            return;
          }

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
            reject(uploadError(403, '无权上传媒体', 403));
            return;
          }

          const filesToProcess = collectFiles(files);
          if (filesToProcess.length === 0) {
            reject(uploadError(400, '上传文件为空'));
            return;
          }

          for (const file of filesToProcess) {
            const stored = await storePostMediaFile(
              user.userId,
              file
            );
            storedFiles.push(stored);
          }

          for (const storedFile of storedFiles) {
            await connection.execute(
              `
              INSERT INTO n_media (
                tweet_id,
                user_id,
                media_type,
                file_name,
                file_path,
                file_size,
                mime_type,
                width,
                height,
                duration,
                thumbnail_path,
                alt_text,
                is_processed,
                created_at
              ) VALUES (
                :tweet_id,
                :user_id,
                :media_type,
                :file_name,
                :file_path,
                :file_size,
                :mime_type,
                :width,
                :height,
                :duration,
                :thumbnail_path,
                :alt_text,
                :is_processed,
                CURRENT_TIMESTAMP
              )
              `,
              {
                tweet_id: tweetId,
                user_id: user.userId,
                media_type: storedFile.mediaType,
                file_name: storedFile.originalName,
                file_path: storedFile.url,
                file_size: storedFile.size,
                mime_type: storedFile.contentType,
                width: storedFile.metadata.width,
                height: storedFile.metadata.height,
                duration: storedFile.metadata.duration,
                thumbnail_path: storedFile.thumbnailUrl,
                alt_text: altText || null,
                is_processed: 1
              },
              { autoCommit: false }
            );
          }

          await connection.commit();

          resolve({
            code: 200,
            success: true,
            message: `成功上传 ${storedFiles.length} 个媒体文件`,
            data: {
              tweetId,
              uploadedFiles: storedFiles.map(file => ({
                fileName: path.basename(file.key),
                originalName: file.originalName,
                url: file.url,
                size: file.size,
                mimeType: file.contentType,
                mediaType: file.mediaType,
                width: file.metadata.width ?? undefined,
                height: file.metadata.height ?? undefined,
                duration: file.metadata.duration ?? undefined,
                thumbnailPath:
                  file.thumbnailUrl ?? undefined
              })),
              altText: altText || undefined,
              description: description || undefined
            },
            timestamp: new Date().toISOString()
          } as SuccessUploadResponse);
        } catch (caught) {
          await connection.rollback().catch(() => undefined);

          for (const storedFile of storedFiles) {
            await deleteStorageReference({
              storageKey: storedFile.key
            }).catch(cleanupError => {
              console.error(
                '清理失败媒体文件时出错:',
                cleanupError
              );
            });
          }

          const message =
            caught instanceof Error
              ? caught.message
              : '媒体上传失败';
          reject(uploadError(400, message));
        } finally {
          await connection.close();
        }
      }
    );
  });
});
