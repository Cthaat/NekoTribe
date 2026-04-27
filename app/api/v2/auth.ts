import {
  toV2PagedResult,
  v2Request,
  v2RequestData
} from './client';
import type {
  V2AuthOtpData,
  V2AuthOtpPayload,
  V2AuthOtpVerificationData,
  V2AuthOtpVerificationPayload,
  V2LoginData,
  V2LoginPayload,
  V2PagedResult,
  V2PasswordResetPayload,
  V2RegistrationPayload,
  V2SessionItem,
  V2TokenData
} from '@/types/v2';

export async function v2CreateOtp(
  payload: V2AuthOtpPayload
): Promise<V2AuthOtpData> {
  return await v2RequestData<V2AuthOtpData, V2AuthOtpPayload>(
    '/api/v2/auth/otp',
    {
      method: 'POST',
      body: payload
    }
  );
}

export async function v2VerifyOtp(
  payload: V2AuthOtpVerificationPayload
): Promise<V2AuthOtpVerificationData> {
  return await v2RequestData<
    V2AuthOtpVerificationData,
    V2AuthOtpVerificationPayload
  >('/api/v2/auth/otp/verification', {
    method: 'POST',
    body: payload
  });
}

export async function v2Register(
  payload: V2RegistrationPayload
) {
  return await v2RequestData<
    {
      user: import('./types').V2SelfUser;
    },
    V2RegistrationPayload
  >('/api/v2/auth/registration', {
    method: 'POST',
    body: payload
  });
}

export async function v2Login(
  payload: V2LoginPayload
): Promise<V2LoginData> {
  return await v2RequestData<V2LoginData, V2LoginPayload>(
    '/api/v2/auth/tokens',
    {
      method: 'POST',
      body: payload
    }
  );
}

export async function v2RefreshCurrentToken(): Promise<V2TokenData> {
  return await v2RequestData<V2TokenData>(
    '/api/v2/auth/tokens/current',
    {
      method: 'PATCH'
    }
  );
}

export async function v2LogoutCurrent(): Promise<void> {
  await v2RequestData<null>('/api/v2/auth/tokens/current', {
    method: 'DELETE'
  });
}

export async function v2PasswordReset(
  payload: V2PasswordResetPayload
): Promise<void> {
  await v2RequestData<null, V2PasswordResetPayload>(
    '/api/v2/auth/password-reset',
    {
      method: 'POST',
      body: payload
    }
  );
}

export async function v2ListSessions(query: {
  page?: number;
  page_size?: number;
} = {}): Promise<V2PagedResult<V2SessionItem>> {
  const response = await v2Request<
    V2SessionItem[],
    undefined,
    typeof query
  >('/api/v2/auth/sessions', {
    method: 'GET',
    query
  });
  return toV2PagedResult(response);
}

export async function v2RevokeSession(
  sessionId: string
): Promise<void> {
  await v2RequestData<null>(`/api/v2/auth/sessions/${sessionId}`, {
    method: 'DELETE'
  });
}

export async function v2RevokeOtherSessions(): Promise<{
  revoked_count: number;
}> {
  return await v2RequestData<{
    revoked_count: number;
  }>('/api/v2/auth/sessions/others', {
    method: 'DELETE'
  });
}

