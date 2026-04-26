import type { File, Files } from 'formidable';
import formidable from 'formidable';
import {
  deleteStorageReference,
  ensureStorageTempDir,
  STORAGE_AVATAR_MAX_SIZE,
  storeAvatarFile
} from '~/server/storage';
import {
  v2NextId,
  v2Number,
  v2One,
  v2StringOrNull
} from '~/server/utils/v2';

function firstAvatarFile(files: Files<string>): File | null {
  return files.avatar?.[0] ?? files.file?.[0] ?? null;
}

function uploadError(
  statusCode: number,
  message: string,
  code = statusCode
) {
  return createError({
    statusCode,
    statusMessage: 'Bad Request',
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
  const getOracleConnection =
    event.context.getOracleConnection;
  const connection = await getOracleConnection();
  const currentAvatar = await v2One(
    connection,
    `
    SELECT
      avatar_url,
      avatar_media_id,
      (
        SELECT storage_key
        FROM n_media_assets
        WHERE media_id = u.avatar_media_id
      ) AS avatar_storage_key
    FROM n_users u
    WHERE user_id = :user_id
    `,
    { user_id: user.userId }
  );
  const tempDir = await ensureStorageTempDir();
  const form = formidable({
    multiples: false,
    uploadDir: tempDir,
    keepExtensions: true,
    maxFileSize: STORAGE_AVATAR_MAX_SIZE
  });

  return await new Promise((resolve, reject) => {
    form.parse(
      event.node.req,
      async (error: Error | null, _fields, files) => {
        let storedAvatar:
          | Awaited<ReturnType<typeof storeAvatarFile>>
          | null = null;

        try {
          if (error) {
            reject(uploadError(400, '上传文件解析失败'));
            return;
          }

          const file = firstAvatarFile(files);
          if (!file) {
            reject(uploadError(400, '上传文件为空'));
            return;
          }

          storedAvatar = await storeAvatarFile(
            user.userId,
            file
          );
          const mediaId = await v2NextId(
            connection,
            'seq_media_id'
          );

          await connection.execute(
            `
            INSERT INTO n_media_assets (
              media_id,
              owner_user_id,
              media_type,
              file_name,
              storage_key,
              public_url,
              file_size,
              mime_type,
              status
            ) VALUES (
              :media_id,
              :owner_user_id,
              'image',
              :file_name,
              :storage_key,
              :public_url,
              :file_size,
              :mime_type,
              'ready'
            )
            `,
            {
              media_id: mediaId,
              owner_user_id: user.userId,
              file_name: storedAvatar.originalName,
              storage_key: storedAvatar.key,
              public_url: storedAvatar.url,
              file_size: storedAvatar.size,
              mime_type: storedAvatar.contentType
            },
            { autoCommit: false }
          );

          const updateResult = await connection.execute(
            `
            UPDATE n_users
            SET avatar_url = :avatar_url,
                avatar_media_id = :avatar_media_id
            WHERE user_id = :user_id
            `,
            {
              avatar_url: storedAvatar.url,
              avatar_media_id: mediaId,
              user_id: user.userId
            },
            { autoCommit: false }
          );

          if (
            !updateResult.rowsAffected ||
            updateResult.rowsAffected === 0
          ) {
            throw new Error('头像信息更新失败');
          }

          const previousAvatarMediaId = v2Number(
            currentAvatar?.AVATAR_MEDIA_ID,
            0
          );
          if (previousAvatarMediaId > 0) {
            await connection.execute(
              `
              DELETE FROM n_media_assets
              WHERE media_id = :media_id
                AND owner_user_id = :user_id
              `,
              {
                media_id: previousAvatarMediaId,
                user_id: user.userId
              },
              { autoCommit: false }
            );
          }

          await connection.commit();

          try {
            await deleteStorageReference({
              storageKey: v2StringOrNull(
                currentAvatar?.AVATAR_STORAGE_KEY
              ),
              publicUrl: v2StringOrNull(
                currentAvatar?.AVATAR_URL
              )
            });
          } catch (cleanupError) {
            console.error(
              '清理旧头像文件失败:',
              cleanupError
            );
          }

          resolve({
            code: 200,
            success: true,
            message: '头像上传成功',
            data: {
              url: storedAvatar.url
            },
            timestamp: new Date().toISOString()
          } as SuccessUploadAvatarResponse);
        } catch (caught) {
          await connection.rollback().catch(() => undefined);

          if (storedAvatar) {
            await deleteStorageReference({
              storageKey: storedAvatar.key
            }).catch(cleanupError => {
              console.error(
                '清理失败头像文件时出错:',
                cleanupError
              );
            });
          }

          const message =
            caught instanceof Error
              ? caught.message
              : '头像上传失败';
          reject(uploadError(400, message));
        } finally {
          await connection.close();
        }
      }
    );
  });
});
