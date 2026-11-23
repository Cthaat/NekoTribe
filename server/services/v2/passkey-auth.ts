import { randomBytes } from 'node:crypto';
import { setResponseHeader } from 'h3';
import type { H3Event } from 'h3';
import type { AuthenticationResponseJSON, RegistrationResponseJSON } from '@simplewebauthn/server';
import type { Connection } from 'oracledb';
import policy from '../../../specifications/requirements/passkey-auth.json';
import githubPolicy from '../../../specifications/requirements/github-oauth.json';
import { requireFeatureSchema } from '../../database/readiness';
import { readBoundedJsonObject } from '../../utils/bounded-json';
import type { V2DbRecord } from '../../utils/v2';
import {
  v2Auth, v2BadRequest, v2Boolean, v2Conflict, v2DateString, v2Execute, v2Forbidden,
  v2NotFound, v2Number, v2Ok, v2One, v2RouterParam, v2Rows, v2ServerError, v2String, v2Unauthorized,
} from '../../utils/v2';
import { v2LoginAfterVerifiedCredential } from './auth';
import {
  authenticationOptions, registrationOptions, relyingParty, verifyPasskeyAuthentication, verifyPasskeyRegistration,
} from './passkey-webauthn';
import type { CredentialKey } from './passkey-webauthn';

type Purpose = 'register' | 'login';
type CredentialResponse = AuthenticationResponseJSON | RegistrationResponseJSON;

interface PasskeySummary {
  credential_id: string;
  label: string;
  created_at: string;
  last_used_at: string | null;
}

const { sql } = policy;
const issuer = 'nuxt';
const passwordHashFormat = new RegExp(policy.passwordHashPattern, 'u');

function privateResponse(event: H3Event) {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
}

function validBase64Url(value: unknown, maxBytes: number, exact = false): value is string {
  if (typeof value !== 'string' || value.length > Math.ceil(maxBytes * 4 / 3) || !/^[A-Za-z0-9_-]+$/u.test(value)) return false;
  const bytes = Buffer.from(value, 'base64url');
  return bytes.length > 0 && (exact ? bytes.length === maxBytes : bytes.length <= maxBytes) && bytes.toString('base64url') === value;
}

function challengeOwner(event: H3Event, purpose: Purpose) {
  if (purpose === 'login') return { owner_user_id: null, owner_session_id: null };
  const auth = v2Auth(event);
  if (!auth.sessionId) return v2Unauthorized();
  return { owner_user_id: auth.userId, owner_session_id: auth.sessionId };
}

function publicCredential(row: V2DbRecord): PasskeySummary {
  return { credential_id: v2String(row.CREDENTIAL_ID), label: v2String(row.LABEL),
    created_at: v2DateString(row.CREATED_AT) ?? '', last_used_at: v2DateString(row.LAST_USED_AT) ?? null };
}

async function inTransaction<T>(connection: Connection, action: () => Promise<T>): Promise<T> {
  try {
    const result = await action();
    await connection.commit();
    return result;
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

async function requestCredential(event: H3Event) {
  const body = await readBoundedJsonObject(event, policy.maxPayloadBytes, 'Passkey 参数错误');
  const challenge = body.challenge_id;
  const candidate = body.credential;
  if (!validBase64Url(challenge, policy.challengeIdBytes, true) || !candidate ||
      typeof candidate !== 'object' || Array.isArray(candidate)) return v2BadRequest('Passkey 参数错误');
  const credential = candidate as Record<string, unknown>;
  if (!validBase64Url(credential.id, policy.maxCredentialIdBytes) || credential.id !== credential.rawId ||
      credential.type !== 'public-key' || !credential.response || typeof credential.response !== 'object') {
    return v2BadRequest('Passkey 参数错误');
  }
  return { challenge, credential: credential as unknown as CredentialResponse, label: body.label, remember: body.remember_me === true };
}

export async function v2PasskeyOptions(event: H3Event, connection: Connection, purpose: Purpose) {
  privateResponse(event);
  const owner = challengeOwner(event, purpose);
  const rp = relyingParty();
  await requireFeatureSchema(connection, 'passkey-auth');
  let options;
  if (owner.owner_user_id !== null) {
    const user = await v2One(connection, sql.owner, { user_id: owner.owner_user_id });
    if (!user || !v2Boolean(user.IS_ACTIVE) || user.STATUS !== 'active') v2Forbidden('账号不可用');
    const credentialIds = (await v2Rows(connection, sql.credentialList, { user_id: owner.owner_user_id }))
      .map(row => v2String(row.CREDENTIAL_ID));
    options = await registrationOptions(rp, owner.owner_user_id, v2String(user.USERNAME), v2String(user.DISPLAY_NAME), credentialIds);
  } else options = await authenticationOptions(rp);

  const challengeId = randomBytes(policy.challengeIdBytes).toString('base64url');
  await inTransaction(connection, async () => {
    await v2Execute(connection, sql.challengePrune, {}, false);
    if (await v2Execute(connection, sql.challengeInsert, {
      challenge_id: challengeId, issuer, purpose, ...owner, challenge: options.challenge,
      engine_state: null, ttl_seconds: policy.ttlSeconds,
    }, false) !== 1) v2ServerError();
  });
  return v2Ok({ challenge_id: challengeId, options });
}

async function takeChallenge(connection: Connection, purpose: Purpose, owner: ReturnType<typeof challengeOwner>, id: string) {
  return inTransaction(connection, async () => {
    const row = await v2One(connection, sql.challengeLock, { ...owner, purpose, issuer, challenge_id: id });
    if (!row) return v2Unauthorized();
    if (await v2Execute(connection, sql.challengeDelete, { challenge_id: id }, false) !== 1) v2ServerError();
    return v2String(row.CHALLENGE);
  });
}

async function storeCredential(connection: Connection, userId: number, credential: CredentialKey, label: string) {
  try {
    return await inTransaction(connection, async () => {
      if (!await v2One(connection, sql.lockOwner, { user_id: userId })) v2Forbidden('账号不可用');
      if (await v2Execute(connection, sql.credentialInsert, {
        credential_id: credential.id, user_id: userId, public_x: credential.x, public_y: credential.y,
        sign_count: credential.counter, backup_eligible: Number(credential.backupEligible),
        backed_up: Number(credential.backedUp), label,
      }, false) !== 1) v2ServerError();
      const result = await v2One(connection, sql.credentialRead, { credential_id: credential.id });
      if (!result) return v2ServerError();
      return publicCredential(result);
    });
  } catch (error) {
    if (error && typeof error === 'object' && 'code' in error && error.code === 'ORA-00001') v2Conflict('Passkey 已登记');
    throw error;
  }
}

async function authenticateCredential(connection: Connection, rp: ReturnType<typeof relyingParty>, challenge: string, value: AuthenticationResponseJSON) {
  return inTransaction(connection, async () => {
    const row = await v2One(connection, sql.credentialRead, { credential_id: value.id });
    if (!row) return v2Unauthorized();
    const userId = v2Number(row.USER_ID);
    const result = await verifyPasskeyAuthentication(rp, challenge, value, userId,
      { id: value.id, x: v2String(row.PUBLIC_X), y: v2String(row.PUBLIC_Y), counter: v2Number(row.SIGN_COUNT),
        backupEligible: v2Boolean(row.BACKUP_ELIGIBLE), backedUp: v2Boolean(row.BACKED_UP) });
    if (!result) return v2Unauthorized();
    if (await v2Execute(connection, sql.credentialUse, {
      credential_id: value.id, user_id: userId, sign_count: result.counter, backed_up: Number(result.backedUp),
    }, false) !== 1) v2ServerError();
    return userId;
  });
}

export async function v2PasskeyVerify(event: H3Event, connection: Connection, purpose: Purpose):
  Promise<V2Response<V2LoginData | { credential: PasskeySummary }>> {
  privateResponse(event);
  const owner = challengeOwner(event, purpose);
  const rp = relyingParty();
  const request = await requestCredential(event);
  const label = typeof request.label === 'string' ? request.label.trim() || 'Passkey' : 'Passkey';
  if (purpose === 'register' && (Array.from(label).length > policy.maxLabelChars ||
      (request.label !== undefined && typeof request.label !== 'string'))) v2BadRequest('Passkey 参数错误');
  await requireFeatureSchema(connection, 'passkey-auth');
  const challenge = await takeChallenge(connection, purpose, owner, request.challenge);

  if (owner.owner_user_id !== null) {
    const credential = await verifyPasskeyRegistration(rp, challenge, request.credential as RegistrationResponseJSON);
    if (!credential) return v2Unauthorized();
    return v2Ok({ credential: await storeCredential(connection, owner.owner_user_id, credential, label) });
  }
  const userId = await authenticateCredential(connection, rp, challenge, request.credential as AuthenticationResponseJSON);
  return v2LoginAfterVerifiedCredential(event, connection, userId, request.remember);
}

export async function v2ListPasskeys(event: H3Event, connection: Connection) {
  privateResponse(event);
  const auth = v2Auth(event);
  await requireFeatureSchema(connection, 'passkey-auth');
  const rows = await v2Rows(connection, sql.credentialList, { user_id: auth.userId });
  return v2Ok({ credentials: rows.map(publicCredential) });
}

export function hasPasswordLogin(hash: unknown): boolean {
  return typeof hash === 'string' && passwordHashFormat.test(hash);
}

async function hasGitHubLogin(connection: Connection, userId: number): Promise<boolean> {
  try { return !!await v2One(connection, githubPolicy.sql.linkForUser, { user_id: userId }); }
  catch (error) {
    if (error && typeof error === 'object' && 'code' in error && error.code === 'ORA-00942') return false;
    throw error;
  }
}

export async function v2DeletePasskey(event: H3Event, connection: Connection) {
  privateResponse(event);
  const auth = v2Auth(event);
  const credentialId = v2RouterParam(event, 'credential_id');
  if (!validBase64Url(credentialId, policy.maxCredentialIdBytes)) v2BadRequest('Passkey 参数错误');
  await requireFeatureSchema(connection, 'passkey-auth');
  const binds = { user_id: auth.userId };
  await inTransaction(connection, async () => {
    const owner = await v2One(connection, sql.lockOwner, binds);
    if (!owner) v2Forbidden('账号不可用');
    const credentials = await v2Rows(connection, sql.credentialList, binds);
    if (!credentials.some(row => row.CREDENTIAL_ID === credentialId)) v2NotFound('Passkey 不存在');
    if (!hasPasswordLogin(owner.PASSWORD_HASH) && credentials.length <= 1 && !await hasGitHubLogin(connection, auth.userId)) {
      v2Conflict('请保留至少一种登录方式');
    }
    if (await v2Execute(connection, sql.credentialDelete, { ...binds, credential_id: credentialId }, false) !== 1) v2NotFound('Passkey 不存在');
  });
  return v2Ok(null);
}
