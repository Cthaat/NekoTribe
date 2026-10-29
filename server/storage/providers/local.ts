import fs from 'node:fs';
import path from 'node:path';
import {normalizeLocalStorageKey,resolveLocalStoragePath} from '../local-path';
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

  private async resolveAbsolutePath(key: string,createParents=false): Promise<string> {
    return await resolveLocalStoragePath(this.config.rootPath,key,createParents);
  }


  private async moveFile(
    sourcePath: string,
    targetPath: string
  ): Promise<void> {
    await fs.promises.copyFile(sourcePath,targetPath,fs.constants.COPYFILE_EXCL);
    await fs.promises.rm(sourcePath,{force:true});
  }

  async saveFromPath(
    input: StorageSaveInput
  ): Promise<StoredObject> {
    const visibility: StorageVisibility =
      input.visibility || 'public';
    const key=normalizeLocalStorageKey(input.key);
    const absolutePath = await this.resolveAbsolutePath(key,true);
    const stat=await fs.promises.stat(input.sourcePath);
    if(!stat.isFile())throw new StorageHttpError(400,'上传文件不可用');
    await this.moveFile(input.sourcePath, absolutePath);

    return {
      key,
      url: this.getPublicUrl(input.key, visibility),
      contentType: input.contentType,
      size: stat.size,
      visibility
    };
  }

  async deleteObject(key: string): Promise<void> {
    try {
      const absolutePath = await this.resolveAbsolutePath(key);
      await fs.promises.rm(absolutePath, { force: true });
    } catch(error) { if((error as NodeJS.ErrnoException).code!=='ENOENT')throw error; }
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
    try {
      const normalized=normalizeLocalStorageKey(key);
      if(normalized.split('/')[0]!.toLowerCase()==='temp')throw new StorageHttpError(404,'文件不存在');
      const absolutePath = await this.resolveAbsolutePath(key);
      return await createLocalReadResult(absolutePath, request);
    } catch (error) {
      const maybeError = error as NodeJS.ErrnoException;
      if (maybeError.code === 'ENOENT') {
        throw new StorageHttpError(404, '文件不存在');
      }
      if (maybeError.code === 'ELOOP') throw new StorageHttpError(400,'非法存储路径');
      throw error;
    }
  }
}
