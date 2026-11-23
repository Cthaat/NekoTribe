import { createHash } from 'node:crypto';
import type { Connection } from 'oracledb';
import policy from '../../../specifications/requirements/ai-vision.json';
import { normalizeLocalStorageKey } from '../../storage/local-path';
import { v2One } from '~/server/utils/v2';

export type ImageReference = { media_id: number; version: string };
export type VisionMedia = { id: number; key: string; scope: 'public' | 'post'; mime: string; size: number };
const validId = (value: unknown): value is number =>
  typeof value === 'number' && Number.isSafeInteger(value) && value > 0;

export function validImageReferences(value: unknown): value is ImageReference[] {
  if (!Array.isArray(value) || value.length < 1 || value.length > policy.max_images) return false;
  const ids = new Set<number>();
  for (const ref of value) {
    if (!ref || typeof ref !== 'object' || Object.keys(ref).length !== 2 || !validId(ref.media_id) ||
        typeof ref.version !== 'string' || !/^[0-9a-f]{64}$/.test(ref.version) || ids.has(ref.media_id)) return false;
    ids.add(ref.media_id);
  }
  return true;
}

export function mediaFromRow(row: Record<string, unknown>): VisionMedia | null {
  const {MEDIA_ID:id, STORAGE_KEY:key, ACCESS_SCOPE:scope, MIME_TYPE:mime, FILE_SIZE:size} = row;
  if (!validId(id) || typeof key !== 'string' || (scope !== 'public' && scope !== 'post') ||
      typeof mime !== 'string' || !policy.mime_types.includes(mime) ||
      !validId(size) || size > policy.max_image_bytes) return null;
  try {
    if (normalizeLocalStorageKey(key) !== key) return null;
  } catch { return null; }
  if (scope === 'post' ? !key.startsWith('private/post/') : key.toLowerCase().startsWith('private/')) return null;
  return {id,key,scope,mime,size};
}
export function imageReference(media: VisionMedia): ImageReference {
  return {media_id:media.id,version:createHash('sha256')
    .update([media.id,media.key,media.mime,media.size].join('\n')).digest('hex')};
}
export async function moderationImagesCurrent(connection: Connection, actorId: number, kind: 'post' | 'group_post', postId: number, refs: ImageReference[]) {
  const query = kind === 'group_post' ? policy.sql.moderation_group_image : policy.sql.moderation_image;
  for (const ref of refs) {
    const row = await v2One(connection, query, {viewer_id:actorId,post_id:postId,media_id:ref.media_id});
    const media = row && mediaFromRow(row);
    if (media?.scope !== 'public' || media.id !== ref.media_id || imageReference(media).version !== ref.version) return false;
  }
  return true;
}
