import { v2RequestData } from './client';
import { validateAiConversationPage } from '../../utils/ai-conversation-page';
import { citationTarget } from '@/services/ai-writing-controller';
import { aiModelVersion, isAiReplyConfigRevision } from '@/utils/ai-model-version';

const targetTypes = ['post', 'comment', 'group_post', 'group_post_comment'] as const;
const risks = ['none', 'spam', 'harassment', 'hate', 'violence', 'adult', 'misinformation', 'copyright', 'other'] as const;
const recommendations = ['no_action', 'human_review', 'consider_removal'] as const;
export const moderationRatings = ['helpful', 'incorrect', 'insufficient'] as const;
export type ModerationRating = typeof moderationRatings[number];
type TargetType = typeof targetTypes[number];
export type ModerationAdviceTarget = { kind: TargetType; id: number };
type Rule = { id: number; version: string; href: string };
export type ModerationAdviceSource = { postId: number; groupId: number | null; commentId: number | null };
type Advice = {
  risk: typeof risks[number]; reason: string; recommendation: typeof recommendations[number];
  rules: Rule[]; source: ModerationAdviceSource | null
};
export type ModerationAdviceMessage = {
  id: string;
  conversationId: string;
  sequence: number;
  createdAt: string;
  modelVersion: string | null;
  configRevision: number | null;
  advice: Advice | null;
  rating: ModerationRating | null;
};
export type ModerationAdviceHistory = {
  conversationId: string | null;
  sequence: number;
  messages: ModerationAdviceMessage[];
  older: Map<string, HistoryCursor>;
  latestSequences: Map<string, number>;
};
type HistoryCursor = {before: number; forwardOnly: boolean};
type HistoryRow = {sequence: number; message: ModerationAdviceMessage | null};

const base = '/api/v2/ai/conversations';
const scopedTitle = ({kind, id}: ModerationAdviceTarget) => `moderation:${kind}:${id}`;
const path = (id: string) => `${base}/${encodeURIComponent(id)}`;
function isMissingConversation(error: unknown): boolean {
  const response = error as {statusCode?: number; status?: number} | null;
  return (response?.statusCode ?? response?.status) === 404;
}
const isUuid = (value: unknown): value is string => typeof value === 'string' &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
const isId = (value: unknown): value is number => typeof value === 'number' &&
  Number.isSafeInteger(value) && value > 0 && value <= 999999999999999;
function oneOf<const T extends string>(values: readonly T[], value: unknown): value is T {
  return values.some(option => option === value);
}
function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid moderation response');
  return value as Record<string, unknown>;
}

export function moderationAdviceTarget(kind: unknown, id: unknown): ModerationAdviceTarget | null {
  const normalized = kind === 'group_comment' ? 'group_post_comment' : kind;
  return oneOf(targetTypes, normalized) && isId(id) ? {kind: normalized, id} : null;
}

function parseAdvice(raw: unknown, target: ModerationAdviceTarget): Advice | null {
  if (raw === null || raw === undefined) return null;
  const {risk, reason, recommendation, rules, rule_ids, target: rawTarget} = record(raw);
  const {kind, id, post_id: postId, group_id: groupId} = record(rawTarget);
  if (kind !== target.kind || id !== target.id) return null;
  if (!oneOf(risks, risk) || !oneOf(recommendations, recommendation) ||
      typeof reason !== 'string' || !reason.trim() || new TextEncoder().encode(reason).length > 1200 ||
      !Array.isArray(rules) || !rules.length || rules.length > 4 || !Array.isArray(rule_ids) ||
      rule_ids.length !== rules.length || new Set(rule_ids).size !== rules.length) {
    throw new Error('Invalid moderation advice');
  }
  const unseen = new Set<unknown>(rule_ids);
  const grouped = target.kind === 'group_post' || target.kind === 'group_post_comment';
  const comment = target.kind === 'comment' || target.kind === 'group_post_comment';
  const source = isId(postId) && (comment || postId === target.id) &&
    (grouped ? isId(groupId) : groupId == null)
    ? { postId, groupId: isId(groupId) ? groupId : null, commentId: comment ? target.id : null }
    : null;
  return {risk, reason, recommendation, source, rules: rules.map(rawRule => {
    const {kind, id, version} = record(rawRule);
    if (kind !== 'terms' || !isId(id) || !unseen.delete(id) || typeof version !== 'string') {
      throw new Error('Invalid moderation rule');
    }
    const link = citationTarget({kind, id, version});
    if (link?.kind !== 'terms') throw new Error('Invalid moderation rule');
    return {id, version, href: link.href};
  })};
}

export function createModerationAdviceApi(run: <T>(request: () => Promise<T>) => Promise<T>) {
  async function readPage(id: string, target: ModerationAdviceTarget, signal: AbortSignal,
    cursor: {before_sequence: number} | {after_sequence: number}, limit = 50) {
    const parsed: HistoryRow[] = [];
    let sequence = 'after_sequence' in cursor ? cursor.after_sequence : 0;
    signal.throwIfAborted();
    const rows = await run(() => v2RequestData<unknown, undefined, typeof cursor & {limit: number}>(`${path(id)}/messages`, {
      query: {...cursor, limit}, signal,
    }));
    if (!Array.isArray(rows) || rows.length > limit) throw new Error('Invalid moderation history');
    const ids = new Set<string>();
    for (const row of rows) {
      const {message_id, conversation_id, sequence_no, role, created_at, moderation_advice, moderation_feedback, model_version, config_revision} = record(row);
      if (!isUuid(message_id) || ids.has(message_id) || conversation_id !== id || !isId(sequence_no) ||
          sequence_no <= sequence || sequence_no > 9999999999 ||
          ('before_sequence' in cursor && sequence_no >= cursor.before_sequence) ||
          typeof created_at !== 'string') {
        throw new Error('Invalid moderation message');
      }
      ids.add(message_id);
      sequence = sequence_no;
      let message: ModerationAdviceMessage | null = null;
      if (role === 'assistant') {
        const advice = parseAdvice(moderation_advice, target);
        message = {
          id: message_id,
          conversationId: id,
          sequence: sequence_no,
          createdAt: created_at,
          modelVersion: aiModelVersion(role, model_version),
          configRevision: isAiReplyConfigRevision(role, config_revision) ? config_revision : null,
          advice,
          rating: advice && oneOf(moderationRatings, moderation_feedback) ? moderation_feedback : null,
        };
      }
      parsed.push({sequence, message});
    }
    return parsed;
  }

  async function readForwardPage(id: string, target: ModerationAdviceTarget, signal: AbortSignal,
    result: HistoryRow[] = [], before = 10_000_000_000) {
    let after = result.at(-1)?.sequence ?? 0;
    for (;;) {
      const page = await readPage(id, target, signal, {after_sequence: after});
      result = [...result, ...page.filter(row => row.sequence < before)].slice(-50);
      const last = page.at(-1)?.sequence ?? after;
      if (page.length < 50 || last >= before) return result;
      after = last;
    }
  }

  async function readConversation(id: string, target: ModerationAdviceTarget, signal: AbortSignal) {
    const head = await readPage(id, target, signal, {before_sequence: 10_000_000_000});
    // A server that ignores the backward cursor may have returned page one.
    const forwardOnly = head.length === 50 && head[0]?.sequence === 1;
    return {rows: forwardOnly ? await readForwardPage(id, target, signal, head) : head, forwardOnly};
  }
  const visibleMessages = (rows: HistoryRow[]) => rows.flatMap(row => row.message ? [row.message] : []);
  function assembleHistory(
    latestSequences: Map<string, number>,
    messages: ModerationAdviceMessage[],
    older: Map<string, HistoryCursor>
  ): ModerationAdviceHistory {
    const [conversationId, sequence] = latestSequences.entries().next().value ?? [null, 0];
    const remaining = messages.filter(message => latestSequences.has(message.conversationId));
    remaining.sort((a, b) => b.createdAt.localeCompare(a.createdAt) || b.id.localeCompare(a.id));
    return {conversationId, sequence, latestSequences, messages: remaining, older};
  }

  return {
    async remove(id: string, signal: AbortSignal) {
      const data = await run(() => v2RequestData<unknown>(path(id), {method:'DELETE', signal}));
      if (data !== null) throw new Error('Invalid delete receipt');
    },
    async rate(message: ModerationAdviceMessage, rating: ModerationRating, target: ModerationAdviceTarget, signal: AbortSignal) {
      const endpoint = `${path(message.conversationId)}/messages/${encodeURIComponent(message.id)}/moderation-feedback`;
      const receipt = record(await run(() => v2RequestData<unknown, {rating: ModerationRating}>(endpoint, {
        method: 'PUT', body: {rating}, signal,
      })));
      if (receipt.message_id !== message.id || receipt.rating !== rating) throw new Error('Invalid moderation feedback receipt');
      const [row] = await readPage(message.conversationId, target, signal, {after_sequence: message.sequence - 1}, 1);
      const confirmed = row?.message;
      return confirmed?.id === message.id && confirmed.sequence === message.sequence &&
        confirmed.advice && confirmed.rating === rating ? confirmed : null;
    },
    async history(target: ModerationAdviceTarget, signal: AbortSignal): Promise<ModerationAdviceHistory> {
      const messages: ModerationAdviceMessage[] = [];
      const older = new Map<string, HistoryCursor>();
      const latestSequences = new Map<string, number>();
      let after: string | null = null;
      do {
        signal.throwIfAborted();
        const cursor: string | null = after;
        const data = record(await run(() => v2RequestData<unknown, undefined, {limit: number; purpose:'moderation'; target_type: TargetType; target_id: number; after_id?: string}>(base, {
          query: {limit: 50, purpose:'moderation', target_type: target.kind, target_id: target.id, ...(cursor ? {after_id: cursor} : {})}, signal,
        })));
        const {items, next_cursor} = data;
        if (!Array.isArray(items) || items.length > 50) {
          throw new Error('Invalid moderation conversation page');
        }
        const entries = items.map(raw => {
          const {conversation_id: id, purpose, group_id, title} = record(raw);
          if (!isUuid(id)) throw new Error('Invalid moderation conversation');
          return {id, purpose, group_id, title};
        });
        const next = validateAiConversationPage(entries.map(entry => entry.id), cursor, next_cursor);
        for (const {id, purpose, group_id, title} of entries) {
          if (purpose !== 'moderation' || group_id !== null || title !== scopedTitle(target)) continue;
          try {
            const entry = await readConversation(id, target, signal);
            latestSequences.set(id, entry.rows.at(-1)?.sequence ?? 0);
            messages.push(...visibleMessages(entry.rows));
            const before = entry.rows[0]?.sequence;
            if (entry.rows.length === 50 && before && before > 1) older.set(id, {before, forwardOnly: entry.forwardOnly});
          } catch (error) {
            if (!isMissingConversation(error)) throw error;
          }
        }
        after = next;
      } while (after);
      return assembleHistory(latestSequences, messages, older);
    },
    async older(previous: ModerationAdviceHistory, target: ModerationAdviceTarget, signal: AbortSignal): Promise<ModerationAdviceHistory> {
      const messages = [...previous.messages];
      const older = new Map<string, HistoryCursor>();
      const latestSequences = new Map(previous.latestSequences);
      for (const [id, {before, forwardOnly}] of previous.older) {
        try {
          const rows = forwardOnly ? await readForwardPage(id, target, signal, [], before) :
            await readPage(id, target, signal, {before_sequence: before});
          const first = rows[0]?.sequence;
          if (rows.length === 50 && first && first > 1) older.set(id, {before:first, forwardOnly});
          messages.push(...visibleMessages(rows));
        } catch (error) {
          if (!isMissingConversation(error)) throw error;
          latestSequences.delete(id);
        }
      }
      return assembleHistory(latestSequences, messages, older);
    },
    async create(target: ModerationAdviceTarget, signal: AbortSignal) {
      const title = scopedTitle(target);
      const data = record(await run(() => v2RequestData<unknown, {purpose: 'moderation'; title: string}>(base, {
        method: 'POST', body: {purpose: 'moderation', title}, signal,
      })));
      if (!isUuid(data.conversation_id) || data.purpose !== 'moderation' || data.group_id !== null || data.title !== title) {
        throw new Error('Invalid moderation conversation');
      }
      return data.conversation_id;
    },
    async generate(id: string, target: ModerationAdviceTarget, locale: 'zh' | 'en', sequence: number, signal: AbortSignal, skillId?: 'moderation-advice') {
      const result = record(await run(() => v2RequestData<unknown, {
        target_type: TargetType; target_id: number; locale: 'zh' | 'en'; expected_sequence: number; skill_id?: 'moderation-advice';
      }>(`${path(id)}/moderation-generate`, {
        method: 'POST', signal,
        body: {target_type: target.kind, target_id: target.id, locale, expected_sequence: sequence, ...(skillId ? {skill_id: skillId} : {})},
      })));
      if (result.status === 'insufficient_evidence' && result.message === null) return false;
      const receipt = record(result.message);
      if (result.status === 'generated' && isUuid(receipt.message_id) &&
          receipt.conversation_id === id && receipt.sequence_no === sequence + 1 && receipt.role === 'assistant') return true;
      throw new Error('Invalid moderation generation receipt');
    },
  };
}
