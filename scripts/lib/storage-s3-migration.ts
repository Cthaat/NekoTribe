import { createHash } from 'node:crypto';
import { constants } from 'node:fs';
import { open, readFile, realpath, stat } from 'node:fs/promises';
import { inferMimeType } from '../../server/storage/http';
import { resolveLocalStoragePath } from '../../server/storage/local-path';
import { managedKey, putS3File } from '../../server/storage/providers/s3';
import { requestS3 } from '../../server/storage/providers/s3-request';

const maxManifestBytes = 32*1024*1024;

async function manifestKeys(path: string): Promise<string[]> {
  const file = await stat(path);
  if (!file.isFile() || file.size > maxManifestBytes) throw Error('INVALID_MANIFEST');
  const bytes = await readFile(path);
  if (bytes.length > maxManifestBytes) throw Error('INVALID_MANIFEST');
  const raw: unknown = JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
  if (!Array.isArray(raw) || !raw.length || raw.length > 100000) throw Error('INVALID_MANIFEST');
  const keys = new Set<string>();
  for (const key of raw as unknown[]) {
    if (typeof key !== 'string' || !key.isWellFormed() || Buffer.byteLength(key) > 1024 || keys.has(key)) throw Error('INVALID_MANIFEST');
    if (managedKey(key) !== key) throw Error('INVALID_MANIFEST');
    keys.add(key);
  }
  return [...keys];
}

async function verifyObject(key: string, expectedSize: number, digest: string) {
  const response = await requestS3('GET',key);
  try {
    if (response.statusCode !== 200 || response.headers['content-length'] !== String(expectedSize)) {
      throw Error('REMOTE_OBJECT_MISMATCH');
    }
    const hash = createHash('sha256');
    let length = 0;
    for await (const chunk of response) {
      length += chunk.length;
      if (length > expectedSize) throw Error('REMOTE_OBJECT_MISMATCH');
      hash.update(chunk);
    }
    if (length !== expectedSize || hash.digest('hex') !== digest) throw Error('REMOTE_OBJECT_MISMATCH');
  } finally {
    response.destroy();
  }
}

export async function migrateStorage({root,manifest,apply}: {root:string; manifest:string; apply:boolean}) {
  const keys = await manifestKeys(manifest);
  const directory = await realpath(root);
  if (!(await stat(directory)).isDirectory()) throw Error('INVALID_STORAGE_ROOT');
  let bytes = 0, copied = 0, existing = 0;
  for (const key of keys) {
    try {
      const path = await resolveLocalStoragePath(directory,key);
      const file = await open(path,constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
      try {
        const info = await file.stat();
        if (!info.isFile() || info.size < 1 || !Number.isSafeInteger(bytes+info.size)) throw Error('INVALID_SOURCE_OBJECT');
        bytes += info.size;
        if (!apply) continue;
        const result = await putS3File(file,key,inferMimeType(key));
        if (result.status !== 200 && result.status !== 412) throw Error('REMOTE_UPLOAD_FAILED');
        await verifyObject(key,result.size,result.digest);
        const current = await file.stat();
        if (current.size !== info.size || current.mtimeMs !== info.mtimeMs || current.ctimeMs !== info.ctimeMs || result.size !== info.size) throw Error('SOURCE_OBJECT_CHANGED');
        if (result.status === 200) copied++;
        else existing++;
      } finally { await file.close(); }
    } catch (error) {
      const message = error instanceof Error ? error.message : '';
      const code = /^[A-Z_]{4,48}$/.test(message) ? message : 'OBJECT_UNAVAILABLE';
      throw Error(`${code} ${key}`,{cause:error});
    }
  }
  return {mode:apply?'apply':'plan',objects:keys.length,bytes,copied,existing};
}
