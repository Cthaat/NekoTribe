import { createHash } from 'node:crypto';
import policy from '../../../specifications/requirements/github-oauth.json';
import { v2ServiceUnavailable } from '../../utils/auth-entry-errors';

interface GitHubConfig {
  clientId: string;
  clientSecret: string;
  redirectUri: string;
}

export interface GitHubIdentity {
  id: string;
  login: string;
}

export function readGitHubConfig(): GitHubConfig {
  const clientId = process.env.GITHUB_OAUTH_CLIENT_ID?.trim();
  const clientSecret = process.env.GITHUB_OAUTH_CLIENT_SECRET?.trim();
  const url = URL.parse(process.env.GITHUB_OAUTH_REDIRECT_URI?.trim() ?? '');
  if (!clientId || !clientSecret || !url || url.username || url.password || url.search || url.hash ||
      url.pathname !== '/api/v2/auth/oauth/github/callback' ||
      (url.protocol !== 'https:' && !(url.protocol === 'http:' && url.hostname === 'localhost'))) return v2ServiceUnavailable();
  return { clientId, clientSecret, redirectUri: url.href };
}

export function githubAuthorizationUrl(config: GitHubConfig, state: string, verifier: string): string {
  const target = new URL(policy.endpoints.authorize);
  target.search = new URLSearchParams({
    client_id: config.clientId, redirect_uri: config.redirectUri, state,
    code_challenge: createHash('sha256').update(verifier).digest('base64url'), code_challenge_method: 'S256',
    allow_signup: 'false', scope: '',
  }).toString();
  return target.href;
}

async function providerJson(response: Response): Promise<Record<string, unknown> | null> {
  if (!response.ok || !response.body || Number(response.headers.get('content-length')) > policy.providerBodyMaxBytes) {
    await response.body?.cancel();
    return null;
  }
  const reader = response.body.getReader();
  const buffers: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > policy.providerBodyMaxBytes) { await reader.cancel(); return null; }
      buffers.push(value);
    }
    const data: unknown = JSON.parse(Buffer.concat(buffers, total).toString('utf8'));
    return data && typeof data === 'object' && !Array.isArray(data) ? data as Record<string, unknown> : null;
  } finally { reader.releaseLock(); }
}

export async function verifyGitHubCode(config: GitHubConfig, code: string, verifier: string, request = fetch): Promise<GitHubIdentity | null> {
  const signal = AbortSignal.timeout(policy.providerTimeoutMs);
  try {
    const exchange = await providerJson(await request(policy.endpoints.exchange, {
      method: 'POST', redirect: 'error', signal,
      headers: { Accept: 'application/json', 'User-Agent': 'NekoTribe OAuth' },
      body: new URLSearchParams({ client_id: config.clientId, client_secret: config.clientSecret,
        redirect_uri: config.redirectUri, code, code_verifier: verifier }),
    }));
    const token = exchange?.access_token;
    if (typeof token !== 'string' || !/^[A-Za-z0-9._-]{1,2048}$/u.test(token)) return null;
    const profile = await providerJson(await request(policy.endpoints.profile, {
      redirect: 'error', signal,
      headers: { Accept: 'application/vnd.github+json', Authorization: `Bearer ${token}`, 'User-Agent': 'NekoTribe OAuth' },
    }));
    if (!profile || typeof profile.id !== 'number' || !Number.isSafeInteger(profile.id) || profile.id <= 0 ||
        typeof profile.login !== 'string' || !profile.login.trim() || Array.from(profile.login.trim()).length > 80) return null;
    return { id: String(profile.id), login: profile.login.trim() };
  } catch { return null; }
}
