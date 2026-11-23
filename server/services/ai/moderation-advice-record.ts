import { createHash } from 'node:crypto';
import type { H3Event } from 'h3';
import type { Connection } from 'oracledb';
import contract from '../../../specifications/requirements/ai-moderation-advice.json';
import catalog from '../../../specifications/requirements/ai-public-terms-catalog.json';
import { v2Auth, v2BadRequest, v2Conflict, v2Rows, v2ServerError } from '~/server/utils/v2';
import { hasTooManyAiBodyMembers } from './knowledge-search-body';
import { readTermsAuthority } from './public-terms-authority';
import { parseTermsCatalog } from './public-terms-source';
import { moderationImagesCurrent, validImageReferences, type ImageReference } from './vision-image-record';

export type ModerationTargetType = keyof typeof contract.queries;
export type ModerationLocale = 'zh' | 'en';
export interface ModerationRequest {
  target_type: ModerationTargetType;
  target_id: number;
  expected_sequence: number;
  locale: ModerationLocale;
  skill_id?: 'moderation-advice';
}
interface TargetReference {
  target_type: ModerationTargetType;
  target_id: number;
  group_id: number | null;
  post_id: number;
  digest: string;
}
interface Advice {
  risk: string;
  reason: string;
  recommendation: string;
  rule_ids: number[];
}
interface AdviceRecord {
  target: TargetReference;
  locale: ModerationLocale;
  terms_digest: string;
  terms_generation: number;
  skill_generation: number;
  advice: Advice;
}
export type ModerationAdviceRecord = AdviceRecord & (
  { version: 1 } | { version: 2; image_sources: ImageReference[] }
);

const signedLimit = 999_999_999_999_999;
const validId = (value: unknown): value is number => typeof value === 'number' && Number.isSafeInteger(value) &&
  value > 0 && value <= signedLimit;
const validDigest = (value: unknown): value is string => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value) && value.length === 64;
const validKind = (value: unknown): value is ModerationTargetType => typeof value === 'string' && Object.hasOwn(contract.queries, value);
const validLocale = (value: unknown): value is ModerationLocale => value === 'zh' || value === 'en';
const grouped = (kind: ModerationTargetType) => kind.startsWith('group_');
const post = (kind: ModerationTargetType) => kind === 'post' || kind === 'group_post';
function fields(value: unknown): Record<string, unknown> | null {
  return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null;
}
const rulesFor = (locale: ModerationLocale) => parseTermsCatalog(catalog).filter(row => row.locale === locale);
export const moderationPrompt = contract.system;
export const moderationResponseSchema = contract.responseSchema;
export class ModerationAdviceUnavailable extends Error {}

export function parseModerationRequest(bytes: Uint8Array): ModerationRequest {
  try {
    const text = new TextDecoder('utf-8', {fatal:true,ignoreBOM:true}).decode(bytes);
    const request = fields(JSON.parse(text));
    const hasSkill = !!request && Object.hasOwn(request, 'skill_id');
    const fieldCount = hasSkill ? 5 : 4;
    if (request && Object.keys(request).length === fieldCount && !hasTooManyAiBodyMembers(text, fieldCount) &&
        (!hasSkill || request.skill_id === 'moderation-advice') &&
        validKind(request.target_type) && validId(request.target_id) && validLocale(request.locale) &&
        typeof request.expected_sequence === 'number' && Number.isSafeInteger(request.expected_sequence) &&
        request.expected_sequence >= 0 && request.expected_sequence < 9999999999) {
      return {target_type:request.target_type,target_id:request.target_id,
        expected_sequence:request.expected_sequence,locale:request.locale,
        ...(hasSkill ? {skill_id:'moderation-advice' as const} : {})};
    }
  } catch { /* Return the same public error for malformed JSON. */ }
  v2BadRequest('审核建议参数错误');
}

function parseAdvice(value: unknown, allowed: number[]): Advice | null {
  const obj = fields(value);
  if (!obj || Object.keys(obj).length !== 4) return null;
  const {risk, reason, recommendation, rule_ids} = obj;
  if (typeof risk !== 'string' || !contract.responseSchema.properties.risk.enum.includes(risk) ||
      typeof recommendation !== 'string' || !contract.responseSchema.properties.recommendation.enum.includes(recommendation) ||
      (risk === 'none' && recommendation === 'consider_removal') ||
      typeof reason !== 'string' || !reason.isWellFormed() || !reason.trim() || Buffer.byteLength(reason) > 1200 ||
      !Array.isArray(rule_ids) || rule_ids.length < 1 || rule_ids.length > 4 ||
      new Set(rule_ids).size !== rule_ids.length || !rule_ids.every(id => typeof id === 'number' && allowed.includes(id))) return null;
  return {risk,reason,recommendation,rule_ids};
}
export function parseModelAdvice(raw: string, allowed: number[]): Advice {
  try {
    if (Buffer.byteLength(raw) <= 4096 && !hasTooManyAiBodyMembers(raw, 4)) {
      const advice = parseAdvice(JSON.parse(raw), allowed);
      if (advice) return advice;
    }
  } catch { /* Invalid model output is never returned to the client. */ }
  throw new ModerationAdviceUnavailable();
}

export function decodeModerationAdvice(text: string): ModerationAdviceRecord | null {
  try {
    const record = fields(JSON.parse(text));
    const target = fields(record?.target);
    if (!record || (record.version !== 1 && record.version !== 2) || !target || !validKind(target.target_type) ||
        !validId(target.target_id) || !validId(target.post_id) ||
        (post(target.target_type) && target.post_id !== target.target_id) ||
        (grouped(target.target_type) ? !validId(target.group_id) : target.group_id !== null) ||
        !validDigest(target.digest) || !validLocale(record.locale) || !validId(record.skill_generation) ||
        !validId(record.terms_generation) || !validDigest(record.terms_digest)) return null;
    if (!parseAdvice(record.advice, rulesFor(record.locale).map(rule => rule.id)) ||
        (record.version === 2 && (!post(target.target_type) || !validImageReferences(record.image_sources))) ||
        (record.version === 1 && 'image_sources' in record)) return null;
    return record as unknown as ModerationAdviceRecord;
  } catch {
    return null;
  }
}

export async function readModerationMaterial(
  event: H3Event, connection: Connection, request: Pick<ModerationRequest,'target_type'|'target_id'|'locale'>,
  lockRules = false, allowImageOnly = false,
) {
  const actor = v2Auth(event);
  const rows = await v2Rows(connection, contract.queries[request.target_type], {actor_id:actor.userId,target_id:request.target_id});
  const row = rows[0];
  if (!row) return null;
  const {CONTENT,POST_ID,GROUP_ID,TEXT_LENGTH} = row;
  if (rows.length !== 1 || !validId(POST_ID) || (post(request.target_type) && POST_ID !== request.target_id) ||
      (grouped(request.target_type) ? !validId(GROUP_ID) : GROUP_ID !== null)) v2ServerError();
  const imageOnly = allowImageOnly && request.target_type === 'post' && (CONTENT === null || CONTENT === '');
  if (!imageOnly && (CONTENT === null || !validId(TEXT_LENGTH) || TEXT_LENGTH > 1000)) return null;
  const content = imageOnly ? '' : CONTENT;
  if (typeof content !== 'string' || !content.isWellFormed()) v2ServerError();
  if ((!content.trim() && !(allowImageOnly && request.target_type === 'post')) || Buffer.byteLength(content) > 4000) return null;
  const groupId = grouped(request.target_type) ? GROUP_ID as number : null;
  const hash = createHash('sha256');
  for (const value of ['moderation-target-v1',request.target_type,String(request.target_id),String(POST_ID),groupId === null ? '' : String(groupId),content]) {
    hash.update(`${Buffer.byteLength(value)}:`).update(value);
  }
  const authority = await readTermsAuthority(event, connection, catalog, {lock:lockRules});
  const selected = rulesFor(request.locale);
  return {
    target: {target_type:request.target_type,target_id:request.target_id,
      post_id:POST_ID,group_id:groupId,digest:hash.digest('hex')},
    content, authority,
    rules:selected.map(rule=>({id:rule.id,version:rule.version,title:rule.title,blocks:rule.blocks})),
  };
}

export async function currentModerationAdvice(
  event: H3Event, connection: Connection, record: ModerationAdviceRecord, lockRules = false,
) {
  const current = await readModerationMaterial(event, connection, {...record.target,locale:record.locale}, lockRules, record.version === 2);
  if (!current || current.target.digest !== record.target.digest ||
      current.authority.digest !== record.terms_digest || current.authority.generation !== record.terms_generation) return null;
  if (record.version === 2) {
    const kind = record.target.target_type;
    if ((kind !== 'post' && kind !== 'group_post') ||
        !await moderationImagesCurrent(connection,v2Auth(event).userId,kind,record.target.target_id,record.image_sources)) return null;
  }
  return {
    ...record.advice,
    ...(record.version === 2 ? {analysis_mode:'text_and_images' as const} : {}),
    target: {kind:record.target.target_type,id:record.target.target_id,post_id:record.target.post_id,group_id:record.target.group_id},
    rules:current.rules.filter(rule=>record.advice.rule_ids.includes(rule.id)).map(({id,version})=>({kind:'terms' as const,id,version})),
  };
}

export async function requireCurrentModerationAdvice(
  event: H3Event, connection: Connection, record: ModerationAdviceRecord, lock = false,
) {
  if (!await currentModerationAdvice(event, connection, record,lock)) v2Conflict('会话已变更，请重试');
}
