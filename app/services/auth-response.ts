import { parseStrictTimestamp } from '@/utils/strict-timestamp';
import type { AuthSessionVM, AuthOtpVM, AuthOtpVerificationVM } from '@/types/auth';

export function invalidAuthResponse(): Error {
  return new Error('Invalid authentication response');
}

function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw invalidAuthResponse();
  return value as Record<string, unknown>;
}

function text(value: unknown): string {
  if (typeof value !== 'string' || !value.trim()) throw invalidAuthResponse();
  return value;
}

function identity(value: unknown): Record<string, unknown> {
  const user = record(value);
  if (typeof user.user_id !== 'number' || !Number.isSafeInteger(user.user_id) || user.user_id < 1) throw invalidAuthResponse();
  text(user.username);
  return user;
}

function account(value: unknown, expected: string): string {
  const actual = text(value);
  if (actual !== expected.trim()) throw invalidAuthResponse();
  return actual;
}

/** Match Dart's calendar validation and microsecond precision, not Date.parse rollover. */
function expiry(value: unknown): bigint {
  try { return parseStrictTimestamp(value); }
  catch { throw invalidAuthResponse(); }
}

export function decodeAuthSession(value: unknown): AuthSessionVM {
  const data = record(value);
  const sessionId = text(data.session_id);
  text(data.access_token);
  text(data.refresh_token);
  const accessTokenExpiresAt = text(data.access_token_expires_at);
  const refreshTokenExpiresAt = text(data.refresh_token_expires_at);
  if (expiry(refreshTokenExpiresAt) <= expiry(accessTokenExpiresAt)) throw invalidAuthResponse();
  // Tokens remain HttpOnly Cookie/server response data, never a new readable preference.
  return { sessionId, accessTokenExpiresAt, refreshTokenExpiresAt };
}

export function decodeAuthOtp(value: unknown, expectedAccount: string): AuthOtpVM {
  const data = record(value);
  const expiresAt = text(data.expires_at);
  expiry(expiresAt);
  return { account: account(data.account, expectedAccount), verificationId: text(data.verification_id), expiresAt };
}

export function decodeOtpVerification(value: unknown, expectedAccount: string): AuthOtpVerificationVM {
  const data = record(value);
  if (data.verified !== true) throw invalidAuthResponse();
  const verifiedAt = text(data.verified_at);
  expiry(verifiedAt);
  return { account: account(data.account, expectedAccount), verified: true, verifiedAt };
}

export function validateRegistrationResponse(value: unknown, email: string, username: string): void {
  const user = identity(record(value).user);
  account(user.email, email);
  if (user.username !== username.trim()) throw invalidAuthResponse();
}

/** Validate authentication fields; complete profile mapping remains in users.ts. */
export function validateLoginResponse(value: unknown, completion = false): void {
  const data = record(value);
  const hasFlag = Object.prototype.hasOwnProperty.call(data, 'two_factor_required');
  if (completion ? hasFlag && data.two_factor_required !== false : typeof data.two_factor_required !== 'boolean') throw invalidAuthResponse();
  if (data.two_factor_required === true) {
    text(data.challenge_id);
    text(data.account);
    expiry(data.expires_at);
    return;
  }
  identity(data.user);
}
