import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import policy from '../../../specifications/requirements/ai-user-provider.json' with { type:'json' };

export type UserProviderPreset = 'default' | 'provided';
export const validUserProviderPreset = (value: unknown): value is UserProviderPreset => value === 'default' || value === 'provided';
export const validUserProviderModel = (value: unknown): value is string =>
  typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$/.test(value);
export const validUserProviderKey = (value: unknown): value is string =>
  typeof value === 'string' && value.length <= policy.max_key_bytes && /^[\x21-\x7e]+$/.test(value);

export interface UserProviderBinding {
  ownerId: number;
  preset: UserProviderPreset;
  baseUrl: string;
}

export function deploymentProviderKey() {
  const input = process.env.AI_USER_PROVIDER_SECRET_B64?.trim();
  if (!input || input.length !== 44) return null;
  const bytes = Buffer.from(input,'base64');
  return bytes.length === policy.key_bytes && bytes.toString('base64') === input ? bytes : null;
}

export function normalizeProviderBaseUrl(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const normalized = raw.trim().replace(/\/+$/, '');
  if (!/^https?:\/\//.test(normalized) || !/^[\x21-\x7e]+$/.test(normalized) ||
      /[?#\\]/.test(normalized) || normalized.length > policy.max_base_url_length) return null;
  const authority = normalized.slice(normalized.indexOf('://') + 3).split('/')[0];
  if (!authority || authority.includes('@')) return null;
  try {
    const url = new URL(normalized);
    return url.hostname ? normalized : null;
  } catch { return null; }
}

export function userProviderPresets(): Array<{id:UserProviderPreset;base_url:string}> {
  const configured = normalizeProviderBaseUrl(process.env.AI_USER_PROVIDER_URL);
  return [
    {id:'default',base_url:policy.default_base_url},
    ...(configured ? [{id:'provided' as const,base_url:configured}] : []),
  ];
}

function associatedData(binding: UserProviderBinding) {
  return Buffer.from([policy.aad_version,binding.ownerId,binding.preset,binding.baseUrl].join('\n'),'utf8');
}

export function sealUserProviderKey(master: Buffer, binding: UserProviderBinding, credential: string) {
  if (!validUserProviderKey(credential)) throw new Error('INVALID_PROVIDER_KEY');
  const nonce = randomBytes(policy.nonce_bytes);
  const cipher = createCipheriv('aes-256-gcm',master,nonce,{authTagLength:policy.tag_bytes});
  cipher.setAAD(associatedData(binding));
  return Buffer.concat([nonce,cipher.update(credential,'utf8'),cipher.final(),cipher.getAuthTag()]).toString('base64url');
}

export function openUserProviderKey(master: Buffer, binding: UserProviderBinding, box: string) {
  if (!/^[A-Za-z0-9_-]{39,720}$/.test(box)) return null;
  const bytes = Buffer.from(box,'base64url');
  const overhead = policy.nonce_bytes + policy.tag_bytes;
  if (bytes.toString('base64url') !== box || bytes.length <= overhead || bytes.length > overhead + policy.max_key_bytes) return null;
  try {
    const decipher = createDecipheriv('aes-256-gcm',master,bytes.subarray(0,policy.nonce_bytes),{authTagLength:policy.tag_bytes});
    decipher.setAAD(associatedData(binding));
    decipher.setAuthTag(bytes.subarray(-policy.tag_bytes));
    const token = Buffer.concat([decipher.update(bytes.subarray(policy.nonce_bytes,-policy.tag_bytes)),decipher.final()]).toString('utf8');
    return validUserProviderKey(token) ? token : null;
  } catch { return null; }
}
