import { randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { promisify } from 'node:util';
import type { File } from 'formidable';
import { fileTypeFromFile } from 'file-type';
import sharp from 'sharp';
import ffprobe from 'ffprobe-static';
import { getStorageConfig } from './config';
import { StorageHttpError } from './http';
import { LocalStorageProvider } from './providers/local';
import { S3StorageProvider } from './providers/s3';
import type {
  FileMetadata,
  ManagedMediaType,
  StorageProvider,
  StoredManagedFile,
  StoredManagedMedia,
  ValidatedAvatarFile,
  ValidatedMediaFile
} from './types';

const execFileAsync = promisify(execFile);

const AVATAR_MIME_TYPES = new Set([
  'image/gif',
  'image/jpeg',
  'image/png'
]);

const MEDIA_MIME_TYPES = new Set([
  'audio/mpeg',
  'audio/ogg',
  'audio/wav',
  'image/gif',
  'image/jpeg',
  'image/png',
  'video/mp4',
  'video/ogg',
  'video/webm'
]);

const AVATAR_MAX_SIZE = 10 * 1024 * 1024;
const MEDIA_MAX_SIZE = 500 * 1024 * 1024;

export const STORAGE_AVATAR_MAX_SIZE = AVATAR_MAX_SIZE;
export const STORAGE_MEDIA_MAX_SIZE = MEDIA_MAX_SIZE;

let cachedProvider: StorageProvider | null = null;

interface FfprobeStream {
  codec_type?: string;
  duration?: string;
  height?: number;
  width?: number;
}

interface FfprobeFormat {
  duration?: string;
}

interface FfprobePayload {
  format?: FfprobeFormat;
  streams?: FfprobeStream[];
}

function normalizeStorageKey(key: string): string {
  const normalized = key
    .replace(/\\/g, '/')
    .replace(/^\/+/, '');
  const safe = path.posix.normalize(normalized);

  if (
    !safe ||
    safe === '.' ||
    safe.startsWith('../') ||
    safe.includes('/../')
  ) {
    throw new StorageHttpError(400, '非法存储路径');
  }

  return safe;
}

function pickDetectedExtension(
  detectedExt: string | undefined,
  fallbackName: string
): string {
  if (detectedExt) {
    return `.${detectedExt.toLowerCase()}`;
  }

  const fallbackExt = path.extname(fallbackName).toLowerCase();
  if (fallbackExt) {
    return fallbackExt;
  }

  throw new StorageHttpError(400, '无法识别文件扩展名');
}

function inferManagedMediaType(
  mimeType: string
): ManagedMediaType {
  if (mimeType === 'image/gif') {
    return 'gif';
  }

  if (mimeType.startsWith('image/')) {
    return 'image';
  }

  if (mimeType.startsWith('video/')) {
    return 'video';
  }

  return 'audio';
}

function buildDateSegments(date: Date): string[] {
  return [
    String(date.getUTCFullYear()),
    String(date.getUTCMonth() + 1).padStart(2, '0')
  ];
}

function buildAvatarStorageKey(
  userId: number,
  extension: string
): string {
  return normalizeStorageKey(
    path.posix.join(
      'avatars',
      String(userId),
      ...buildDateSegments(new Date()),
      `${randomUUID()}${extension}`
    )
  );
}

function buildPostMediaStorageKey(
  userId: number,
  mediaType: ManagedMediaType,
  extension: string
): string {
  const bucket =
    mediaType === 'video'
      ? 'videos'
      : mediaType === 'audio'
        ? 'audio'
        : 'images';

  return normalizeStorageKey(
    path.posix.join(
      'posts',
      bucket,
      String(userId),
      ...buildDateSegments(new Date()),
      `${randomUUID()}${extension}`
    )
  );
}

function getProvider(): StorageProvider {
  if (cachedProvider) {
    return cachedProvider;
  }

  const config = getStorageConfig();
  cachedProvider =
    config.type === 's3'
      ? new S3StorageProvider(config)
      : new LocalStorageProvider(config);

  return cachedProvider;
}

async function detectUploadedFile(
  file: File
): Promise<{
  extension: string;
  mimeType: string;
  originalName: string;
}> {
  const detected = await fileTypeFromFile(file.filepath);
  const originalName =
    file.originalFilename || path.basename(file.filepath);
  const mimeType =
    detected?.mime || file.mimetype || 'application/octet-stream';
  const extension = pickDetectedExtension(
    detected?.ext,
    originalName
  );

  return {
    extension,
    mimeType,
    originalName
  };
}

async function readImageMetadata(
  filePath: string
): Promise<FileMetadata> {
  const metadata = await sharp(filePath).metadata();

  return {
    width: metadata.width ?? null,
    height: metadata.height ?? null,
    duration: null
  };
}

async function readRichMediaMetadata(
  filePath: string
): Promise<FileMetadata> {
  const ffprobeBinary =
    typeof ffprobe === 'string' ? ffprobe : ffprobe.path;

  if (!ffprobeBinary) {
    return {
      width: null,
      height: null,
      duration: null
    };
  }

  const { stdout } = await execFileAsync(ffprobeBinary, [
    '-v',
    'quiet',
    '-print_format',
    'json',
    '-show_format',
    '-show_streams',
    filePath
  ]);
  const payload = JSON.parse(stdout) as FfprobePayload;
  const videoStream = payload.streams?.find(
    stream => stream.codec_type === 'video'
  );
  const audioStream = payload.streams?.find(
    stream => stream.codec_type === 'audio'
  );

  const rawDuration =
    payload.format?.duration ||
    videoStream?.duration ||
    audioStream?.duration;

  return {
    width: videoStream?.width ?? null,
    height: videoStream?.height ?? null,
    duration: rawDuration
      ? Math.round(Number.parseFloat(rawDuration))
      : null
  };
}

async function removeTempFile(filePath: string): Promise<void> {
  await fs.promises.rm(filePath, { force: true });
}

export function getStorageProvider(): StorageProvider {
  return getProvider();
}

export function getStorageTempDir(): string {
  return path.join(getStorageConfig().rootPath, 'temp');
}

export async function ensureStorageTempDir(): Promise<string> {
  const tempDir = getStorageTempDir();
  await fs.promises.mkdir(tempDir, { recursive: true });
  return tempDir;
}

export function managedPublicUrlToStorageKey(
  publicUrl: string
): string | null {
  const config = getStorageConfig();
  const relativePrefix = `${config.publicBasePath}/`;

  if (publicUrl.startsWith(relativePrefix)) {
    return normalizeStorageKey(
      publicUrl.slice(relativePrefix.length)
    );
  }

  const baseUrl = config.cdnBaseUrl || config.publicBaseUrl;
  if (!baseUrl) {
    return null;
  }

  try {
    const parsed = new URL(publicUrl);
    const base = new URL(`${baseUrl}/`);
    if (parsed.origin !== base.origin) {
      return null;
    }
    if (!parsed.pathname.startsWith(relativePrefix)) {
      return null;
    }
    return normalizeStorageKey(
      parsed.pathname.slice(relativePrefix.length)
    );
  } catch {
    return null;
  }
}

export function legacyPublicUrlToAbsolutePath(
  publicUrl: string
): string | null {
  const normalized = publicUrl.replace(/\\/g, '/');
  const legacyPrefix = '/upload/';

  if (!normalized.startsWith(legacyPrefix)) {
    return null;
  }

  const config = getStorageConfig();
  const relativePath = normalized.slice(legacyPrefix.length);
  const absolutePath = path.resolve(
    config.legacyUploadPath,
    relativePath
  );
  const relative = path.relative(
    config.legacyUploadPath,
    absolutePath
  );

  if (
    relative.startsWith('..') ||
    path.isAbsolute(relative)
  ) {
    return null;
  }

  return absolutePath;
}

export async function deleteManagedObject(
  storageKey: string
): Promise<void> {
  const provider = getProvider();
  await provider.deleteObject(normalizeStorageKey(storageKey));
}

export async function deletePublicFileReference(
  publicUrl: string | null | undefined
): Promise<void> {
  if (!publicUrl) {
    return;
  }

  const managedKey = managedPublicUrlToStorageKey(publicUrl);
  if (managedKey) {
    await deleteManagedObject(managedKey);
    return;
  }

  const legacyPath = legacyPublicUrlToAbsolutePath(publicUrl);
  if (legacyPath) {
    await fs.promises.rm(legacyPath, { force: true });
  }
}

export async function deleteStorageReference(input: {
  storageKey?: string | null;
  publicUrl?: string | null;
}): Promise<void> {
  if (input.storageKey) {
    if (path.isAbsolute(input.storageKey)) {
      await fs.promises.rm(input.storageKey, {
        force: true
      });
      return;
    }

    await deleteManagedObject(input.storageKey);
    return;
  }

  await deletePublicFileReference(input.publicUrl);
}

export async function validateAvatarFile(
  file: File
): Promise<ValidatedAvatarFile> {
  const detected = await detectUploadedFile(file);

  if (!AVATAR_MIME_TYPES.has(detected.mimeType)) {
    throw new StorageHttpError(
      400,
      '头像仅支持 jpg、png、gif 图片'
    );
  }

  if ((file.size || 0) > AVATAR_MAX_SIZE) {
    throw new StorageHttpError(
      400,
      '头像文件不能超过 10MB'
    );
  }

  return {
    originalName: detected.originalName,
    mimeType: detected.mimeType,
    extension: detected.extension,
    size: file.size || 0
  };
}

export async function validateMediaFile(
  file: File
): Promise<ValidatedMediaFile> {
  const detected = await detectUploadedFile(file);

  if (!MEDIA_MIME_TYPES.has(detected.mimeType)) {
    throw new StorageHttpError(
      400,
      '仅支持图片、视频和音频文件上传'
    );
  }

  if ((file.size || 0) > MEDIA_MAX_SIZE) {
    throw new StorageHttpError(
      400,
      '媒体文件不能超过 500MB'
    );
  }

  const mediaType = inferManagedMediaType(detected.mimeType);
  const metadata =
    mediaType === 'image' || mediaType === 'gif'
      ? await readImageMetadata(file.filepath)
      : await readRichMediaMetadata(file.filepath);

  return {
    originalName: detected.originalName,
    mimeType: detected.mimeType,
    extension: detected.extension,
    size: file.size || 0,
    mediaType,
    metadata
  };
}

export async function storeAvatarFile(
  userId: number,
  file: File
): Promise<StoredManagedFile> {
  const provider = getProvider();
  const validated = await validateAvatarFile(file);
  const stored = await provider.saveFromPath({
    key: buildAvatarStorageKey(userId, validated.extension),
    sourcePath: file.filepath,
    contentType: validated.mimeType
  });

  return {
    ...stored,
    originalName: validated.originalName
  };
}

export async function storePostMediaFile(
  userId: number,
  file: File
): Promise<StoredManagedMedia> {
  const provider = getProvider();
  const validated = await validateMediaFile(file);
  const stored = await provider.saveFromPath({
    key: buildPostMediaStorageKey(
      userId,
      validated.mediaType,
      validated.extension
    ),
    sourcePath: file.filepath,
    contentType: validated.mimeType
  });

  return {
    ...stored,
    originalName: validated.originalName,
    mediaType: validated.mediaType,
    metadata: validated.metadata,
    thumbnailUrl: null
  };
}

export async function discardUploadedFile(
  file: File
): Promise<void> {
  await removeTempFile(file.filepath);
}
