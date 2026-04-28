import fs from 'node:fs';
import path from 'node:path';
import {
  createLocalReadResult,
  StorageHttpError
} from '../http';
import type {
  StorageCapabilities,
  StorageConfig,
  StorageProvider,
  StorageReadRequest,
  StorageReadResult,
  StorageSaveInput,
  StoredObject,
  StorageVisibility
} from '../types';

const LOCAL_CAPABILITIES: StorageCapabilities = {
  multipartUpload: false,
  cdn: false,
  privateObjects: false
};

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

function buildPublicUrl(
  config: StorageConfig,
  key: string
): string {
  const relativeUrl = `${config.publicBasePath}/${key}`;
  const baseUrl = config.cdnBaseUrl || config.publicBaseUrl;

  if (!baseUrl) {
    return relativeUrl;
  }

  return new URL(relativeUrl, `${baseUrl}/`).toString();
}

export class LocalStorageProvider
  implements StorageProvider
{
  readonly type = 'local' as const;
  readonly capabilities = LOCAL_CAPABILITIES;

  constructor(private readonly config: StorageConfig) {}

  private resolveAbsolutePath(key: string): string {
    const normalizedKey = normalizeStorageKey(key);
    const absolutePath = path.resolve(
      this.config.rootPath,
      normalizedKey
    );
    const relative = path.relative(
      this.config.rootPath,
      absolutePath
    );

    if (
      relative.startsWith('..') ||
      path.isAbsolute(relative)
    ) {
      throw new StorageHttpError(400, '非法存储路径');
    }

    return absolutePath;
  }

  private async moveFile(
    sourcePath: string,
    targetPath: string
  ): Promise<void> {
    try {
      await fs.promises.rename(sourcePath, targetPath);
    } catch (error) {
      const maybeError = error as NodeJS.ErrnoException;
      if (maybeError.code !== 'EXDEV') {
        throw error;
      }

      await fs.promises.copyFile(sourcePath, targetPath);
      await fs.promises.rm(sourcePath, { force: true });
    }
  }

  async saveFromPath(
    input: StorageSaveInput
  ): Promise<StoredObject> {
    const visibility: StorageVisibility =
      input.visibility || 'public';
    const absolutePath = this.resolveAbsolutePath(input.key);

    await fs.promises.mkdir(path.dirname(absolutePath), {
      recursive: true
    });
    await this.moveFile(input.sourcePath, absolutePath);

    const stat = await fs.promises.stat(absolutePath);

    return {
      key: normalizeStorageKey(input.key),
      url: this.getPublicUrl(input.key, visibility),
      contentType: input.contentType,
      size: stat.size,
      visibility
    };
  }

  async deleteObject(key: string): Promise<void> {
    const absolutePath = this.resolveAbsolutePath(key);
    await fs.promises.rm(absolutePath, { force: true });
  }

  getPublicUrl(
    key: string,
    _visibility: StorageVisibility = 'public'
  ): string {
    return buildPublicUrl(
      this.config,
      normalizeStorageKey(key)
    );
  }

  async readObject(
    key: string,
    request: StorageReadRequest
  ): Promise<StorageReadResult> {
    const absolutePath = this.resolveAbsolutePath(key);

    try {
      return await createLocalReadResult(absolutePath, request);
    } catch (error) {
      const maybeError = error as NodeJS.ErrnoException;
      if (maybeError.code === 'ENOENT') {
        throw new StorageHttpError(404, '文件不存在');
      }
      throw error;
    }
  }
}
