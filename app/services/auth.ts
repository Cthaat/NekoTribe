import {
  v2CreateOtp as apiCreateOtp,
  v2Login as apiLogin,
  v2LogoutCurrent,
  v2PasswordReset as apiPasswordReset,
  v2RefreshCurrentToken as apiRefreshCurrentToken,
  v2Register as apiRegister,
  v2VerifyOtp as apiVerifyOtp
} from '@/api/v2/auth';
import type {
  V2AuthOtpData,
  V2AuthOtpPayload,
  V2AuthOtpVerificationData,
  V2AuthOtpVerificationPayload,
  V2LoginData,
  V2LoginPayload,
  V2PasswordResetPayload,
  V2RegistrationPayload,
  V2TokenData
} from '@/types/v2';
import type {
  AuthOtpFormVM,
  AuthOtpVerificationFormVM,
  AuthOtpVerificationVM,
  AuthOtpVM,
  AuthSessionVM,
  LoginFormVM,
  LoginVM,
  PasswordResetFormVM,
  RegistrationFormVM
} from '@/types/auth';
import { mapCurrentUser } from './users';

export {
  v2LogoutCurrent
};

function mapOtpForm(form: AuthOtpFormVM): V2AuthOtpPayload {
  return {
    account: form.account,
    type: form.type,
    channel: form.channel
  };
}

function mapOtp(dto: V2AuthOtpData): AuthOtpVM {
  return {
    account: dto.account,
    verificationId: dto.verification_id,
    expiresAt: dto.expires_at
  };
}

function mapVerifyOtpForm(
  form: AuthOtpVerificationFormVM
): V2AuthOtpVerificationPayload {
  return {
    account: form.account,
    type: form.type,
    verification_id: form.verificationId,
    code: form.code
  };
}

function mapVerifyOtp(
  dto: V2AuthOtpVerificationData
): AuthOtpVerificationVM {
  return {
    account: dto.account,
    verified: dto.verified,
    verifiedAt: dto.verified_at
  };
}

function mapRegistrationForm(
  form: RegistrationFormVM
): V2RegistrationPayload {
  return {
    email: form.email,
    username: form.username,
    password: form.password,
    confirm_password: form.confirmPassword,
    display_name: form.displayName,
    bio: form.bio,
    location: form.location,
    phone: form.phone,
    birth_date: form.birthDate,
    verification_id: form.verificationId,
    agree_to_terms: form.agreeToTerms
  };
}

function mapLoginForm(form: LoginFormVM): V2LoginPayload {
  return {
    account: form.account,
    password: form.password,
    remember_me: form.rememberMe
  };
}

function mapSession(dto: V2TokenData): AuthSessionVM {
  return {
    sessionId: dto.session_id,
    accessTokenExpiresAt: dto.access_token_expires_at,
    refreshTokenExpiresAt: dto.refresh_token_expires_at
  };
}

function mapLogin(dto: V2LoginData): LoginVM {
  return {
    user: mapCurrentUser(dto.user),
    tokens: mapSession(dto.tokens)
  };
}

function mapPasswordResetForm(
  form: PasswordResetFormVM
): V2PasswordResetPayload {
  return {
    email: form.email,
    verification_id: form.verificationId,
    code: form.code,
    new_password: form.newPassword
  };
}

export async function v2CreateOtp(
  form: AuthOtpFormVM
): Promise<AuthOtpVM> {
  return mapOtp(await apiCreateOtp(mapOtpForm(form)));
}

export async function v2VerifyOtp(
  form: AuthOtpVerificationFormVM
): Promise<AuthOtpVerificationVM> {
  return mapVerifyOtp(await apiVerifyOtp(mapVerifyOtpForm(form)));
}

export async function v2Register(
  form: RegistrationFormVM
): Promise<{ user: LoginVM['user'] }> {
  const result = await apiRegister(mapRegistrationForm(form));
  return {
    user: mapCurrentUser(result.user)
  };
}

export async function v2Login(
  form: LoginFormVM
): Promise<LoginVM> {
  return mapLogin(await apiLogin(mapLoginForm(form)));
}

export async function v2RefreshCurrentToken(): Promise<AuthSessionVM> {
  return mapSession(await apiRefreshCurrentToken());
}

export async function v2PasswordReset(
  form: PasswordResetFormVM
): Promise<void> {
  await apiPasswordReset(mapPasswordResetForm(form));
}
