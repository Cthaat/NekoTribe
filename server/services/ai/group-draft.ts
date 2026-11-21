import type { H3Event } from 'h3';
import type { Connection } from 'oracledb';
import { v2Auth, v2BadRequest, v2Conflict, v2Connection, v2One } from '~/server/utils/v2';
import { AiQuotaError, requireAiModelQuota } from '~/server/utils/ai-model-quota';
import { AiRunAudit } from './run-audit';
import { appendGroupDraft, readConversation } from './conversation-store';
import { groupDraftExamplesTool, groupDraftSystem, groupDraftTools, groupEvidenceDigest, groupLookback,
  isGroupDraftKind, validGroupDraftTools, validGroupSearchTerm, type GroupDraftKind } from './group-draft-record';
import { readGroupEvidence } from './group-evidence';
import { AiInferenceTransport, type AiInferenceResult } from './inference-transport';
import type { AiModelRouter } from './model-configuration';
import { configuredModelRouter } from './model-source';
import { hasTooManyAiBodyMembers } from './knowledge-search-body';
import { selectConfiguredConversationSkill } from './skill-conversation';

export class GroupDraftUnavailable extends Error {}
export interface GroupDraftRequest {
  kind: GroupDraftKind;
  expected_sequence: number;
  skill_id?: 'group-brief';
  search_term?: string;
}

export function parseGroupDraftRequest(bytes: Uint8Array): GroupDraftRequest {
  let body: Partial<GroupDraftRequest> | null;
  let text: string;
  try {
    text = new TextDecoder('utf-8', {fatal:true, ignoreBOM:true}).decode(bytes);
    body = JSON.parse(text);
  }
  catch { v2BadRequest('群运营草稿参数错误'); }
  if (!body || typeof body !== 'object' ||
      Object.keys(body).length !== 2 + Number(Object.hasOwn(body, 'skill_id')) + Number(Object.hasOwn(body, 'search_term')) ||
      hasTooManyAiBodyMembers(text, Object.keys(body).length) ||
      (Object.hasOwn(body, 'skill_id') && body.skill_id !== 'group-brief') ||
      (Object.hasOwn(body, 'search_term') && !validGroupSearchTerm(body.search_term)) ||
      !isGroupDraftKind(body.kind) || typeof body.expected_sequence !== 'number' ||
      !Number.isSafeInteger(body.expected_sequence) || body.expected_sequence < 0 || body.expected_sequence >= 9999999999) {
    v2BadRequest('群运营草稿参数错误');
  }
  return { kind: body.kind, expected_sequence: body.expected_sequence,
    ...(body.skill_id ? { skill_id: body.skill_id } : {}),
    ...(body.search_term ? { search_term: body.search_term } : {}) };
}

async function withConnection<T>(event: H3Event, action: (connection: Connection) => Promise<T>): Promise<T> {
  const connection = await v2Connection(event);
  try { return await action(connection); }
  finally { await connection.close(); }
}

function encodeGroupDraftInput(value: object): string {
  return JSON.stringify(value).replaceAll('\u2028','\\u2028').replaceAll('\u2029','\\u2029');
}

export async function generateGroupDraft(event: H3Event, id: string, request: GroupDraftRequest, signal: AbortSignal) {
  const actor = v2Auth(event);
  signal.throwIfAborted();
  const load = (searchTerm?: string) => withConnection(event, async connection => {
    const conversation = await readConversation(event, connection, id);
    if (conversation.purpose !== 'group' || conversation.group_id === null) v2BadRequest('群运营草稿参数错误');
    const evidence = await readGroupEvidence(event, connection, conversation.group_id, {
      lookbackDays: groupLookback(request.kind), ...(searchTerm === undefined ? {} : {searchTerm, matchExcerpt:true}),
    });
    const sequence = await v2One(connection, 'SELECT NVL(MAX(sequence_no),0) AS last_sequence FROM n_ai_messages WHERE conversation_id=:conversation_id', {conversation_id:id});
    if (sequence?.LAST_SEQUENCE !== request.expected_sequence) v2Conflict('会话已变更，请重试');
    const selected = await selectConfiguredConversationSkill(event, connection, {
      ownerUserId: actor.userId, purpose: 'group', groupId: conversation.group_id,
    }, request.skill_id ?? null);
    if (groupDraftTools.some(tool => !selected.skill.tools.some(name => name === tool.name))) {
      throw new Error('SKILL_UNAVAILABLE');
    }
    return {evidence, configGeneration: selected.configGeneration};
  });
  const initial = await load(request.search_term);
  const audit = new AiRunAudit('group_draft', initial.configGeneration,
    request.skill_id ? 'explicit' : 'purpose-default');
  try {
    const result = await generateApprovedGroupDraft(event, id, request, signal, actor.userId, initial, load, audit);
    audit.finish(result.status);
    return result;
  } catch (error) {
    audit.fail(error, signal);
    throw error;
  }
}

type DraftEvidence = {evidence: Awaited<ReturnType<typeof readGroupEvidence>>; configGeneration: number};
async function generateApprovedGroupDraft(
  event: H3Event, id: string, request: GroupDraftRequest, signal: AbortSignal, actor: number,
  initial: DraftEvidence, load: (searchTerm?: string) => Promise<DraftEvidence>, audit: AiRunAudit,
) {
  signal.throwIfAborted();
  if (!initial.evidence.examples.length) return {status:'insufficient_evidence', message:null} as const;
  let selection: ReturnType<AiModelRouter['select']>;
  let transport: AiInferenceTransport;
  let calls: AiInferenceResult['toolCalls'];
  let toolsUsed: string[];
  let searchTerm = request.search_term;
  let budget: number;
  const messages = [
    {role:'system',content:groupDraftSystem(request.kind)},
    {role:'user',content:encodeGroupDraftInput({kind:request.kind,
      ...(searchTerm === undefined ? {} : {search_term:searchTerm})})},
  ];
  audit.stage = 'configuration';
  try {
    selection = (await configuredModelRouter()).select('agent', ['tools']);
    audit.configRevision = selection.configurationRevision;
    budget = Math.min(16384, selection.contextWindowTokens - selection.maxOutputTokens - 512);
    const packet = {messages, tools:groupDraftTools};
    if (Buffer.byteLength(encodeGroupDraftInput(packet)) + 64 > budget) throw new Error();
    transport = new AiInferenceTransport(reference => process.env[reference]);
    signal.throwIfAborted();
    audit.stage = 'quota';
    await requireAiModelQuota(event, actor, 2);
    signal.throwIfAborted();
    audit.stage = 'proposal';
    const reply = await transport.infer(selection, packet, signal);
    calls = reply.toolCalls;
    toolsUsed = calls.map(call => call.name);
    if (reply.finishReason !== 'tool-calls' || !validGroupDraftTools(toolsUsed)) throw new Error();
    for (const call of calls) {
      const keys = Object.keys(call.arguments);
      if (!keys.length) continue;
      const term = call.arguments.search_term;
      if (call.name !== groupDraftExamplesTool || keys.length !== 1 ||
          keys[0] !== 'search_term' || !validGroupSearchTerm(term) ||
          (request.search_term !== undefined && term !== request.search_term)) throw new Error();
      searchTerm = term;
    }
  } catch (error) {
    if (error instanceof AiQuotaError) throw error;
    throw new GroupDraftUnavailable();
  }

  signal.throwIfAborted();
  audit.stage = 'evidence';
  const {evidence, configGeneration} = await load(searchTerm);
  signal.throwIfAborted();
  if (configGeneration !== initial.configGeneration) v2Conflict('会话已变更，请重试');
  if (!evidence.examples.length) return {status:'insufficient_evidence', message:null} as const;
  audit.toolCount = toolsUsed.length;

  let draft: string;
  try {
    const nextPacket = () => ({
      messages: [...messages, {role:'assistant',content:'',toolCalls:calls}, ...calls.map(call => ({
        role:'tool', toolCallId:call.id,
        content:encodeGroupDraftInput({
          window_start:evidence.window_start, window_end:evidence.window_end,
          ...(call.name === groupDraftExamplesTool ? {examples:evidence.examples} :
            {posts_count:evidence.posts_count,comments_count:evidence.comments_count}),
        }),
      }))],
    });
    let packet = nextPacket();
    while (Buffer.byteLength(encodeGroupDraftInput(packet)) + 64 > budget) {
      if (evidence.examples.length <= 1) throw new Error();
      evidence.examples.pop();
      packet = nextPacket();
    }
    audit.stage = 'inference';
    const reply = await transport.infer(selection, packet, signal);
    if (reply.finishReason !== 'stop' || reply.toolCalls.length || !reply.text.trim() ||
        !reply.text.isWellFormed() || Buffer.byteLength(reply.text) > 8192) throw new Error();
    draft = reply.text;
  } catch {
    throw new GroupDraftUnavailable();
  }
  signal.throwIfAborted();
  audit.stage = 'persist';
  const message = await withConnection(event, connection => appendGroupDraft(event, connection, id, {
    expectedSequence: request.expected_sequence, modelId: selection.profileId,
    ...(selection.modelVersion !== undefined ? { modelVersion: selection.modelVersion } : {}),
    configRevision: selection.configurationRevision, signal,
    draft: {version:1, kind:request.kind, window_end:evidence.window_end,
      source_digest:groupEvidenceDigest(evidence), example_count:evidence.examples.length,
      skill_generation:configGeneration, draft, tools_used:toolsUsed,
      ...(searchTerm === undefined ? {} : {search_term:searchTerm, match_excerpt:true})},
  }));
  return {status:'generated', message} as const;
}
