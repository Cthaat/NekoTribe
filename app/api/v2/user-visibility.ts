import { toV2PagedResult, v2Request, v2RequestData } from './client';
import { currentSessionMutation } from './auth-mutation';
import type { V2PublicUser } from '@/types/v2';

export type VisibilityKind = 'blocks' | 'mutes';
export type VisibilityUser = V2PublicUser & { expires_at?: string | null };

export async function listUserVisibility(kind: VisibilityKind, page: number, pageSize: number) {
  return toV2PagedResult(await v2Request<VisibilityUser[], undefined, { page: number; page_size: number }>(
    `/api/v2/users/me/${kind}`,
    { query: { page, page_size: pageSize } }
  ));
}

export function setUserVisibility(kind: VisibilityKind, target: number, remove: boolean, expiresAt?: string) {
  return currentSessionMutation(() => v2RequestData<unknown, { expires_at: string } | undefined>(
    `/api/v2/users/me/${kind}/${target}`,
    { method: remove ? 'DELETE' : 'POST', body: kind === 'mutes' && !remove && expiresAt ? { expires_at: expiresAt } : undefined }
  ));
}
