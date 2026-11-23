import {
  generateAuthenticationOptions, generateRegistrationOptions, verifyAuthenticationResponse, verifyRegistrationResponse,
} from '@simplewebauthn/server';
import type { AuthenticationResponseJSON, RegistrationResponseJSON } from '@simplewebauthn/server';
import { cose, decodeClientDataJSON, decodeCredentialPublicKey, isoCBOR } from '@simplewebauthn/server/helpers';
import policy from '../../../specifications/requirements/passkey-auth.json';
import { v2ServiceUnavailable } from '../../utils/auth-entry-errors';

interface RelyingParty {
  id: string;
  origins: string[];
}

export interface CredentialKey {
  id: string;
  x: string;
  y: string;
  counter: number;
  backupEligible: boolean;
  backedUp: boolean;
}

function validOrigin(origin: string): boolean {
  if (/^android:apk-key-hash:[A-Za-z0-9_-]{43}$/u.test(origin)) return true;
  const url = URL.parse(origin);
  return !!url && url.origin === origin && (url.protocol === 'https:' ||
    (url.protocol === 'http:' && url.hostname === 'localhost'));
}

export function relyingParty(): RelyingParty {
  const id = process.env.WEBAUTHN_RP_ID?.trim().toLowerCase() ?? '';
  const origins = (process.env.WEBAUTHN_ORIGINS ?? '').split(',').map(origin => origin.trim()).filter(Boolean);
  if (!id || id.length > 253 || !id.split('.').every(label => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/u.test(label)) ||
      !origins.length || !origins.every(validOrigin)) return v2ServiceUnavailable();
  return { id, origins };
}

export function userHandle(userId: number): Buffer<ArrayBuffer> {
  const bytes = Buffer.alloc(policy.userHandleBytes);
  bytes.writeBigUInt64BE(BigInt(userId), bytes.length - 8);
  return bytes;
}

export function registrationOptions(rp: RelyingParty, userId: number, username: string, displayName: string, credentialIds: string[]) {
  return generateRegistrationOptions({
    rpName: 'NekoTribe', rpID: rp.id, userName: username, userDisplayName: displayName || username,
    userID: userHandle(userId), timeout: policy.timeoutMs, attestationType: 'none',
    authenticatorSelection: { residentKey: 'required', requireResidentKey: true, userVerification: 'required' },
    supportedAlgorithmIDs: [policy.algorithm as -7],
    excludeCredentials: credentialIds.map(id => ({ id })),
  });
}

export function authenticationOptions(rp: RelyingParty) {
  return generateAuthenticationOptions({ rpID: rp.id, timeout: policy.timeoutMs, userVerification: 'required' });
}

const { COSEKEYS, COSEKTY, COSECRV, isCOSEPublicKeyEC2 } = cose;

export async function verifyPasskeyRegistration(rp: RelyingParty, challenge: string, value: RegistrationResponseJSON): Promise<CredentialKey | null> {
  try {
    if (decodeClientDataJSON(value.response.clientDataJSON).crossOrigin === true) return null;
    const verification = await verifyRegistrationResponse({
      response: value, expectedChallenge: challenge, expectedOrigin: rp.origins, expectedRPID: rp.id,
      requireUserPresence: true, requireUserVerification: true, supportedAlgorithmIDs: [policy.algorithm as -7],
    });
    if (!verification.verified) return null;
    const info = verification.registrationInfo;
    const key = decodeCredentialPublicKey(info.credential.publicKey);
    if (!isCOSEPublicKeyEC2(key) || key.get(COSEKEYS.alg) !== policy.algorithm || key.get(COSEKEYS.crv) !== COSECRV.P256) return null;
    const x = key.get(COSEKEYS.x);
    const y = key.get(COSEKEYS.y);
    if (x?.length !== 32 || y?.length !== 32) return null;
    return { id: info.credential.id, x: Buffer.from(x).toString('base64url'), y: Buffer.from(y).toString('base64url'),
      counter: info.credential.counter, backupEligible: info.credentialDeviceType === 'multiDevice', backedUp: info.credentialBackedUp };
  } catch { return null; }
}

export async function verifyPasskeyAuthentication(rp: RelyingParty, challenge: string, value: AuthenticationResponseJSON,
  userId: number, credential: CredentialKey): Promise<{ counter: number; backedUp: boolean } | null> {
  try {
    if (value.response.userHandle !== userHandle(userId).toString('base64url') ||
        decodeClientDataJSON(value.response.clientDataJSON).crossOrigin === true) return null;
    const x = Buffer.from(credential.x, 'base64url');
    const y = Buffer.from(credential.y, 'base64url');
    if (x.length !== 32 || y.length !== 32) return null;
    const key = new Map<number, number | Uint8Array<ArrayBuffer>>();
    key.set(COSEKEYS.kty, COSEKTY.EC2);
    key.set(COSEKEYS.alg, policy.algorithm as -7);
    key.set(COSEKEYS.crv, COSECRV.P256);
    key.set(COSEKEYS.x, x);
    key.set(COSEKEYS.y, y);
    const result = await verifyAuthenticationResponse({
      response: value, expectedChallenge: challenge, expectedOrigin: rp.origins, expectedRPID: rp.id,
      requireUserVerification: true,
      credential: { id: credential.id, publicKey: isoCBOR.encode(key), counter: credential.counter },
    });
    const info = result.authenticationInfo;
    if (!result.verified || (info.credentialDeviceType === 'multiDevice') !== credential.backupEligible ||
        ((info.newCounter !== 0 || credential.counter !== 0) && info.newCounter <= credential.counter)) return null;
    return { counter: info.newCounter, backedUp: info.credentialBackedUp };
  } catch { return null; }
}
