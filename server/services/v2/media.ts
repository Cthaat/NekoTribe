import type { H3Event } from 'h3';
import type { File, Fields, Files } from 'formidable';
import formidable from 'formidable';
import fs from 'node:fs/promises';
import path from 'node:path';
import { StorageHttpError } from '~/server/storage/http';
import type oracledb from 'oracledb';
import {
  deleteStorageReference,
  ensureStorageTempDir,
  STORAGE_MEDIA_MAX_SIZE,
  storePostMediaFile
} from '~/server/storage';
import {
  v2EnsureMediaDescriptionColumn,
  v2MapMedia
} from '~/server/models/v2';
import {
  v2Auth,
  v2BadRequest,
  v2Execute,
  v2NextId,
  v2NotFound,
  v2Ok,
  v2One,
  v2StringOrNull,
  v2Throw
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
  const contentType = event.node.req.headers['content-type']?.toString() ?? '';
  return contentType.split(';')[0]?.trim().toLowerCase() === 'multipart/form-data';
}

async function v2UploadMultipartMedia(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2MediaAsset> {
  const auth = v2Auth(event);
  const tempRoot = await ensureStorageTempDir();
  // This path is created by this request, never taken from a filename or row.
  const tempDir = await fs.mkdtemp(path.join(tempRoot, 'media-'));
  let storedMedia: Awaited<ReturnType<typeof storePostMediaFile>> | null = null;
  let databaseStarted = false;
  let commitAttempted = false;
  let committed = false;
  try {
    const form = formidable({
      multiples: false,
      uploadDir: tempDir,
      keepExtensions: true,
      maxFileSize: STORAGE_MEDIA_MAX_SIZE,
      maxTotalFileSize: STORAGE_MEDIA_MAX_SIZE
    });
    let fields: Fields<string>;
    let files: Files<string>;
    try { [fields, files] = await form.parse(event.node.req); }
    catch (error) {
      // Formidable numeric codes describe invalid or incomplete input. IO
      // failures with string errno codes remain internal errors.
      if (typeof error === 'object' && error !== null &&
          typeof Reflect.get(error, 'code') === 'number') v2BadRequest('媒体上传失败');
      throw error;
    }
    const file = v2FirstFile(files);
    if (!file) v2BadRequest('上传文件为空');
    storedMedia = await storePostMediaFile(auth.userId, file);
    databaseStarted = true;
    const mediaId = await v2NextId(connection, 'seq_media_id');
    await v2EnsureMediaDescriptionColumn(connection);
    await v2Execute(connection, `
      INSERT INTO n_media_assets (
        media_id, owner_user_id, media_type, file_name, storage_key,
        public_url, file_size, mime_type, width, height, duration,
        thumbnail_url, alt_text, description, status
      ) VALUES (
        :media_id, :owner_user_id, :media_type, :file_name, :storage_key,
        :public_url, :file_size, :mime_type, :width, :height, :duration,
        :thumbnail_url, :alt_text, :description, 'ready'
      )
    `, {
      media_id: mediaId, owner_user_id: auth.userId,
      media_type: storedMedia.mediaType, file_name: storedMedia.originalName,
      storage_key: storedMedia.key, public_url: storedMedia.url,
      file_size: storedMedia.size, mime_type: storedMedia.contentType,
      width: storedMedia.metadata.width, height: storedMedia.metadata.height,
      duration: storedMedia.metadata.duration, thumbnail_url: storedMedia.thumbnailUrl,
      alt_text: v2FirstField(fields, 'alt_text') || null,
      description: v2FirstField(fields, 'description') || null
    }, false);
    const row = await v2One(connection,
      'SELECT * FROM n_media_assets WHERE media_id = :media_id',
      {media_id: mediaId});
    if (!row) throw new Error('Media insert did not return a row');
    const result = v2MapMedia(row);
    commitAttempted = true;
    await connection.commit();
    committed = true;
    return result;
  } catch (error) {
    let rollbackConfirmed = !databaseStarted;
    if (databaseStarted && !committed) {
      try { await connection.rollback(); rollbackConfirmed = true; }
      catch { rollbackConfirmed = false; }
    }
    if (storedMedia && !commitAttempted && rollbackConfirmed) {
      try { await deleteStorageReference({storageKey: storedMedia.key}); }
      catch { console.warn('media upload object cleanup unavailable'); }
    }
    if (!rollbackConfirmed && !committed) throw new Error('Media upload rollback failed');
    throw error;
  } finally {
    // Remove only the request-owned directory, including ignored files and
    // partially parsed uploads. Retry transient Windows file-handle errors.
    try {
      if (path.dirname(path.resolve(tempDir)) !== path.resolve(tempRoot) ||
          !path.basename(tempDir).startsWith('media-')) throw new Error('Invalid temporary directory');
      await fs.rm(tempDir, {recursive: true, force: true, maxRetries: 3, retryDelay: 10});
    }
    catch { console.warn('media upload temporary cleanup unavailable'); }
  }
}

export async function v2UploadMedia(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2MediaAsset>> {
  v2Auth(event);
  if (!v2IsMultipart(event)) v2BadRequest('请使用 multipart/form-data 上传媒体文件');
  try {
    return v2Ok(await v2UploadMultipartMedia(event, connection), 'media uploaded');
  } catch (error) {
    if (error instanceof StorageHttpError) {
      if (error.statusCode === 400 && [
        '仅支持图片、视频、音频、文档、文本或压缩包文件', '文件不能超过 500MB'
      ].includes(error.message)) v2BadRequest(error.message);
      if (error.statusCode === 501) v2Throw(501, '媒体存储暂不可用');
    }
    throw error;
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
