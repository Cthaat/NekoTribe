import type oracledb from 'oracledb';
import { normalizeLocalStorageKey } from '~/server/storage/local-path';
import { v2One } from '~/server/utils/v2';
import policy from '../../../specifications/requirements/media-private-bind.json';

type PrivateTarget = { scope: 'chat' } | { scope: 'post'; postId: number };

// Called after locking the media row. A separate query sees associations
// committed while this transaction was waiting to acquire the row lock.
export async function canBindMedia(
  connection: oracledb.Connection,
  mediaId: number,
  storageKey: unknown,
  target: PrivateTarget | null
): Promise<boolean> {
  if (typeof storageKey !== 'string' || !storageKey) return false;
  if (storageKey.replaceAll('\\', '/').split('/')[0]?.toLowerCase() !== 'private') return true;
  if (!target) return false;

  let key: string;
  try { key = normalizeLocalStorageKey(storageKey); }
  catch { return false; }
  if (!key.startsWith(`private/${target.scope}/`)) return false;

  try {
    const row = await v2One(connection, policy[target.scope], {
      media_id: mediaId,
      ...(target.scope === 'post' ? { post_id: target.postId } : {})
    });
    return row !== null;
  } catch (error) {
    if (typeof error === 'object' && error !== null && (
      ('errorNum' in error && (error.errorNum === 904 || error.errorNum === 942)) ||
      ('code' in error && (error.code === 'ORA-00904' || error.code === 'ORA-00942'))
    )) return false;
    throw error;
  }
}

export async function postRetainsPrivateMedia(
  connection: oracledb.Connection,
  postId: number
): Promise<boolean> {
  return (await v2One(connection, policy.retained, { post_id: postId })) !== null;
}
