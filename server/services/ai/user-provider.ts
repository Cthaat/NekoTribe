import { setResponseHeader, type H3Event } from 'h3';
import type { Connection } from 'oracledb';
import policy from '../../../specifications/requirements/ai-user-provider.json';
import { requireFeatureSchema } from '~/server/database/readiness';
import { safeV2Action, v2ServiceUnavailable } from '~/server/utils/auth-entry-errors';
import { v2Auth, v2BadRequest, v2Conflict, v2Connection, v2Execute, v2NotFound, v2Ok, v2One, v2ServerError } from '~/server/utils/v2';
import { hasTooManyAiBodyMembers, readBoundedAiBody } from './knowledge-search-body';
import type { AiModelSelection } from './model-configuration';
import { deploymentProviderKey, normalizeProviderBaseUrl, openUserProviderKey, sealUserProviderKey, userProviderPresets,
  validUserProviderKey, validUserProviderModel, validUserProviderPreset, type UserProviderBinding, type UserProviderPreset } from './user-provider-crypto';

interface StoredProvider extends UserProviderBinding {
  model: string;
  enabled: boolean;
  box: string;
  revision: number;
}

const feature = 'ai-user-provider' as const;
const maxRevision = 999_999_999_999_999;
const invalidInput: () => never = () => v2BadRequest('个人 AI 连接参数错误');
const changed: () => never = () => v2Conflict('个人 AI 连接已变更，请重新填写密钥');
export const personalWritingKeyReference = 'PERSONAL_WRITING_CREDENTIAL';

async function withConnection<T>(event: H3Event, action:(connection: Connection)=>Promise<T>) {
  const connection = await v2Connection(event);
  try { return await action(connection); }
  finally { await connection.close(); }
}

function privateAction<T>(event: H3Event, action:(ownerId:number)=>Promise<T>) {
  setResponseHeader(event,'Cache-Control','private, no-store');
  return safeV2Action(() => action(v2Auth(event).userId));
}

async function currentProvider(connection: Connection, ownerId: number): Promise<StoredProvider | null> {
  const row = await v2One(connection,policy.sql.read,{user_id:ownerId});
  if (!row) return null;
  const {PRESET_ID:preset,BASE_URL:baseUrl,MODEL_NAME:model,SECRET_BOX:box,ENABLED:enabled,REVISION:revision} = row;
  if (!validUserProviderPreset(preset) || typeof baseUrl !== 'string' || normalizeProviderBaseUrl(baseUrl) !== baseUrl ||
      !validUserProviderModel(model) || typeof box !== 'string' || (enabled !== 0 && enabled !== 1) ||
      typeof revision !== 'number' || !Number.isSafeInteger(revision) || revision < 1 || revision > maxRevision) v2ServerError();
  return {ownerId,preset,baseUrl,model,box,enabled:enabled === 1,revision};
}

function currentCredential(master: Buffer, profile: StoredProvider) {
  const available = userProviderPresets().some(entry=>entry.id === profile.preset && entry.base_url === profile.baseUrl);
  return available ? openUserProviderKey(master,profile,profile.box) : null;
}

function safeView(master: Buffer | null, profile: StoredProvider | null) {
  const config = master && profile ? {
    preset:profile.preset, model:profile.model, enabled:profile.enabled, key_configured:true, revision:profile.revision,
    reconnect_required:!currentCredential(master,profile),
  } : null;
  return {setup_available:master !== null,presets:userProviderPresets(),config};
}

export function readUserProvider(event: H3Event) {
  return privateAction(event, async ownerId => {
    const master = deploymentProviderKey();
    if (!master) return v2Ok(safeView(null,null));
    const profile = await withConnection(event,async connection => {
      await requireFeatureSchema(connection,feature);
      return currentProvider(connection,ownerId);
    });
    return v2Ok(safeView(master,profile));
  });
}

async function readSaveInput(event: H3Event): Promise<{preset:UserProviderPreset;model:string;enabled:boolean;key?:string}> {
  try {
    const body = new TextDecoder('utf-8',{fatal:true,ignoreBOM:true}).decode(await readBoundedAiBody(event.node.req));
    const value: unknown = JSON.parse(body);
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      const keys = Object.keys(value);
      const {preset,model,enabled,api_key:key} = value as Record<string,unknown>;
      if (keys.length === (key === undefined ? 3 : 4) && !hasTooManyAiBodyMembers(body,keys.length) &&
          validUserProviderPreset(preset) && validUserProviderModel(model) && typeof enabled === 'boolean' &&
          (key === undefined || validUserProviderKey(key))) return {preset,model,enabled,key};
    }
  } catch { /* Never include the request body in a configuration error. */ }
  return invalidInput();
}

async function lockProviderOwner(connection: Connection, ownerId: number) {
  if (!await v2One(connection,policy.sql.lock_user,{user_id:ownerId})) v2NotFound('用户不存在');
}

export function saveUserProvider(event: H3Event) {
  return privateAction(event,async ownerId => {
    const input = await readSaveInput(event);
    const master = deploymentProviderKey();
    if (!master) v2ServiceUnavailable();
    const target = userProviderPresets().find(preset=>preset.id === input.preset);
    if (!target) invalidInput();
    const profile = await withConnection(event, async connection=>{
      await requireFeatureSchema(connection,feature);
      let committing = false;
      try {
        await lockProviderOwner(connection,ownerId);
        const previous = await currentProvider(connection,ownerId);
        const binding = {ownerId,preset:input.preset,baseUrl:target.base_url};
        let box: string;
        if (input.key === undefined) {
          if (!previous) invalidInput();
          if (previous.preset !== binding.preset || previous.baseUrl !== binding.baseUrl || !currentCredential(master,previous)) changed();
          box = previous.box;
        } else box = sealUserProviderKey(master,binding,input.key);
        const revision = (previous?.revision ?? 0) + 1;
        if (revision > maxRevision) changed();
        const params = {user_id:ownerId,preset_id:binding.preset,base_url:binding.baseUrl,model_name:input.model,
          secret_box:box,enabled:input.enabled ? 1 : 0,revision};
        if (await v2Execute(connection,policy.sql.save,params,false) !== 1) v2ServerError();
        committing = true;
        await connection.commit();
        return {...binding,model:input.model,enabled:input.enabled,box,revision};
      } catch (error) {
        if (committing) v2ServerError();
        try { await connection.rollback(); } catch { v2ServerError(); }
        throw error;
      }
    });
    return v2Ok(safeView(master,profile));
  });
}

export function deleteUserProvider(event: H3Event) {
  return privateAction(event,async ownerId => {
    await withConnection(event,async connection=>{
      await requireFeatureSchema(connection,feature);
      let committing = false;
      try {
        await lockProviderOwner(connection,ownerId);
        await v2Execute(connection,policy.sql.delete,{user_id:ownerId},false);
        committing = true;
        await connection.commit();
      } catch (error) {
        if (committing) v2ServerError();
        try { await connection.rollback(); } catch { v2ServerError(); }
        throw error;
      }
    });
    return v2Ok(null);
  });
}

async function matchesModel(response: Response, model: string) {
  if (!response.ok || !response.body) {
    await response.body?.cancel();
    return false;
  }
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const {done,value} = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > policy.test_max_response_bytes) return false;
      chunks.push(value);
    }
    const parsed: unknown = JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(Buffer.concat(chunks,size)));
    return !!parsed && typeof parsed === 'object' && 'data' in parsed && Array.isArray(parsed.data) &&
      (parsed.data as unknown[]).some(item=>!!item && typeof item === 'object' && 'id' in item && item.id === model);
  } finally {
    await reader.cancel().catch(()=>{});
    reader.releaseLock();
  }
}

export function testUserProvider(event: H3Event) {
  return privateAction(event,async ownerId => {
    const master = deploymentProviderKey();
    if (!master) v2ServiceUnavailable();
    const profile = await withConnection(event,async connection=>{
      await requireFeatureSchema(connection,feature);
      return currentProvider(connection,ownerId);
    });
    if (!profile) v2NotFound('个人 AI 连接不存在');
    const credential = currentCredential(master,profile);
    if (!credential) changed();
    try {
      const response = await fetch(profile.baseUrl+'/models',{
        redirect:'error',signal:AbortSignal.timeout(policy.test_timeout_ms),
        headers:{Authorization:`Bearer ${credential}`,Accept:'application/json'},
      });
      if (!await matchesModel(response,profile.model)) v2ServiceUnavailable();
    } catch { v2ServiceUnavailable(); }
    return v2Ok({verified:true});
  });
}

type WritingProvider = {kind:'unusable'} | {kind:'personal'; selection:AiModelSelection; credential:string};
export async function personalWritingProvider(event: H3Event, ownerId: number): Promise<WritingProvider | null> {
  const master = deploymentProviderKey();
  if (!master) return null;
  const profile = await withConnection(event,async connection=>{
    await requireFeatureSchema(connection,feature);
    return currentProvider(connection,ownerId);
  });
  if (!profile?.enabled) return null;
  const credential = currentCredential(master,profile);
  if (!credential) return {kind:'unusable'};
  return {kind:'personal',credential,selection:{
    role:'writing',adapter:'openai-compatible',baseUrl:profile.baseUrl,model:profile.model,profileId:policy.profile_id,
    providerId:profile.preset,configurationRevision:profile.revision,apiKeyEnv:personalWritingKeyReference,
    capabilities:[],contextWindowTokens:policy.context_window_tokens,maxOutputTokens:policy.max_output_tokens,
  }};
}

export async function personalWritingAvailability(event: H3Event): Promise<boolean | null> {
  try {
    const profile = await personalWritingProvider(event,v2Auth(event).userId);
    return profile ? profile.kind === 'personal' : null;
  } catch {
    return false;
  }
}
