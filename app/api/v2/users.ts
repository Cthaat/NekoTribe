import {
  toV2PagedResult,
  v2Request,
  v2RequestData
} from './client';
import type {
  V2AccountStatement,
  V2AccountDeletionData,
  V2AccountDeletionPayload,
  V2AvatarData,
  V2ChangeEmailData,
  V2ChangeEmailPayload,
  V2FollowUserData,
  V2PagedResult,
  V2PublicUser,
  V2SelfUser,
  V2StatementAppealData,
  V2StatementAppealPayload,
  V2StatementStatusData,
  V2TwoFactorConfirmData,
  V2TwoFactorConfirmPayload,
  V2TwoFactorDisablePayload,
  V2TwoFactorSetupData,
  V2TwoFactorSetupPayload,
  V2TwoFactorStatusData,
  V2UpdateSettingsPayload,
  V2UpdateStatementPayload,
  V2UpdateUserPayload,
  V2UserAnalytics,
  V2UserDailyAnalytics,
  V2UserSearchQuery,
  V2UserSettings
} from '@/types/v2';
import { decodeEmailChangeResponse } from './email-change-response';
import { currentSessionMutation } from './auth-mutation';
import { apiFetch } from '@/composables/useApi';
import { decodeSettingsResponse } from './settings-response';
import {
  decodeAccountDeletionResponse,
  decodeFactorConfirmResponse,
  decodeFactorDisableResponse,
  decodeFactorSetupResponse
} from './security-response';

export interface AccountUsage {
  ai_quota: { used_units: number | null; limit_units: number | null; window_seconds: number };
  media: { bytes: number; files: number };
  ai_history: { conversations: number };
}

export type AccountExportFormat = 'json' | 'markdown';

export function v2GetAccountUsage(signal?: AbortSignal) {
  return v2RequestData<AccountUsage>('/api/v2/users/me/usage', { signal });
}

export function v2DownloadAccountExport(format: AccountExportFormat, signal?: AbortSignal) {
  return apiFetch<Blob, 'blob'>('/api/v2/users/me/export', {
    query: { format },
    responseType: 'blob',
    cache: 'no-store',
    redirect: 'error',
    signal
  });
}

export async function v2GetMe(): Promise<V2SelfUser> {
  const response = await v2Request<V2SelfUser>('/api/v2/users/me', {
    method: 'GET'
  });
  const data = response?.data;
  if (
    response?.code !== 200 || response.message !== 'success' ||
    response.meta !== null || !data ||
    !Number.isSafeInteger(data.user_id) || data.user_id <= 0
  ) {
    throw new Error('Invalid current user profile response');
  }
  return data;
}

export async function v2PatchMe(
  payload: V2UpdateUserPayload
): Promise<V2SelfUser> {
  return await v2RequestData<
    V2SelfUser,
    V2UpdateUserPayload
  >('/api/v2/users/me', {
    method: 'PATCH',
    body: payload
  });
}

export async function v2DeleteMe(
  payload: V2AccountDeletionPayload
): Promise<V2AccountDeletionData> {
  const submitted = { ...payload };
  const response = await currentSessionMutation(() => v2Request<
    unknown,
    V2AccountDeletionPayload
  >('/api/v2/users/me', {
    method: 'DELETE',
    body: submitted
  }));
  return decodeAccountDeletionResponse(response);
}

export async function v2ChangeEmail(
  payload: V2ChangeEmailPayload
): Promise<V2ChangeEmailData> {
  const submitted = { ...payload };
  const response = await v2Request<
    unknown,
    V2ChangeEmailPayload
  >('/api/v2/users/me/email', {
    method: 'PATCH',
    body: submitted
  });
  return decodeEmailChangeResponse(response, submitted.new_email);
}

export async function v2UpdateAvatar(
  formData: FormData
): Promise<V2AvatarData> {
  return await v2RequestData<V2AvatarData, FormData>(
    '/api/v2/users/me/avatar',
    {
      method: 'PUT',
      body: formData
    }
  );
}

export async function v2GetSettings(): Promise<V2UserSettings> {
  return decodeSettingsResponse(await v2Request<unknown>(
    '/api/v2/users/me/settings',
    {
      method: 'GET'
    }
  ));
}

export async function v2PatchSettings(
  payload: V2UpdateSettingsPayload
): Promise<V2UserSettings> {
  return decodeSettingsResponse(await v2Request<
    unknown,
    V2UpdateSettingsPayload
  >('/api/v2/users/me/settings', {
    method: 'PATCH',
    body: payload
  }));
}

export async function v2StartTwoFactorSetup(
  payload: V2TwoFactorSetupPayload
): Promise<V2TwoFactorSetupData> {
  const response = await v2Request<
    unknown,
    V2TwoFactorSetupPayload
  >('/api/v2/users/me/two-factor/setup', {
    method: 'POST',
    body: payload
  });
  return decodeFactorSetupResponse(response);
}

export async function v2ConfirmTwoFactorSetup(
  payload: V2TwoFactorConfirmPayload
): Promise<V2TwoFactorConfirmData> {
  const response = await v2Request<
    unknown,
    V2TwoFactorConfirmPayload
  >('/api/v2/users/me/two-factor/confirm', {
    method: 'POST',
    body: payload
  });
  return decodeFactorConfirmResponse(response);
}

export async function v2DisableTwoFactor(
  payload: V2TwoFactorDisablePayload
): Promise<V2TwoFactorStatusData> {
  const response = await v2Request<
    unknown,
    V2TwoFactorDisablePayload
  >('/api/v2/users/me/two-factor', {
    method: 'DELETE',
    body: payload
  });
  return decodeFactorDisableResponse(response);
}

export async function v2ListAccountStatements(
  query: {
    page?: number;
    page_size?: number;
    status?: string;
    type?: string;
  } = {}
): Promise<V2PagedResult<V2AccountStatement>> {
  const response = await v2Request<
    V2AccountStatement[],
    undefined,
    typeof query
  >('/api/v2/users/me/account-statements', {
    method: 'GET',
    query
  });
  return toV2PagedResult(response);
}

export async function v2PatchAccountStatement(
  statementId: number,
  payload: V2UpdateStatementPayload
): Promise<V2StatementStatusData> {
  return await currentSessionMutation(() => v2RequestData<
    V2StatementStatusData,
    V2UpdateStatementPayload
  >(`/api/v2/users/me/account-statements/${statementId}`, {
    method: 'PATCH',
    body: payload
  }));
}

export async function v2CreateStatementAppeal(
  statementId: number,
  payload: V2StatementAppealPayload
): Promise<V2StatementAppealData> {
  return await currentSessionMutation(() => v2RequestData<
    V2StatementAppealData,
    V2StatementAppealPayload
  >(
    `/api/v2/users/me/account-statements/${statementId}/appeals`,
    {
      method: 'POST',
      body: payload
    }
  ));
}

export async function v2SearchUsers(
  query: V2UserSearchQuery,
  signal?: AbortSignal
): Promise<V2PagedResult<V2PublicUser>> {
  const response = await v2Request<
    V2PublicUser[],
    undefined,
    {
      q?: string;
      verified?: 'true' | 'false';
      sort?: 'popular' | 'newest' | 'oldest' | 'followers';
      page?: number;
      page_size?: number;
    }
  >('/api/v2/users', {
    method: 'GET',
    signal,
    query: {
      q: query.q,
      verified:
        query.verified === undefined
          ? undefined
          : query.verified
            ? 'true'
            : 'false',
      sort: query.sort,
      page: query.page,
      page_size: query.page_size
    }
  });
  return toV2PagedResult(response);
}

export async function v2GetUserById(
  userId: number
): Promise<V2PublicUser> {
  const user = await v2RequestData<V2PublicUser>(
    `/api/v2/users/${userId}`,
    {
      method: 'GET'
    }
  );
  if (!user || !Number.isSafeInteger(user.user_id) || user.user_id <= 0 || user.user_id !== userId) {
    throw new Error('Invalid public profile response');
  }
  return user;
}

export function v2RecommendedUsers(limit: number): Promise<V2PublicUser[]> {
  return v2RequestData<V2PublicUser[], undefined, { limit: number }>(
    '/api/v2/users/recommendations',
    { method: 'GET', query: { limit } }
  );
}

export async function v2GetUserAnalytics(
  userId: number
): Promise<V2UserAnalytics> {
  return await v2RequestData<V2UserAnalytics>(
    `/api/v2/users/${userId}/analytics`,
    {
      method: 'GET'
    }
  );
}

export async function v2GetUserDailyAnalytics(
  userId: number,
  query: {
    days?: number;
  } = {},
  signal?: AbortSignal
): Promise<V2UserDailyAnalytics[]> {
  return await v2RequestData<V2UserDailyAnalytics[]>(
    `/api/v2/users/${userId}/analytics/daily`,
    {
      method: 'GET',
      query,
      signal
    }
  );
}

export async function v2ListUserFollowers(
  userId: number,
  query: {
    page?: number;
    page_size?: number;
  } = {}
): Promise<V2PagedResult<V2PublicUser>> {
  const response = await v2Request<
    V2PublicUser[],
    undefined,
    typeof query
  >(`/api/v2/users/${userId}/followers`, {
    method: 'GET',
    query
  });
  return toV2PagedResult(response);
}

export async function v2ListUserFollowing(
  userId: number,
  query: {
    page?: number;
    page_size?: number;
  } = {}
): Promise<V2PagedResult<V2PublicUser>> {
  const response = await v2Request<
    V2PublicUser[],
    undefined,
    typeof query
  >(`/api/v2/users/${userId}/following`, {
    method: 'GET',
    query
  });
  return toV2PagedResult(response);
}

export async function v2FollowUser(
  userId: number
): Promise<V2FollowUserData> {
  return await v2RequestData<V2FollowUserData>(
    `/api/v2/users/${userId}/followers`,
    {
      method: 'POST'
    }
  );
}

export async function v2UnfollowUser(
  userId: number
): Promise<V2FollowUserData> {
  return await v2RequestData<V2FollowUserData>(
    `/api/v2/users/${userId}/followers`,
    {
      method: 'DELETE'
    }
  );
}
