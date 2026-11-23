import { createHash, randomBytes } from 'node:crypto';
import { getQuery, setResponseHeader, setResponseStatus } from 'h3';
import type { H3Event } from 'h3';
import type { Connection } from 'oracledb';
import policy from '../../../specifications/requirements/github-oauth.json';
import passkeyPolicy from '../../../specifications/requirements/passkey-auth.json';
import { requireFeatureSchema } from '../../database/readiness';
import { readBoundedJsonObject } from '../../utils/bounded-json';
import type { V2DbRecord } from '../../utils/v2';
import {
  v2Auth, v2BadRequest, v2Conflict, v2DateString, v2Execute, v2Forbidden, v2NotFound,
  v2Number, v2Ok, v2One, v2RouterParam, v2ServerError, v2String, v2Unauthorized, v2WithConnection,
} from '../../utils/v2';
import { v2LoginAfterVerifiedCredential } from './auth';
import { hasPasswordLogin } from './passkey-auth';
import { githubAuthorizationUrl, readGitHubConfig, verifyGitHubCode } from './github-oauth-provider';
import type { GitHubIdentity } from './github-oauth-provider';

type Purpose = 'login' | 'link';

interface GitHubLink {
  github_user_id: string;
  github_login: string;
  linked_at: string;
}

type FlowCompletion = { status: 'pending' } | { status: 'completed'; link: GitHubLink } |
  { status: 'completed'; login: V2LoginData };

const { sql } = policy;
const callbackPage = '<!doctype html><html lang="zh"><meta charset="utf-8"><title>NekoTribe</title><main><h1>返回 NekoTribe</h1><p>请在原来的应用或标签页查看授权结果。</p><p>Return to NekoTribe to see the authorization result.</p></main></html>';
const nonce = () => randomBytes(policy.nonceBytes).toString('base64url');
const digest = (value: string) => createHash('sha256').update(value).digest('hex');

function validNonce(value: unknown): value is string {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{43}$/u.test(value)) return false;
  const data = Buffer.from(value, 'base64url');
  return data.length === policy.nonceBytes && data.toString('base64url') === value;
}

function privateResponse(event: H3Event) {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
}

function flowOwner(event: H3Event, purpose: Purpose) {
  if (purpose === 'login') return { owner_user_id: null, owner_session_id: null };
  const auth = v2Auth(event);
  if (!auth.sessionId) return v2Unauthorized();
  return { owner_user_id: auth.userId, owner_session_id: auth.sessionId };
}

function linkSummary(row: V2DbRecord): GitHubLink {
  return { github_user_id: v2String(row.GITHUB_USER_ID), github_login: v2String(row.GITHUB_LOGIN),
    linked_at: v2DateString(row.LINKED_AT) ?? '' };
}

async function transaction<T>(connection: Connection, action: () => Promise<T>): Promise<T> {
  try {
    const value = await action();
    await connection.commit();
    return value;
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

export async function v2StartGitHubOAuth(event: H3Event, connection: Connection, purpose: Purpose) {
  privateResponse(event);
  const owner = flowOwner(event, purpose);
  const config = readGitHubConfig();
  await requireFeatureSchema(connection, 'github-oauth');
  const flowId = nonce();
  const flowKey = nonce();
  const state = nonce();
  const verifier = nonce();
  await transaction(connection, async () => {
    await v2Execute(connection, sql.prune, {}, false);
    if (await v2Execute(connection, sql.begin, {
      flow_id: flowId, purpose, ...owner, state_hash: digest(state), flow_key_hash: digest(flowKey),
      pkce_verifier: verifier, ttl_seconds: policy.ttlSeconds,
    }, false) !== 1) v2ServerError();
  });
  return v2Ok({ flow_id: flowId, flow_key: flowKey, authorization_url: githubAuthorizationUrl(config, state, verifier),
    expires_in: policy.ttlSeconds });
}

async function claimCallback(connection: Connection, state: string) {
  return transaction(connection, async () => {
    const flow = await v2One(connection, sql.callbackLock, { state_hash: digest(state) });
    if (!flow) return null;
    const id = v2String(flow.FLOW_ID);
    const verifier = v2String(flow.PKCE_VERIFIER);
    if (await v2Execute(connection, sql.callbackClaim, { flow_id: id }, false) !== 1) return null;
    return { id, verifier };
  });
}

export async function v2GitHubCallback(event: H3Event) {
  privateResponse(event);
  setResponseHeader(event, 'Referrer-Policy', 'no-referrer');
  setResponseHeader(event, 'Content-Type', 'text/html; charset=utf-8');
  setResponseHeader(event, 'Content-Security-Policy', "default-src 'none'; frame-ancestors 'none'");
  const reply = (status: number) => { setResponseStatus(event, status); return callbackPage; };
  if (event.method !== 'GET') return reply(405);
  const { state, code, error } = getQuery(event);
  const denied = typeof error === 'string' && error.length > 0;
  if (!validNonce(state) || (error !== undefined && !denied) ||
      (!denied && (typeof code !== 'string' || !/^[A-Za-z0-9_-]{1,512}$/u.test(code)))) return reply(400);
  try {
    const config = readGitHubConfig();
    const { data: flow } = await v2WithConnection(event, async connection => {
      await requireFeatureSchema(connection, 'github-oauth');
      return v2Ok(await claimCallback(connection, state));
    });
    if (!flow) return reply(401);
    const identity = !denied && typeof code === 'string' ? await verifyGitHubCode(config, code, flow.verifier) : null;
    const { data: updated } = await v2WithConnection(event, async connection => v2Ok(await v2Execute(connection, sql.callbackFinish, {
      flow_id: flow.id, status: identity ? 'verified' : 'failed', github_user_id: identity?.id ?? null,
      github_login: identity?.login ?? null,
    })));
    return reply(updated === 1 && identity ? 200 : 401);
  } catch { return reply(503); }
}

async function finishFlow(connection: Connection, owner: ReturnType<typeof flowOwner>, purpose: Purpose, id: string, key: string) {
  return transaction(connection, async () => {
    const flow = await v2One(connection, sql.completeLock, { flow_id: id, flow_key_hash: digest(key), purpose, ...owner });
    if (!flow) v2Unauthorized();
    const status = v2String(flow.STATUS);
    if (status === 'pending' || status === 'checking') return null;
    if (await v2Execute(connection, sql.completeConsume, { flow_id: id }, false) !== 1) v2ServerError();
    return { id: v2String(flow.GITHUB_USER_ID), login: v2String(flow.GITHUB_LOGIN), verified: status === 'verified' };
  });
}

async function bindAccount(connection: Connection, userId: number, account: GitHubIdentity) {
  try {
    return await transaction(connection, async () => {
      const owner = { user_id: userId };
      if (!await v2One(connection, passkeyPolicy.sql.lockOwner, owner)) v2Forbidden('账号不可用');
      const existing = await v2One(connection, sql.linkForUser, owner);
      if (existing) {
        if (existing.GITHUB_USER_ID !== account.id) v2Conflict('GitHub 账号已绑定');
        return linkSummary(existing);
      }
      if (await v2Execute(connection, sql.linkCreate, { ...owner, github_user_id: account.id, github_login: account.login }, false) !== 1) v2ServerError();
      const linked = await v2One(connection, sql.linkForUser, owner);
      if (!linked) v2ServerError();
      return linkSummary(linked);
    });
  } catch (error) {
    if (error && typeof error === 'object' && 'code' in error && error.code === 'ORA-00001') v2Conflict('GitHub 账号已绑定');
    throw error;
  }
}

export async function v2CompleteGitHubOAuth(event: H3Event, connection: Connection, purpose: Purpose): Promise<V2Response<FlowCompletion>> {
  privateResponse(event);
  const owner = flowOwner(event, purpose);
  const id = v2RouterParam(event, 'flow_id');
  const body = await readBoundedJsonObject(event, 4096, 'GitHub 授权参数错误');
  if (!validNonce(id) || !validNonce(body.flow_key)) v2BadRequest('GitHub 授权参数错误');
  readGitHubConfig();
  await requireFeatureSchema(connection, 'github-oauth');
  const verified = await finishFlow(connection, owner, purpose, id, body.flow_key);
  if (!verified) return v2Ok({ status: 'pending' as const });
  if (!verified.verified || !verified.id || !verified.login) v2Unauthorized();
  if (owner.owner_user_id !== null) {
    return v2Ok({ status: 'completed' as const, link: await bindAccount(connection, owner.owner_user_id, verified) });
  }
  const link = await v2One(connection, sql.linkForGitHub, { github_user_id: verified.id });
  if (!link) v2Unauthorized();
  const { data: login } = await v2LoginAfterVerifiedCredential(event, connection, v2Number(link.USER_ID), body.remember_me === true);
  return v2Ok({ status: 'completed' as const, login });
}

export async function v2GetGitHubLink(event: H3Event, connection: Connection) {
  privateResponse(event);
  const auth = v2Auth(event);
  await requireFeatureSchema(connection, 'github-oauth');
  const row = await v2One(connection, sql.linkForUser, { user_id: auth.userId });
  return v2Ok({ link: row ? linkSummary(row) : null });
}

async function hasPasskey(connection: Connection, userId: number): Promise<boolean> {
  try { return v2Number((await v2One(connection, sql.passkeyCount, { user_id: userId }))?.TOTAL) > 0; }
  catch (error) {
    if (error && typeof error === 'object' && 'code' in error && error.code === 'ORA-00942') return false;
    throw error;
  }
}

export async function v2DeleteGitHubLink(event: H3Event, connection: Connection) {
  privateResponse(event);
  const auth = v2Auth(event);
  await requireFeatureSchema(connection, 'github-oauth');
  const args = { user_id: auth.userId };
  await transaction(connection, async () => {
    const owner = await v2One(connection, passkeyPolicy.sql.lockOwner, args);
    if (!owner) v2Forbidden('账号不可用');
    if (!await v2One(connection, sql.linkForUser, args)) v2NotFound('GitHub 绑定不存在');
    if (!hasPasswordLogin(owner.PASSWORD_HASH) && !await hasPasskey(connection, auth.userId)) v2Conflict('请保留至少一种登录方式');
    if (await v2Execute(connection, sql.linkRemove, args, false) !== 1) v2NotFound('GitHub 绑定不存在');
  });
  return v2Ok(null);
}
