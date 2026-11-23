import type { GenerationDelta } from './ai-stream';
import { v2RequestData } from './client';
import { validateAiConversationPage } from '../../utils/ai-conversation-page';
import { aiModelVersion, isAiReplyConfigRevision } from '@/utils/ai-model-version';

export const groupDraftKinds = ['weekly_report', 'faq', 'announcement', 'activity_plan'] as const;
export type GroupDraftKind = typeof groupDraftKinds[number];
type GroupDraftTool = 'public_search' | 'public_statistics' | 'community_sentiment_summary';
export interface GroupDraftSource { kind: 'post' | 'comment'; source_id: number; post_id: number }
export interface GroupDraftMessage {
  id: string;
  sequence: number;
  role: string;
  content: string;
  modelVersion: string | null;
  configRevision: number | null;
  sources: GroupDraftSource[];
  tools: GroupDraftTool[];
}
export interface GroupDraftConversation {
  id: string;
  purpose: string;
  groupId: number | null;
  title: string | null;
  updatedAt: string;
}

const base = '/api/v2/ai/conversations';
const path = (id: string) => `${base}/${encodeURIComponent(id)}`;
const isId = (id: unknown): id is number => typeof id === 'number' && Number.isSafeInteger(id) && id > 0;
const isConversationId = (id: unknown): id is string => typeof id === 'string' &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id);
function record(value: unknown): Record<string, unknown> {
  if (typeof value !== 'object' || !value || Array.isArray(value)) throw new Error('Invalid AI response');
  return value as Record<string, unknown>;
}

function parseConversation(value: unknown): GroupDraftConversation {
  const { conversation_id, purpose, group_id, title, updated_at } = record(value);
  if (!isConversationId(conversation_id) || typeof purpose !== 'string' ||
      (group_id !== null && !isId(group_id)) || (title !== null && typeof title !== 'string') ||
      typeof updated_at !== 'string') throw new Error('Invalid AI conversation');
  return {id:conversation_id, purpose, groupId:group_id, title, updatedAt:updated_at};
}
function parseMessage(value: unknown, conversationId: string): GroupDraftMessage {
  const { message_id, conversation_id, sequence_no, role, content, group_sources, group_tools, model_version, config_revision } = record(value);
  if (conversation_id !== conversationId || typeof message_id !== 'string' || !message_id || !isId(sequence_no) || sequence_no > 9999999999 ||
      typeof role !== 'string' || typeof content !== 'string') throw new Error('Invalid AI message');
  const sources = group_sources === undefined ? [] : group_sources;
  if (!Array.isArray(sources) || sources.length > 8) throw new Error('Invalid AI sources');
  const tools = group_tools === undefined ? [] : group_tools;
  if (!Array.isArray(tools) || (group_tools !== undefined && (
    role !== 'assistant' || !sources.length || tools.length > 3 ||
    !tools.includes('public_search') || new Set(tools).size !== tools.length ||
    !tools.every(tool => tool === 'public_search' || tool === 'public_statistics' || tool === 'community_sentiment_summary')
  ))) throw new Error('Invalid AI group tools');
  return {id:message_id, sequence:sequence_no, role, content, modelVersion:aiModelVersion(role, model_version),
    configRevision:isAiReplyConfigRevision(role, config_revision) ? config_revision : null,
    tools:tools as GroupDraftTool[], sources:sources.map(item => {
    const {kind, source_id, post_id} = record(item);
    if ((kind !== 'post' && kind !== 'comment') || !isId(source_id) ||
        !isId(post_id) || (kind === 'post' && source_id !== post_id)) throw new Error('Invalid AI source');
    return {kind, source_id, post_id};
  })};
}

export function createGroupDraftApi(run: <T>(request: () => Promise<T>) => Promise<T>) {
  return {
    async list(groupId: number, after: string | null, signal: AbortSignal) {
      const data = await run(() => v2RequestData<unknown, undefined, {limit:number;purpose:'group';group_id:number;after_id?:string}>(base, {
        query:{limit:50, purpose:'group', group_id:groupId, ...(after ? {after_id:after} : {})}, signal,
      }));
      const {items, next_cursor} = record(data);
      if (!Array.isArray(items) || items.length > 50) throw new Error('Invalid AI history');
      const entries = items.map(parseConversation);
      const next = validateAiConversationPage(entries.map(item => item.id), after, next_cursor);
      return {items:entries, next};
    },
    async create(groupId: number, signal: AbortSignal) {
      const result = parseConversation(await run(() => v2RequestData<unknown, {purpose:string;group_id:number}>(base, {
        method:'POST', body:{purpose:'group', group_id:groupId}, signal,
      })));
      if (result.purpose !== 'group' || result.groupId !== groupId) throw new Error('Invalid AI group');
      return result;
    },
    async messages(id: string, after: number, limit: number, signal: AbortSignal, before?: number) {
      const result = await run(() => v2RequestData<unknown, undefined, {after_sequence?:number;before_sequence?:number;limit:number}>(`${path(id)}/messages`, {
        query: before === undefined ? {after_sequence:after, limit} : {before_sequence:before, limit}, signal,
      }));
      if (!Array.isArray(result) || result.length > limit) throw new Error('Invalid AI messages');
      const messages = result.map(row => parseMessage(row, id));
      const ids = new Set<string>();
      let previous = after;
      for (const message of messages) {
        if (ids.has(message.id) || message.sequence <= previous || (before !== undefined && message.sequence >= before)) {
          throw new Error('Invalid AI history page');
        }
        ids.add(message.id);
        previous = message.sequence;
      }
      return messages;
    },
    async remove(id: string, signal: AbortSignal) {
      const data = await run(() => v2RequestData<unknown>(path(id), {method:'DELETE',signal}));
      if (data !== null) throw new Error('Invalid delete receipt');
    },
    async generate(id: string, kind: GroupDraftKind, sequence: number, signal: AbortSignal, skillId?: 'group-brief', searchTerm?: string, onDelta?: GenerationDelta) {
      const result = record(await run(() => v2RequestData<unknown, {kind:GroupDraftKind;expected_sequence:number;skill_id?:'group-brief';search_term?:string}>(`${path(id)}/group-generate`, {
        method:'POST', body:{kind, expected_sequence:sequence, ...(skillId ? {skill_id:skillId} : {}),
          ...(searchTerm ? {search_term:searchTerm} : {})}, signal, ...(onDelta ? {onDelta} : {})})));
      if (result.status === 'insufficient_evidence' && result.message === null) return false;
      if (result.status === 'generated') {
        const receipt = record(result.message);
        if (typeof receipt.message_id === 'string' && receipt.message_id &&
            receipt.conversation_id === id && receipt.sequence_no === sequence + 1 && receipt.role === 'assistant') return true;
      }
      throw new Error('Invalid AI generation receipt');
    },
  };
}
