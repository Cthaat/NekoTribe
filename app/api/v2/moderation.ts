import {
  toV2PagedResult,
  v2Request,
  v2RequestData,
  type V2QueryValue
} from './client';
import type {
  V2CreateReportPayload,
  V2ModerationActionPayload,
  V2ModerationContentItem,
  V2ModerationReport,
  V2ModerationSetting,
  V2ModerationSettingsPayload,
  V2ModerationStats,
  V2ModerationUserActionPayload,
  V2ModerationUserItem,
  V2PagedResult
} from '@/types/v2';

export interface V2ModerationContentQuery
  extends Record<string, V2QueryValue> {
  q?: string;
  status?: string;
  reason?: string;
  date_range?: string;
  sort?: string;
  page?: number;
  page_size?: number;
}

export interface V2ModerationReportsQuery
  extends Record<string, V2QueryValue> {
  status?: string;
  reason?: string;
  target_type?: string;
  page?: number;
  page_size?: number;
}

export interface V2ModerationUsersQuery
  extends Record<string, V2QueryValue> {
  q?: string;
  status?: string;
  sort?: string;
  page?: number;
  page_size?: number;
}

export async function v2GetModerationStats(): Promise<V2ModerationStats> {
  return await v2RequestData<V2ModerationStats>(
    '/api/v2/moderation/stats',
    {
      method: 'GET'
    }
  );
}

export async function v2ListModerationContent(
  query: V2ModerationContentQuery = {}
): Promise<V2PagedResult<V2ModerationContentItem>> {
  const response = await v2Request<
    V2ModerationContentItem[],
    undefined,
    V2ModerationContentQuery
  >('/api/v2/moderation/content', {
    method: 'GET',
    query
  });
  return toV2PagedResult(response);
}

export async function v2ModeratePost(
  postId: number,
  payload: V2ModerationActionPayload
): Promise<V2ModerationContentItem> {
  return await v2RequestData<
    V2ModerationContentItem,
    V2ModerationActionPayload
  >(`/api/v2/moderation/content/${postId}/actions`, {
    method: 'POST',
    body: payload
  });
}

export async function v2BulkModeratePosts(payload: {
  post_ids: number[];
  action: 'approve' | 'reject' | 'flag' | 'remove' | 'restore';
  note?: string;
  reason?: string;
}): Promise<{ processed_count: number }> {
  return await v2RequestData<
    { processed_count: number },
    typeof payload
  >('/api/v2/moderation/content/bulk-actions', {
    method: 'POST',
    body: payload
  });
}

export async function v2ListModerationReports(
  query: V2ModerationReportsQuery = {}
): Promise<V2PagedResult<V2ModerationReport>> {
  const response = await v2Request<
    V2ModerationReport[],
    undefined,
    V2ModerationReportsQuery
  >('/api/v2/moderation/reports', {
    method: 'GET',
    query
  });
  return toV2PagedResult(response);
}

export async function v2PatchModerationReport(
  reportId: number,
  status: V2ModerationReport['status']
): Promise<V2ModerationReport> {
  return await v2RequestData<
    V2ModerationReport,
    { status: V2ModerationReport['status'] }
  >(`/api/v2/moderation/reports/${reportId}`, {
    method: 'PATCH',
    body: { status }
  });
}

export async function v2ListModerationUsers(
  query: V2ModerationUsersQuery = {}
): Promise<V2PagedResult<V2ModerationUserItem>> {
  const response = await v2Request<
    V2ModerationUserItem[],
    undefined,
    V2ModerationUsersQuery
  >('/api/v2/moderation/users', {
    method: 'GET',
    query
  });
  return toV2PagedResult(response);
}

export async function v2ModerateUser(
  userId: number,
  payload: V2ModerationUserActionPayload
): Promise<V2ModerationUserItem> {
  return await v2RequestData<
    V2ModerationUserItem,
    V2ModerationUserActionPayload
  >(`/api/v2/moderation/users/${userId}/actions`, {
    method: 'POST',
    body: payload
  });
}

export async function v2GetModerationSettings(): Promise<
  V2ModerationSetting[]
> {
  return await v2RequestData<V2ModerationSetting[]>(
    '/api/v2/moderation/settings',
    {
      method: 'GET'
    }
  );
}

export async function v2PatchModerationSettings(
  payload: V2ModerationSettingsPayload
): Promise<V2ModerationSetting[]> {
  return await v2RequestData<
    V2ModerationSetting[],
    V2ModerationSettingsPayload
  >('/api/v2/moderation/settings', {
    method: 'PATCH',
    body: payload
  });
}

export async function v2CreateReport(
  payload: V2CreateReportPayload
): Promise<V2ModerationReport> {
  return await v2RequestData<
    V2ModerationReport,
    V2CreateReportPayload
  >('/api/v2/reports', {
    method: 'POST',
    body: payload
  });
}
