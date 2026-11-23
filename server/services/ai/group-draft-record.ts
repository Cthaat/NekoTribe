import { createHash } from 'node:crypto';
import type { H3Event } from 'h3';
import type { Connection } from 'oracledb';
import contract from '../../../specifications/requirements/ai-group-draft.json';
import { v2Conflict } from '~/server/utils/v2';
import { readGroupEvidence, readGroupSentimentEvidence, type GroupEvidence } from './group-evidence';
import { communitySentimentTool } from './sentiment-flow';

export type GroupDraftKind = keyof typeof contract.lookbackDays;
export interface GroupDraftRecord {
  version: 1;
  kind: GroupDraftKind;
  window_end: string;
  source_digest: string;
  example_count: number;
  skill_generation: number;
  draft: string;
  tools_used?: string[];
  search_term?: string;
  match_excerpt?: true;
  sentiment_source_digest?: string;
}
export function groupDraftSystem(kind: GroupDraftKind, sentiment = false) {
  return [contract.system,
    ...(kind === 'activity_plan' ? [contract.activityPlanInstruction] : []),
    ...(sentiment ? ['需要讨论情绪变化时可一并请求 community_sentiment_summary，只传空对象。将结果标明为样本趋势。服务不可用时利用其它资料继续，不编造情绪统计。'] : []),
  ].join('\n');
}
export const groupDraftTools = contract.tools;
export const groupDraftExamplesTool = contract.requiredTool;
export const validGroupSearchTerm = (value: unknown): value is string =>
  typeof value === 'string' && value.length > 0 && value === value.trim() &&
  value.isWellFormed() && Buffer.byteLength(value) <= 256 && !/[\u0000-\u001f\u007f]/.test(value);
export function validGroupDraftTools(names: readonly unknown[]): boolean {
  return names.length <= groupDraftTools.length + 1 && names.includes(groupDraftExamplesTool) &&
    new Set(names).size === names.length &&
    names.every(name => name === communitySentimentTool.name || groupDraftTools.some(tool => tool.name === name));
}
export function isGroupDraftKind(value: unknown): value is GroupDraftKind {
  return typeof value === 'string' && Object.hasOwn(contract.lookbackDays, value);
}
export function groupLookback(kind: GroupDraftKind): 7 | 30 {
  const days = contract.lookbackDays[kind];
  if (days !== 7 && days !== 30) throw new Error('Unsupported group lookback window');
  return days;
}
export function groupEvidenceDigest(data: GroupEvidence): string {
  const hash = createHash('sha256');
  const add = (value: string | number) => {
    const text = String(value);
    hash.update(Buffer.byteLength(text, 'utf8') + ':').update(text);
  };
  for (const value of ['group-evidence-v1', data.window_start, data.window_end, data.posts_count, data.comments_count]) add(value);
  for (const row of data.examples) {
    for (const value of [row.kind, row.source_id, row.post_id, row.excerpt]) add(value);
  }
  return hash.digest('hex');
}
export function groupSentimentDigest(evidence: {current:GroupEvidence;previous:GroupEvidence}) {
  return createHash('sha256').update(groupEvidenceDigest(evidence.current))
    .update('\n').update(groupEvidenceDigest(evidence.previous)).digest('hex');
}
export function decodeGroupDraft(content: string): GroupDraftRecord | null {
  try {
    const input = JSON.parse(content) as Partial<GroupDraftRecord> | null;
    if (input?.version !== 1 || !isGroupDraftKind(input.kind) ||
        typeof input.window_end !== 'string' ||
        !/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}$/.test(input.window_end) ||
        typeof input.source_digest !== 'string' || !/^[a-f0-9]{64}$/.test(input.source_digest) ||
        typeof input.example_count !== 'number' || !Number.isInteger(input.example_count) ||
        input.example_count < 1 || input.example_count > 8 ||
        !Number.isSafeInteger(input.skill_generation) || input.skill_generation! < 1 ||
        typeof input.draft !== 'string' || !input.draft || !input.draft.isWellFormed() || Buffer.byteLength(input.draft) > 8192 ||
        (input.tools_used !== undefined && (!Array.isArray(input.tools_used) || !validGroupDraftTools(input.tools_used))) ||
        (input.search_term !== undefined && !validGroupSearchTerm(input.search_term)) ||
        (input.match_excerpt !== undefined && (input.match_excerpt !== true || input.search_term === undefined))) return null;
    const hasSentiment = input.tools_used?.includes(communitySentimentTool.name) ?? false;
    if (hasSentiment !== (typeof input.sentiment_source_digest === 'string' && /^[a-f0-9]{64}$/.test(input.sentiment_source_digest)) ||
        (!hasSentiment && input.sentiment_source_digest !== undefined)) return null;
    return input as GroupDraftRecord;
  } catch {
    return null;
  }
}
export async function recheckGroupDraft(
  event: H3Event, connection: Connection, groupId: number, draft: GroupDraftRecord
) {
  const options = {
    lookbackDays: groupLookback(draft.kind), windowEnd: draft.window_end,
    ...(draft.search_term === undefined ? {} : {searchTerm:draft.search_term}),
    matchExcerpt: draft.match_excerpt === true,
  };
  const evidence = await readGroupEvidence(event, connection, groupId, options);
  evidence.examples = evidence.examples.slice(0, draft.example_count);
  if (groupEvidenceDigest(evidence) !== draft.source_digest) return null;
  if (draft.sentiment_source_digest) {
    const samples = await readGroupSentimentEvidence(event,connection,groupId,options);
    if (groupSentimentDigest(samples) !== draft.sentiment_source_digest) return null;
  }
  return evidence;
}
export async function requireCurrentGroupDraft(
  event: H3Event, connection: Connection, groupId: number, draft: GroupDraftRecord
): Promise<void> {
  if (!await recheckGroupDraft(event, connection, groupId, draft)) v2Conflict('会话已变更，请重试');
}
