export function aiQuotaRetry(error: unknown): number | null {
  const failure = error as {
    statusCode?: number;
    status?: number;
    response?: { headers?: Headers };
  } | null;
  if ((failure?.statusCode ?? failure?.status) !== 429) return null;
  const seconds = Number(failure?.response?.headers?.get('Retry-After'));
  return Number.isInteger(seconds) && seconds >= 1 && seconds <= 60 ? seconds : 0;
}
