import type { H3Event } from 'h3';
import type { File, Fields, Files } from 'formidable';
import formidable from 'formidable';
import type oracledb from 'oracledb';
import {
  deleteStorageReference,
  ensureStorageTempDir,
  STORAGE_MEDIA_MAX_SIZE,
  storePostMediaFile
} from '~/server/storage';
import { v2MapMedia } from '~/server/models/v2';
import {
  v2Auth,
  v2BadRequest,
  v2Execute,
  v2NextId,
  v2NotFound,
  v2Ok,
  v2One,
  type V2DbRecord
} from '~/server/utils/v2';

function v2FirstField(
  fields: Fields<string>,
  key: string
): string {
  return fields[key]?.[0] ?? '';
}

function v2FirstFile(files: Files<string>): File | null {
  return files.file?.[0] ?? files.media?.[0] ?? null;
}

function v2IsMultipart(event: H3Event): boolean {
  return (
    event.node.req.headers['content-type']
      ?.toString()
      .includes('multipart/form-data') ?? false
  );
}

async function v2UploadMultipartMedia(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2MediaAsset> {
  const auth = v2Auth(event);
  const tempDir = await ensureStorageTempDir();
  const form = formidable({
    multiples: false,
    uploadDir: tempDir,
    keepExtensions: true,
    maxFileSize: STORAGE_MEDIA_MAX_SIZE
  });

  return await new Promise<V2MediaAsset>(
    (resolve, reject) => {
      form.parse(
        event.node.req,
        async (error: Error | null, fields, files) => {
          let storedMedia: Awaited<
            ReturnType<typeof storePostMediaFile>
          > | null = null;

          try {
            if (error) {
              reject(error);
              return;
            }

            const file = v2FirstFile(files);
            if (!file) {
              reject(new Error('上传文件为空'));
              return;
            }

            storedMedia = await storePostMediaFile(
              auth.userId,
              file
            );
            const mediaId = await v2NextId(
              connection,
              'seq_media_id'
            );

            await v2Execute(
              connection,
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
              width,
              height,
              duration,
              thumbnail_url,
              alt_text,
              status
            ) VALUES (
              :media_id,
              :owner_user_id,
              :media_type,
              :file_name,
              :storage_key,
              :public_url,
              :file_size,
              :mime_type,
              :width,
              :height,
              :duration,
              :thumbnail_url,
              :alt_text,
              'ready'
            )
            `,
              {
                media_id: mediaId,
                owner_user_id: auth.userId,
                media_type: storedMedia.mediaType,
                file_name: storedMedia.originalName,
                storage_key: storedMedia.key,
                public_url: storedMedia.url,
                file_size: storedMedia.size,
                mime_type: storedMedia.contentType,
                width: storedMedia.metadata.width,
                height: storedMedia.metadata.height,
                duration: storedMedia.metadata.duration,
                thumbnail_url: storedMedia.thumbnailUrl,
                alt_text:
                  v2FirstField(fields, 'alt_text') || null
              },
              false
            );

            const row = await v2One(
              connection,
              `
            SELECT *
            FROM n_media_assets
            WHERE media_id = :media_id
            `,
              { media_id: mediaId }
            );

            if (!row) {
              reject(new Error('媒体记录创建失败'));
              return;
            }

            await connection.commit();
            resolve(v2MapMedia(row));
          } catch (caught) {
            await connection
              .rollback()
              .catch(() => undefined);
            if (storedMedia) {
              await deleteStorageReference({
                storageKey: storedMedia.key
              }).catch(cleanupError => {
                console.error(
                  '清理上传失败的媒体文件时出错:',
                  cleanupError
                );
              });
            }

            reject(caught);
          }
        }
      );
    }
  );
}

export async function v2UploadMedia(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2MediaAsset>> {
  if (!v2IsMultipart(event)) {
    v2BadRequest('请使用 multipart/form-data 上传媒体文件');
  }

  try {
    const media = await v2UploadMultipartMedia(
      event,
      connection
    );

    return v2Ok(media, 'media uploaded');
  } catch (error) {
    v2BadRequest(
      error instanceof Error
        ? error.message
        : '媒体上传失败'
    );
  }
}

export async function v2DeleteMedia(
  event: H3Event,
  connection: oracledb.Connection,
  mediaId: number
): Promise<V2Response<null>> {
  const auth = v2Auth(event);
  const row = await v2One(
    connection,
    `
    SELECT storage_key, public_url, thumbnail_url
    FROM n_media_assets
    WHERE media_id = :media_id
      AND owner_user_id = :user_id
    `,
    { media_id: mediaId, user_id: auth.userId }
  );
  if (!row) v2NotFound('媒体不存在');

  await v2Execute(
    connection,
    `
    DELETE FROM n_media_assets
    WHERE media_id = :media_id
      AND owner_user_id = :user_id
    `,
    { media_id: mediaId, user_id: auth.userId }
  );

  await deleteStorageReference({
    storageKey: v2StringOrNull(row.STORAGE_KEY),
    publicUrl: v2StringOrNull(row.PUBLIC_URL)
  });
  await deleteStorageReference({
    publicUrl: v2StringOrNull(row.THUMBNAIL_URL)
  });

  return {
    code: 200,
    message: 'media deleted',
    data: null,
    meta: null
  };
}
