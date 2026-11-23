import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';

export const chunkSize = 768;
export const chunkOverlap = 128;
export const embeddingBatch = 8;
export const verificationText = 'NekoTribe public knowledge index';
export const maxSourceId = 999_999_999_999_999;
export const versionPattern = /^[0-9a-f]{64}$/;
const collectionPattern = /^neko_knowledge_[a-z0-9][a-z0-9_]{0,47}$/;
const groupCollectionPattern = /^neko_group_knowledge_[a-z0-9][a-z0-9_]{0,47}$/;
const revisionPattern = /^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$/;
const envPattern = /^AI_EMBEDDING_KEY_[A-Z0-9_]{1,46}$/;

export function baseUrl(value) {
  if (typeof value !== 'string' || !value || value.length > 2048 || value.trim() !== value) throw Error('INVALID_URL');
  const url = new URL(value);
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) throw Error('INVALID_URL');
  return url.href.replace(/\/+$/, '');
}

export async function readProfile(path, scope = 'public') {
  if (!path) throw Error('PROFILE_REQUIRED');
  const file = await readFile(path);
  if (file.length > 16384) throw Error('INVALID_PROFILE');
  const value = JSON.parse(new TextDecoder('utf-8', { fatal:true }).decode(file));
  const profile = parseProfile(value);
  if ((profile.scope ?? 'public') !== scope) throw Error('INVALID_PROFILE');
  return profile;
}

export function parseProfile(value) {
  const group = value?.scope === 'group';
  const fields = ['version','collection','adapter','baseUrl','model','modelRevision','dimensions','keyEnv'];
  if (group) fields.push('scope');
  if (!value || Object.keys(value).length !== fields.length || !fields.every(key => Object.hasOwn(value,key)) ||
      value.version !== 1 || typeof value.collection !== 'string' || !(group ? groupCollectionPattern : collectionPattern).test(value.collection) ||
      !['ollama','openai-compatible'].includes(value.adapter) || typeof value.model !== 'string' ||
      !value.model || !/^[A-Za-z0-9][A-Za-z0-9._:/-]{0,191}$/.test(value.model) ||
      typeof value.modelRevision !== 'string' || !revisionPattern.test(value.modelRevision) ||
      !Number.isInteger(value.dimensions) || value.dimensions < 1 || value.dimensions > 4096 ||
      (value.keyEnv !== null && (typeof value.keyEnv !== 'string' || !envPattern.test(value.keyEnv)))) throw Error('INVALID_PROFILE');
  const {version,collection,adapter,model,modelRevision,dimensions,keyEnv} = value;
  return {version,collection,adapter,baseUrl:baseUrl(value.baseUrl),model,modelRevision,dimensions,keyEnv,...(group ? {scope:'group'} : {})};
}

export function profileFingerprint(profile) {
  return createHash('sha256').update(JSON.stringify({profile,chunkSize,chunkOverlap})).digest('hex');
}

export function credential(value) {
  if (typeof value !== 'string' || !/^[!-~]{1,512}$/.test(value)) throw Error('CREDENTIAL_REQUIRED');
  return value;
}

export const groupSourceKinds = ['group_post','group_comment'];
const sourceKinds = ['post','comment','terms',...groupSourceKinds];

export function validGroupId(id) {
  return Number.isSafeInteger(id) && id > 0;
}

export function validCandidate(value) {
  return value && sourceKinds.includes(value.kind) &&
    Number.isSafeInteger(value.id) && value.id >= 1 && value.id <= (value.kind === 'terms' ? 8 : maxSourceId) &&
    typeof value.version === 'string' && versionPattern.test(value.version);
}
