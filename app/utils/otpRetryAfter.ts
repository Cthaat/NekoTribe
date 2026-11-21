const OTP_RETRY_FALLBACK_SECONDS = 60;
const OTP_RETRY_MAX_SECONDS = 3600;

export function otpRetryDelay(error: unknown): number | null {
  if (typeof error !== 'object' || error === null) return null;
  const candidate = error as {
    statusCode?: number;
    response?: { status?: number; headers?: Pick<Headers, 'get'> };
  };
  if ((candidate.response?.status ?? candidate.statusCode) !== 429) return null;
  const raw = candidate.response?.headers?.get('Retry-After');
  if (!raw || !/^\d+$/.test(raw)) return OTP_RETRY_FALLBACK_SECONDS;
  const seconds = Number(raw);
  return Number.isSafeInteger(seconds) && seconds >= 1 && seconds <= OTP_RETRY_MAX_SECONDS
    ? seconds
    : OTP_RETRY_FALLBACK_SECONDS;
}
