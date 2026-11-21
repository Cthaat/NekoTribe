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
