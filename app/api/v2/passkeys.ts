import { browserSupportsWebAuthn, startAuthentication, startRegistration, WebAuthnAbortService } from '@simplewebauthn/browser';
import type { PublicKeyCredentialCreationOptionsJSON, PublicKeyCredentialRequestOptionsJSON } from '@simplewebauthn/browser';
import type { V2LoginData } from '@/types/v2';
import { authQueueFor } from '@/services/auth-request-queue';
import { authMutation } from './auth-mutation';
import { v2RequestData } from './client';

export interface PasskeySummary {
  credential_id: string;
  label: string;
  created_at: string;
  last_used_at: string | null;
}

interface PasskeyOptions<T> {
  challenge_id: string;
  options: T;
}

const authPath = '/api/v2/auth/passkeys';
const managePath = '/api/v2/users/me/passkeys';

export function supportsPasskeys(): boolean {
  return typeof window !== 'undefined' && window.isSecureContext && browserSupportsWebAuthn();
}

export function passkeyCancelled(error: unknown): boolean {
  return error instanceof Error && ['NotAllowedError', 'AbortError'].includes(error.name) ||
    (typeof error === 'object' && error !== null && 'code' in error && error.code === 'ERROR_CEREMONY_ABORTED');
}

function requireCurrent(condition: boolean) {
  if (!condition) throw new DOMException('Passkey action superseded', 'AbortError');
}

export function cancelPasskeyPrompt() {
  WebAuthnAbortService.cancelCeremony();
}

export function authenticatePasskey(rememberMe: boolean, active: () => boolean): Promise<V2LoginData> {
  const app = useNuxtApp();
  const identity = authQueueFor(app);
  const pending = authMutation(async () => {
    requireCurrent(active() && identity.revision === revision);
    const begin = await app.runWithContext(() => v2RequestData<PasskeyOptions<PublicKeyCredentialRequestOptionsJSON>>(
      `${authPath}/authentication/options`, { method: 'POST' },
    ));
    requireCurrent(active() && identity.revision === revision);
    const credential = await startAuthentication({ optionsJSON: begin.options });
    requireCurrent(active() && identity.revision === revision);
    const body = { challenge_id: begin.challenge_id, credential, remember_me: rememberMe };
    return app.runWithContext(() => v2RequestData<V2LoginData, typeof body>(
      `${authPath}/authentication/verification`, { method: 'POST', body },
    ));
  }, true);
  const revision = identity.revision;
  return pending;
}

export async function registerPasskey(label: string, current: () => boolean): Promise<PasskeySummary> {
  const app = useNuxtApp();
  requireCurrent(current());
  const begin = await v2RequestData<PasskeyOptions<PublicKeyCredentialCreationOptionsJSON>>(
    `${authPath}/registration/options`, { method: 'POST' },
  );
  requireCurrent(current());
  const credential = await startRegistration({ optionsJSON: begin.options });
  requireCurrent(current());
  const body = { challenge_id: begin.challenge_id, credential, ...(label ? { label } : {}) };
  const result = await app.runWithContext(() => v2RequestData<{ credential: PasskeySummary }, typeof body>(
    `${authPath}/registration/verification`, { method: 'POST', body },
  ));
  if (result?.credential?.credential_id !== credential.id) throw new Error('Unconfirmed Passkey registration');
  return result.credential;
}

export async function listPasskeys(): Promise<PasskeySummary[]> {
  const result = await v2RequestData<{ credentials: PasskeySummary[] }>(managePath);
  if (!Array.isArray(result?.credentials) || result.credentials.some(row =>
    typeof row?.credential_id !== 'string' || typeof row.label !== 'string' || typeof row.created_at !== 'string' ||
    (row.last_used_at !== null && typeof row.last_used_at !== 'string'))) throw new Error('Invalid Passkey list');
  return result.credentials;
}

export async function deletePasskey(id: string): Promise<void> {
  const response = await v2RequestData<null>(`${managePath}/${encodeURIComponent(id)}`, { method: 'DELETE' });
  if (response !== null) throw new Error('Unconfirmed Passkey removal');
}
