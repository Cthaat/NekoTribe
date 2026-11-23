import policy from '../../specifications/requirements/chat-realtime-details.json';

export const typingMinIntervalMs = policy.typing_min_interval_ms;
export const typingTtlMs = policy.typing_ttl_ms;

export type TypingEvent = 'typing_start' | 'typing_stop';
type TypingScope = { conversation_id: number } | { channel_id: number };
type TypingData = TypingScope & { user_id: number };
type ReadData = { conversation_id: number; reader_id: number; last_read_message_id: number };

const record = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);
const id = (value: unknown): value is number => typeof value === 'number' && Number.isSafeInteger(value) && value > 0;

export const isTypingEvent = (type: unknown): type is TypingEvent => type === 'typing_start' || type === 'typing_stop';

function typingScope(data: Record<string, unknown>): TypingScope | null {
  if (id(data.conversation_id) && data.channel_id === undefined) return { conversation_id: data.conversation_id };
  if (id(data.channel_id) && data.conversation_id === undefined) return { channel_id: data.channel_id };
  return null;
}

export function typingInput(data: unknown): TypingScope | null {
  return record(data) && Object.keys(data).length === 1 ? typingScope(data) : null;
}

function eventFields(data: Record<string, unknown>, fields: string[]): boolean {
  return Object.keys(data).every(key => key === 'server_id' || fields.includes(key)) &&
    (data.server_id === undefined || typeof data.server_id === 'string' && data.server_id.length > 0);
}

export function parseChatRealtimeDetail(type: unknown, data: unknown): { typing: TypingData } | { read: ReadData } | null | undefined {
  if (isTypingEvent(type)) {
    if (!record(data) || !id(data.user_id) || !eventFields(data, ['conversation_id', 'channel_id', 'user_id'])) return null;
    const scope = typingScope(data);
    return scope && { typing: { ...scope, user_id: data.user_id } };
  }
  if (type === 'direct_read_updated') {
    if (!record(data) || !eventFields(data, ['conversation_id', 'reader_id', 'last_read_message_id']) ||
        !id(data.conversation_id) || !id(data.reader_id) || !id(data.last_read_message_id)) return null;
    return { read: { conversation_id: data.conversation_id, reader_id: data.reader_id, last_read_message_id: data.last_read_message_id } };
  }
  return undefined;
}
