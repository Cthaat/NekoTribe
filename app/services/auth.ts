import {
  v2CreateOtp as apiCreateOtp,
  v2CompleteTwoFactorLogin as apiCompleteTwoFactorLogin,
  v2Login as apiLogin,
  v2LogoutCurrent,
  v2PasswordReset as apiPasswordReset,
  v2RefreshCurrentToken as apiRefreshCurrentToken,
  v2Register as apiRegister,
  v2VerifyOtp as apiVerifyOtp
} from '@/api/v2/auth';
import type {
  V2AuthOtpPayload,
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
  LoginResultVM,
  LoginVM,
  PasswordResetFormVM,
  RegistrationFormVM,
  TwoFactorLoginChallengeVM,
  TwoFactorLoginFormVM
} from '@/types/auth';
import { mapCurrentUser } from './users';
import { decodeAuthSession, decodeAuthOtp, decodeOtpVerification, invalidAuthResponse, validateLoginResponse, validateRegistrationResponse } from './auth-response';

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
  return decodeAuthSession(dto);
}

function mapLogin(dto: V2LoginData): LoginVM {
  if ('two_factor_required' in dto && dto.two_factor_required) {
    throw new Error('two-factor challenge cannot be mapped as login');
  }
  try {
    return { user: mapCurrentUser(dto.user), tokens: mapSession(dto.tokens) };
  } catch {
    throw invalidAuthResponse();
  }
}

function mapTwoFactorChallenge(
  dto: V2LoginData
): TwoFactorLoginChallengeVM | null {
  if ('two_factor_required' in dto && dto.two_factor_required) {
    return {
      twoFactorRequired: true,
      challengeId: dto.challenge_id,
      account: dto.account,
      expiresAt: dto.expires_at
    };
  }
  return null;
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
  const payload = mapOtpForm(form);
  return decodeAuthOtp(await apiCreateOtp(payload), payload.account);
}

export async function v2VerifyOtp(
  form: AuthOtpVerificationFormVM
): Promise<AuthOtpVerificationVM> {
  const payload = mapVerifyOtpForm(form);
  return decodeOtpVerification(await apiVerifyOtp(payload), payload.account);
}

export async function v2Register(
  form: RegistrationFormVM
): Promise<{ user: LoginVM['user'] }> {
  const payload = mapRegistrationForm(form);
  const result = await apiRegister(payload);
  validateRegistrationResponse(result, payload.email, payload.username);
  try { return { user: mapCurrentUser(result.user) }; }
  catch { throw invalidAuthResponse(); }
}

export async function v2Login(
  form: LoginFormVM
): Promise<LoginResultVM> {
  const result = await apiLogin(mapLoginForm(form));
  validateLoginResponse(result);
  return mapTwoFactorChallenge(result) ?? mapLogin(result);
}

export async function v2CompleteTwoFactorLogin(
  form: TwoFactorLoginFormVM
): Promise<LoginVM> {
  const result = await apiCompleteTwoFactorLogin(
    form.challengeId,
    {
      challenge_id: form.challengeId,
      code: form.code
    }
  );
  validateLoginResponse(result, true);
  return mapLogin(result);
}

export async function v2RefreshCurrentToken(): Promise<AuthSessionVM> {
  return mapSession(await apiRefreshCurrentToken());
}

export async function v2PasswordReset(
  form: PasswordResetFormVM
): Promise<void> {
  await apiPasswordReset(mapPasswordResetForm(form));
}
