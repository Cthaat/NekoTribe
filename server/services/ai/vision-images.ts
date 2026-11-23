import type { Connection } from 'oracledb';
import policy from '../../../specifications/requirements/ai-vision.json';
import { getStorageProvider } from '~/server/storage';
import { StorageHttpError } from '../../storage/http';
import { v2Rows } from '~/server/utils/v2';
import { imageReference, mediaFromRow, type ImageReference, type VisionMedia } from './vision-image-record';

export type VisionImage = { mime_type: string; data: string };

export function hasImageSignature(bytes: Buffer, mime: string): boolean {
  if (mime === 'image/jpeg') return bytes.length >= 3 && bytes.subarray(0,3).equals(Buffer.from([255,216,255]));
  if (mime === 'image/png') return bytes.length >= 8 && bytes.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10]));
  return mime === 'image/webp' && bytes.length >= 12 &&
    bytes.toString('ascii',0,4) === 'RIFF' && bytes.toString('ascii',8,12) === 'WEBP';
}

export async function readImage(media: VisionMedia, signal: AbortSignal): Promise<VisionImage | null> {
  signal.throwIfAborted();
  try {
    const storage = getStorageProvider();
    const result = media.scope === 'post' ? await storage.readPrivateObject(media.key,{}) : await storage.readObject(media.key,{});
    const {stream} = result;
    const stop = () => stream.destroy();
    const chunks: Buffer[] = [];
    let size = 0;
    signal.addEventListener('abort', stop, {once:true});
    try {
      signal.throwIfAborted();
      if (result.statusCode !== 200) return null;
      for await (const chunk of stream) {
        if (!Buffer.isBuffer(chunk)) return null;
        size += chunk.length;
        if (size > media.size) return null;
        chunks.push(chunk);
      }
      if (size !== media.size) return null;
      const bytes = Buffer.concat(chunks, size);
      if (!hasImageSignature(bytes, media.mime)) return null;
      return {mime_type:media.mime,data:bytes.toString('base64')};
    } finally {
      signal.removeEventListener('abort', stop);
      stream.destroy();
    }
  } catch (error) {
    signal.throwIfAborted();
    if (error instanceof StorageHttpError && error.statusCode === 404) return null;
    throw error;
  }
}

export async function readModerationImageMedia(connection: Connection, actorId: number, kind: 'post' | 'group_post', postId: number): Promise<VisionMedia[]> {
  const query = kind === 'group_post' ? policy.sql.moderation_group_images : policy.sql.moderation_images;
  const rows = await v2Rows(connection, query, {viewer_id:actorId,post_id:postId});
  return rows.map(mediaFromRow).filter((row): row is VisionMedia => row?.scope === 'public');
}

export async function prepareModerationImages(media: VisionMedia[], signal: AbortSignal) {
  const images: VisionImage[] = [];
  const refs: ImageReference[] = [];
  let bytes = 0;
  for (const item of media) {
    if (bytes + item.size > policy.max_total_image_bytes) continue;
    const image = await readImage(item, signal).catch(() => {
      signal.throwIfAborted();
      return null;
    });
    if (image) {
      images.push(image);
      refs.push(imageReference(item));
      bytes += item.size;
    }
  }
  return {images,refs};
}
