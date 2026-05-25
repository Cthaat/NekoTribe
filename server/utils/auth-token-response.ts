interface BuildV2TokenDataInput {
  sessionId: string;
  accessToken: string;
  refreshToken: string;
  accessExpiresAt: Date;
  refreshExpiresAt: Date;
}

export function buildV2TokenData(
  input: BuildV2TokenDataInput
): V2TokenData {
  return {
    session_id: input.sessionId,
    access_token: input.accessToken,
    refresh_token: input.refreshToken,
    access_token_expires_at: input.accessExpiresAt.toISOString(),
    refresh_token_expires_at: input.refreshExpiresAt.toISOString()
  };
}

export function resolveV2RefreshToken(
  cookieToken: string | null | undefined,
  body: Record<string, unknown>
): string | null {
  const cookieValue = normalizeToken(cookieToken);
  if (cookieValue) return cookieValue;
  return normalizeToken(body.refresh_token);
}

function normalizeToken(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const token = value.trim();
  return token.length > 0 ? token : null;
}
