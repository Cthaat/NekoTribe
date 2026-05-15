import {
  toV2PagedResult,
  v2Request,
  v2RequestData
} from './client';
import type {
  V2AccountStatement,
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
  V2UpdateSettingsPayload,
  V2UpdateStatementPayload,
  V2UpdateUserPayload,
  V2UserAnalytics,
  V2UserDailyAnalytics,
  V2UserSearchQuery,
  V2UserSettings
} from '@/types/v2';

export async function v2GetMe(): Promise<V2SelfUser> {
  return await v2RequestData<V2SelfUser>(
    '/api/v2/users/me',
    {
      method: 'GET'
    }
  );
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

export async function v2ChangeEmail(
  payload: V2ChangeEmailPayload
): Promise<V2ChangeEmailData> {
  return await v2RequestData<
    V2ChangeEmailData,
    V2ChangeEmailPayload
  >('/api/v2/users/me/email', {
    method: 'PATCH',
    body: payload
  });
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
  return await v2RequestData<V2UserSettings>(
    '/api/v2/users/me/settings',
    {
      method: 'GET'
    }
  );
}

export async function v2PatchSettings(
  payload: V2UpdateSettingsPayload
): Promise<V2UserSettings> {
  return await v2RequestData<
    V2UserSettings,
    V2UpdateSettingsPayload
  >('/api/v2/users/me/settings', {
    method: 'PATCH',
    body: payload
  });
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
  return await v2RequestData<
    V2StatementStatusData,
    V2UpdateStatementPayload
  >(`/api/v2/users/me/account-statements/${statementId}`, {
    method: 'PATCH',
    body: payload
  });
}

export async function v2CreateStatementAppeal(
  statementId: number,
  payload: V2StatementAppealPayload
): Promise<V2StatementAppealData> {
  return await v2RequestData<
    V2StatementAppealData,
    V2StatementAppealPayload
  >(
    `/api/v2/users/me/account-statements/${statementId}/appeals`,
    {
      method: 'POST',
      body: payload
    }
  );
}

export async function v2SearchUsers(
  query: V2UserSearchQuery
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
  return await v2RequestData<V2PublicUser>(
    `/api/v2/users/${userId}`,
    {
      method: 'GET'
    }
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
  } = {}
): Promise<V2UserDailyAnalytics[]> {
  return await v2RequestData<V2UserDailyAnalytics[]>(
    `/api/v2/users/${userId}/analytics/daily`,
    {
      method: 'GET',
      query
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
