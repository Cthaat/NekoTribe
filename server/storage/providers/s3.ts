import { createHash } from 'node:crypto';
import { constants } from 'node:fs';
import { open, unlink, type FileHandle } from 'node:fs/promises';
import { Readable } from 'node:stream';
import { inferMimeType, StorageHttpError } from '../http';
import { isPrivateStorageKey, normalizeLocalStorageKey } from '../local-path';
import type {
  StorageCapabilities, StorageConfig, StorageProvider, StorageReadRequest,
  StorageReadResult, StorageSaveInput, StorageVisibility, StoredObject
} from '../types';
import { requestS3, s3Unavailable } from './s3-request';

export function managedKey(raw: string): string {
  const key = normalizeLocalStorageKey(raw);
  if (!key.startsWith('posts/') && !key.startsWith('avatars/')) throw new StorageHttpError(404,'文件不存在');
  return key;
}

function discardResponse(response: Awaited<ReturnType<typeof requestS3>>) {
  response.on('error',()=>{});
  response.resume();
}

async function* fileChunks(file: FileHandle, size: number) {
  let offset = 0;
  while (offset < size) {
    const buffer = Buffer.allocUnsafe(Math.min(65536,size-offset));
    const {bytesRead} = await file.read(buffer,0,buffer.length,offset);
    if (!bytesRead) throw new StorageHttpError(400,'上传文件不可用');
    offset += bytesRead;
    yield buffer.subarray(0,bytesRead);
  }
}

export async function putS3File(file: FileHandle, raw: string, contentType: string) {
  return putObject(file, managedKey(raw), contentType);
}

async function putObject(file: FileHandle, key: string, contentType: string) {
  const stat = await file.stat();
  if (!stat.isFile() || stat.size < 1) throw new StorageHttpError(400,'上传文件不可用');
  const hash = createHash('sha256');
  for await (const chunk of fileChunks(file,stat.size)) hash.update(chunk);
  const digest = hash.digest('hex');
  const body = Readable.from(fileChunks(file,stat.size),{objectMode:false});
  try {
    const response = await requestS3('PUT',key,{digest,body,headers:{
      'content-type':contentType,'content-length':String(stat.size),'if-none-match':'*',
      ...(isPrivateStorageKey(key) ? {'cache-control':'private, no-store'} : {})
    }});
    discardResponse(response);
    return {status:response.statusCode,size:stat.size,digest};
  } finally {
    body.destroy();
  }
}

export class S3StorageProvider implements StorageProvider {
  readonly type = 's3' as const;
  readonly capabilities: StorageCapabilities = {multipartUpload:false,cdn:true,privateObjects:true};

  constructor(private readonly config: StorageConfig) {}

  async saveFromPath(input: StorageSaveInput): Promise<StoredObject> {
    const visibility = input.visibility ?? 'public';
    const key = normalizeLocalStorageKey(input.key);
    if (visibility === 'private' && !isPrivateStorageKey(key)) {
      throw new StorageHttpError(400, '非法存储路径');
    }
    const url = visibility === 'private' ? '' : this.getPublicUrl(key);
    const file = await open(input.sourcePath,constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
    let size: number;
    try {
      const stored = await putObject(file,key,input.contentType);
      if (stored.status !== 200) throw s3Unavailable();
      size = stored.size;
    } finally { await file.close(); }
    await unlink(input.sourcePath).catch((error: NodeJS.ErrnoException)=>{
      if (error.code !== 'ENOENT') console.warn('media upload temporary cleanup unavailable');
    });
    return {key,url,contentType:input.contentType,size,visibility};
  }

  async deleteObject(raw: string): Promise<void> {
    const key = normalizeLocalStorageKey(raw);
    const response = await requestS3('DELETE',isPrivateStorageKey(key) ? key : managedKey(key));
    discardResponse(response);
    if (response.statusCode !== 204 && response.statusCode !== 404) throw s3Unavailable();
  }

  getPublicUrl(raw: string, visibility: StorageVisibility = 'public'): string {
    if (visibility !== 'public') throw new StorageHttpError(404,'文件不存在');
    const relativePath = `${this.config.publicBasePath}/${managedKey(raw)}`;
    const baseUrl = this.config.cdnBaseUrl || this.config.publicBaseUrl;
    return baseUrl ? new URL(relativePath,`${baseUrl}/`).toString() : relativePath;
  }

  async readObject(raw: string, request: StorageReadRequest): Promise<StorageReadResult> {
    return this.readFile(managedKey(raw), request);
  }

  async readPrivateObject(raw: string, request: StorageReadRequest): Promise<StorageReadResult> {
    const key = normalizeLocalStorageKey(raw);
    if (!isPrivateStorageKey(key)) {
      throw new StorageHttpError(404, '文件不存在');
    }
    return this.readFile(key, request);
  }

  private async unsatisfiedRange(key: string, contentRange?: string): Promise<StorageHttpError> {
    if (!contentRange || !/^bytes \*\/\d+$/.test(contentRange)) {
      const metadata = await requestS3('HEAD', key);
      const length = metadata.headers['content-length'];
      metadata.destroy();
      if (metadata.statusCode === 404) return new StorageHttpError(404, '文件不存在');
      if (metadata.statusCode !== 200 || typeof length !== 'string' || !/^\d+$/.test(length)) {
        return s3Unavailable();
      }
      contentRange = `bytes */${length}`;
    }
    return new StorageHttpError(416, 'Requested range not satisfiable', { 'Content-Range': contentRange });
  }

  private async readFile(key: string, request: StorageReadRequest): Promise<StorageReadResult> {
    const value = request.headOnly ? undefined : request.rangeHeader?.trim();
    const range = value ? /^bytes=(\d{0,16})-(\d{0,16})$/i.exec(value) : null;
    if (value && (!range || (!range[1] && !range[2]))) throw await this.unsatisfiedRange(key);
    const response = await requestS3(request.headOnly ? 'HEAD' : 'GET',key,{headers:range ? {range:`bytes=${range[1]}-${range[2]}`} : {}});
    const headers: Record<string,string> = {
      'Accept-Ranges':'bytes','Cache-Control':'public, max-age=31536000, immutable',
      'Content-Type':inferMimeType(key),'X-Content-Type-Options':'nosniff'
    };
    const contentRange = response.headers['content-range'];
    if (typeof contentRange === 'string' && /^bytes \d+-\d+\/\d+$/.test(contentRange)) headers['Content-Range'] = contentRange;
    if (response.statusCode !== (range ? 206 : 200) || (range && !/^bytes \d+-\d+\/\d+$/.test(headers['Content-Range'] ?? ''))) {
      response.destroy();
      if (response.statusCode === 404) throw new StorageHttpError(404,'文件不存在');
      if (range && response.statusCode === 416) throw await this.unsatisfiedRange(key, contentRange);
      throw s3Unavailable();
    }
    for (const [source,target] of [['content-length','Content-Length'],['etag','ETag'],['last-modified','Last-Modified']] as const) {
      const value = response.headers[source];
      if (typeof value === 'string') headers[target] = value;
    }
    return {statusCode:response.statusCode,headers,stream:response};
  }
}
