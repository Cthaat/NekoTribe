import type { V2Post } from '@/types/v2';
import { v2RequestData } from './client';

const ownPin = '/api/v2/users/me/pinned-post';

export async function v2GetProfilePin(profileId: number, signal?: AbortSignal): Promise<V2Post | null> {
  const data = await v2RequestData<{post: V2Post | null}>(`/api/v2/users/${profileId}/pinned-post`, {signal});
  if (!data || (data.post !== null && data.post?.author?.user_id !== profileId)) throw new Error('Invalid profile pin');
  return data.post;
}

export async function v2SetProfilePin(postId: number, signal?: AbortSignal) {
  const data = await v2RequestData<{post_id:number},{post_id:number}>(ownPin,{method:'PUT',body:{post_id:postId},signal});
  if (data?.post_id !== postId) throw new Error('Unconfirmed profile pin');
}

export async function v2ClearProfilePin(signal?: AbortSignal) {
  if (await v2RequestData<null>(ownPin,{method:'DELETE',signal}) !== null) throw new Error('Unconfirmed profile unpin');
}
