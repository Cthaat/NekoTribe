import type { H3Event } from 'h3';
import type { File, Files, Fields } from 'formidable';
import formidable from 'formidable';
import fs from 'fs';
import path from 'path';
import type oracledb from 'oracledb';
import { fileTypeFromFile } from 'file-type';
import {
  v2Auth,
  v2BadRequest,
  v2Body,
  v2Execute,
  v2NextId,
  v2NotFound,
  v2Number,
  v2Ok,
  v2One,
  v2RequiredString,
  v2String,
  v2StringOrNull,
  type V2DbRecord
} from '~/server/utils/v2';
import { v2MapMedia } from '~/server/models/v2';

const V2_ALLOWED_MIME = [
  'image/jpeg',
  'image/png',
  'image/gif',
  'video/mp4',
  'video/webm',
  'video/ogg',
  'audio/mpeg',
  'audio/wav',
  'audio/ogg'
];

const V2_ALLOWED_EXTS = [
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.mp4',
  '.webm',
  '.ogg',
  '.mp3',
  '.wav'
];

interface V2MediaCheckResult {
  valid: boolean;
  message?: string;
  fileType?: string;
}

async function v2CheckMediaFileBasic(
  file: File
): Promise<V2MediaCheckResult> {
  const typeInfo = await fileTypeFromFile(file.filepath);
  const realMime = typeInfo?.mime || '';
  const ext = path
    .extname(file.originalFilename || '')
    .toLowerCase();

  if (!V2_ALLOWED_MIME.includes(realMime)) {
    return {
      valid: false,
      message:
        '仅支持图片、视频、音频格式文件'
    };
  }
  if (!V2_ALLOWED_EXTS.includes(ext)) {
    return { valid: false, message: '文件扩展名不被支持' };
  }
  if (file.size > 500 * 1024 * 1024) {
    return { valid: false, message: '文件不能超过500MB' };
  }
  return {
    valid: true,
    fileType: v2InferMediaType(realMime)
  };
}

function v2FirstField(fields: Fields<string>, key: string): string {
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

function v2InferMediaType(mimeType: string): string {
  if (mimeType === 'image/gif') return 'gif';
  if (mimeType.startsWith('image/')) return 'image';
  if (mimeType.startsWith('video/')) return 'video';
  if (mimeType.startsWith('audio/')) return 'audio';
  return 'image';
}

async function v2UploadMultipartMedia(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2MediaAsset> {
  const auth = v2Auth(event);
  const tempDir = path.join(process.cwd(), 'temp');
  await fs.promises.mkdir(tempDir, { recursive: true });
  const form = formidable({
    multiples: false,
    uploadDir: tempDir,
    keepExtensions: true,
    maxFileSize: 500 * 1024 * 1024
  });

  return await new Promise<V2MediaAsset>((resolve, reject) => {
    form.parse(
      event.node.req,
      async (error: Error | null, fields, files) => {
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
          const check = await v2CheckMediaFileBasic(file);
          if (!check.valid) {
            reject(new Error(check.message || '文件不符合要求'));
            return;
          }

          const mediaId = await v2NextId(
            connection,
            'seq_media_id'
          );
          const ext = path.extname(
            file.originalFilename || file.filepath
          );
          const fileName = `${mediaId}${ext}`;
          const uploadDir = path.join(
            process.cwd(),
            'upload',
            'media',
            String(auth.userId)
          );
          await fs.promises.mkdir(uploadDir, { recursive: true });
          const newPath = path.join(uploadDir, fileName);
          await fs.promises.rename(file.filepath, newPath);

          const publicUrl = `/upload/media/${auth.userId}/${fileName}`;
          const mediaType =
            check.fileType && check.fileType !== 'unknown'
              ? check.fileType
              : v2InferMediaType(file.mimetype || '');
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
              :alt_text,
              'ready'
            )
            `,
            {
              media_id: mediaId,
              owner_user_id: auth.userId,
              media_type: mediaType,
              file_name: file.originalFilename || fileName,
              storage_key: newPath,
              public_url: publicUrl,
              file_size: file.size,
              mime_type: file.mimetype || 'application/octet-stream',
              alt_text: v2FirstField(fields, 'alt_text') || null
            }
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
          resolve(v2MapMedia(row));
        } catch (caught) {
          reject(caught);
        }
      }
    );
  });
}

async function v2CreateJsonMedia(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2MediaAsset> {
  const auth = v2Auth(event);
  const body = await v2Body(event);
  const mediaId = await v2NextId(connection, 'seq_media_id');
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
      :status
    )
    `,
    {
      media_id: mediaId,
      owner_user_id: auth.userId,
      media_type: v2String(body.media_type, 'image'),
      file_name: v2RequiredString(body, 'file_name'),
      storage_key: v2String(body.storage_key, v2String(body.public_url)),
      public_url: v2RequiredString(body, 'public_url'),
      file_size: v2Number(body.file_size),
      mime_type: v2String(body.mime_type, 'application/octet-stream'),
      width: body.width === undefined ? null : v2Number(body.width),
      height: body.height === undefined ? null : v2Number(body.height),
      duration:
        body.duration === undefined ? null : v2Number(body.duration),
      thumbnail_url: v2StringOrNull(body.thumbnail_url),
      alt_text: v2StringOrNull(body.alt_text),
      status: v2String(body.status, 'ready')
    }
  );
  const row = await v2One(
    connection,
    'SELECT * FROM n_media_assets WHERE media_id = :media_id',
    { media_id: mediaId }
  );
  if (!row) v2NotFound('媒体不存在');
  return v2MapMedia(row as V2DbRecord);
}

export async function v2UploadMedia(
  event: H3Event,
  connection: oracledb.Connection
): Promise<V2Response<V2MediaAsset>> {
  try {
    const media = v2IsMultipart(event)
      ? await v2UploadMultipartMedia(event, connection)
      : await v2CreateJsonMedia(event, connection);
    return v2Ok(media, 'media uploaded');
  } catch (error) {
    v2BadRequest(
      error instanceof Error ? error.message : '媒体上传失败'
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
    SELECT storage_key
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
  const storageKey = v2String(row.STORAGE_KEY);
  if (storageKey && path.isAbsolute(storageKey)) {
    await fs.promises.rm(storageKey, { force: true });
  }
  return {
    code: 200,
    message: 'media deleted',
    data: null,
    meta: null
  };
}
