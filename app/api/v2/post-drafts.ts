import type { V2PostDraft, V2PostDraftInput, V2PostDraftList } from '@/types/v2';
import { v2RequestData } from './client';

const base = '/api/v2/users/me/drafts';

function confirmsDraft(draft: V2PostDraft, id: number | null, status: V2PostDraft['status']): V2PostDraft {
  if (!draft || !Number.isSafeInteger(draft.draft_id) || draft.draft_id < 1 ||
      (id !== null && draft.draft_id !== id) || draft.status !== status) {
    throw new Error('Unconfirmed draft operation');
  }
  return draft;
}

export function v2ListPostDrafts(groupId: number | null, beforeId: number | null, signal?: AbortSignal) {
  return v2RequestData<V2PostDraftList, undefined, {group_id?:number;before_id?:number}>(base, {
    query:{group_id:groupId ?? undefined,before_id:beforeId ?? undefined}, signal,
  });
}

export async function v2SavePostDraft(payload: V2PostDraftInput, id: number | null, signal?: AbortSignal) {
  const draft = await v2RequestData<V2PostDraft, V2PostDraftInput>(id === null ? base : `${base}/${id}`, {
    method:id === null ? 'POST' : 'PUT', body:payload, signal,
  });
  if (draft?.payload?.group_id !== payload.group_id) throw new Error('Unconfirmed draft scope');
  return confirmsDraft(draft,id,'draft');
}

export function v2DeletePostDraft(id: number, signal?: AbortSignal) {
  return v2RequestData<null>(`${base}/${id}`, {method:'DELETE',signal});
}

export async function v2SchedulePostDraft(id: number, at: string, signal?: AbortSignal) {
  const draft = await v2RequestData<V2PostDraft, {scheduled_at:string}>(`${base}/${id}/schedule`, {
    method:'PUT',body:{scheduled_at:at},signal,
  });
  return confirmsDraft(draft,id,'scheduled');
}

export async function v2UnschedulePostDraft(id: number, signal?: AbortSignal) {
  const draft = await v2RequestData<V2PostDraft>(`${base}/${id}/schedule`, {method:'DELETE',signal});
  return confirmsDraft(draft,id,'draft');
}

export async function v2PublishPostDraft(id: number, signal?: AbortSignal) {
  const draft = confirmsDraft(await v2RequestData<V2PostDraft>(`${base}/${id}/publish`, {method:'POST',signal}),id,'published');
  if (!Number.isSafeInteger(draft.published_post_id) || draft.published_post_id === null || draft.published_post_id < 1) {
    throw new Error('Unconfirmed draft publication');
  }
  return draft;
}
