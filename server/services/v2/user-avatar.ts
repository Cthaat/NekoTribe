import { open, unlink } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { formidable } from 'formidable';
import type { File, Files } from 'formidable';
import { getRequestHeader, setResponseHeader } from 'h3';
import type { H3Event } from 'h3';
import type { Connection } from 'oracledb';
import avatar from '../../../specifications/requirements/user-avatar.json';
import { deleteStorageReference, ensureStorageTempDir, storeValidatedAvatarFile } from '~/server/storage';
import { getStorageConfig } from '~/server/storage/config';
import { classifyMultipartPartsByFilename, StorageHttpError } from '~/server/storage/http';
import { validateS3Configuration } from '~/server/storage/providers/s3-request';
import { v2Auth, v2BadRequest, v2Execute, v2Ok, v2One, v2ServerError, v2Throw } from '~/server/utils/v2';

const formats = avatar.formats.map(format => ({ ...format, prefix: Buffer.from(format.hex, 'hex') }));

async function inspectAvatar(file: File) {
  if (file.size < 1 || file.size > avatar.maxFileBytes) v2BadRequest('头像上传失败');
  const handle = await open(file.filepath, 'r').catch(() => v2ServerError());
  const bytes = Buffer.alloc(8);
  const { bytesRead } = await handle.read(bytes, 0, bytes.length, 0)
    .finally(() => handle.close()).catch(() => v2ServerError());
  const format = formats.find(({ prefix }) => bytesRead >= prefix.length && bytes.subarray(0, prefix.length).equals(prefix));
  if (!format) v2BadRequest('头像仅支持 jpg、png、gif 图片');

  const name = file.originalFilename ?? '';
  const originalName = name && Buffer.byteLength(name) <= 255 && !/[\/\\\x00-\x1f\x7f]/.test(name)
    ? name : 'avatar' + format.extension;
  return { originalName, extension: format.extension, mimeType: format.mime, size: file.size };
}

export async function v2UpdateAvatar(
  event: H3Event,
  connection: Connection,
  preferredField: 'file' | 'avatar' = 'file'
): Promise<V2Response<V2AvatarData>> {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  const { userId } = v2Auth(event);
  const contentType = getRequestHeader(event, 'content-type') ?? '';
  if (!/^multipart\/form-data(?:\s*;|$)/i.test(contentType)) v2BadRequest('请使用 multipart/form-data 上传头像');

  try {
    if (getStorageConfig().type === 's3') validateS3Configuration();
  } catch (error) {
    if (error instanceof StorageHttpError && error.statusCode === 503) v2Throw(503, error.message);
    v2ServerError();
  }

  const tempDir = resolve(await ensureStorageTempDir().catch(() => v2ServerError()));
  const paths = new Set<string>();
  try {
    const form = formidable({
      uploadDir: tempDir,
      maxFiles: avatar.maxFiles,
      maxFields: avatar.maxFields,
      maxFieldsSize: avatar.maxFieldBytes,
      maxFileSize: avatar.maxFileBytes,
      maxTotalFileSize: avatar.maxFileBytes
    });
    classifyMultipartPartsByFilename(form);
    form.on('fileBegin', (_, file) => paths.add(file.filepath));
    let files: Files;
    try {
      [, files] = await form.parse(event.node.req);
    } catch {
      v2BadRequest('头像上传失败');
    }
    const alternateField = preferredField === 'file' ? 'avatar' : 'file';
    const file = files[preferredField]?.[0] ?? files[alternateField]?.[0];
    if (!file) v2BadRequest('上传文件为空');
    const validated = await inspectAvatar(file);
    const stored = await storeValidatedAvatarFile(userId, file.filepath, validated).catch(() => v2ServerError());

    let commitStarted = false;
    try {
      if (!await v2One(connection, avatar.sql.lock, { user_id: userId })) v2ServerError();
      const id = Number((await v2One(connection, avatar.sql.next))?.ID);
      if (!Number.isSafeInteger(id) || id < 1) v2ServerError();
      const reference = { user_id: userId, media_id: id, public_url: stored.url };
      if (await v2Execute(connection, avatar.sql.insert, {
        ...reference, file_name: stored.originalName, storage_key: stored.key, file_size: stored.size, mime_type: stored.contentType
      }, false) !== 1) v2ServerError();
      if (await v2Execute(connection, avatar.sql.update, reference, false) !== 1) v2ServerError();
      commitStarted = true;
      await connection.commit();
      return v2Ok({ avatar_url: stored.url, avatar_media_id: id });
    } catch {
      if (!commitStarted) {
        const rolledBack = await connection.rollback().then(() => true, () => false);
        if (rolledBack) await deleteStorageReference({ storageKey: stored.key }).catch(() => {
          console.error('Avatar rollback storage cleanup failed');
        });
      }
      v2ServerError();
    }
  } finally {
    await Promise.all(Array.from(paths, async (file) => {
      if (dirname(resolve(file)) === tempDir) {
        await unlink(file).catch((error: NodeJS.ErrnoException) => {
          if (error.code !== 'ENOENT') console.error('Avatar temporary cleanup failed');
        });
      }
    }));
  }
}
