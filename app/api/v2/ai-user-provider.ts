import { v2RequestData } from './client';

export type UserProviderPreset = 'default' | 'provided';
type ProviderConfig = {
  preset:UserProviderPreset;model:string;enabled:boolean;key_configured:true;revision:number;reconnect_required:boolean;
};
export interface UserProviderView {
  setup_available:boolean;
  presets:Array<{id:UserProviderPreset;base_url:string}>;
  config:ProviderConfig|null;
}
export interface UserProviderInput {
  preset:UserProviderPreset;
  model:string;
  enabled:boolean;
  api_key?:string;
}

const path = '/api/v2/users/me/ai-provider';
function record(value: unknown): Record<string,unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid provider settings');
  return value as Record<string,unknown>;
}
const validPreset = (value: unknown): value is UserProviderPreset => value === 'default' || value === 'provided';
export const validProviderModel = (value: string) => /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$/.test(value);
export const validProviderKey = (value: string) => /^[\x21-\x7e]{1,512}$/.test(value);

function decode(value: unknown): UserProviderView {
  const body = record(value);
  const {setup_available,presets,config} = body;
  if (Object.keys(body).length !== 3 || typeof setup_available !== 'boolean' ||
      !Array.isArray(presets) || presets.length < 1 || presets.length > 2) throw new Error('Invalid provider settings');
  const items = (presets as unknown[]).map(value=>{
    const item = record(value);
    const {id,base_url} = item;
    if (Object.keys(item).length !== 2 || !validPreset(id) || typeof base_url !== 'string' || !/^https?:\/\//.test(base_url)) {
      throw new Error('Invalid provider preset');
    }
    return {id,base_url};
  });
  if (new Set(items.map(item=>item.id)).size !== items.length || !items.some(item=>item.id === 'default')) {
    throw new Error('Invalid provider presets');
  }
  if (config === null) return {setup_available,presets:items,config:null};
  const saved = record(config);
  const {preset,model,enabled,key_configured,revision,reconnect_required} = saved;
  if (!setup_available || Object.keys(saved).length !== 6 || !validPreset(preset) || typeof model !== 'string' ||
      !validProviderModel(model) || typeof enabled !== 'boolean' || key_configured !== true ||
      typeof revision !== 'number' || !Number.isSafeInteger(revision) || revision < 1 ||
      typeof reconnect_required !== 'boolean') throw new Error('Invalid provider settings');
  return {setup_available,presets:items,config:{preset,model,enabled,key_configured,revision,reconnect_required}};
}

export async function getUserProvider(signal:AbortSignal) {
  return decode(await v2RequestData<unknown>(path,{signal,redirect:'error'}));
}
export async function putUserProvider(body:UserProviderInput,signal:AbortSignal) {
  const result = decode(await v2RequestData<unknown,UserProviderInput>(path,{method:'PUT',body,signal,redirect:'error'}));
  if (!result.config || result.config.preset !== body.preset || result.config.model !== body.model ||
      result.config.enabled !== body.enabled || result.config.reconnect_required) throw new Error('Invalid provider save receipt');
  return result;
}
export async function verifyUserProvider(signal:AbortSignal) {
  const receipt = record(await v2RequestData<unknown>(path+'/test',{method:'POST',signal,redirect:'error'}));
  if (Object.keys(receipt).length !== 1 || receipt.verified !== true) throw new Error('Invalid provider test receipt');
}
export async function removeUserProvider(signal:AbortSignal) {
  if (await v2RequestData<unknown>(path,{method:'DELETE',signal,redirect:'error'}) !== null) throw new Error('Invalid provider removal receipt');
}
