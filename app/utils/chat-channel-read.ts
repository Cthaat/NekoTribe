export function displayedChatCursor(messages: readonly { id: number }[]): number {
  return messages.reduce((cursor, { id }) => Number.isSafeInteger(id) && id > cursor ? id : cursor, 0);
}

export function confirmedChatUnread(channel: number, cursor: number, receipt: unknown): number | null {
  if (!receipt || typeof receipt !== 'object') return null;
  const { channel_id, last_read_message_id, unread_count } = receipt as Record<string, unknown>;
  if (channel_id !== channel || typeof last_read_message_id !== 'number' ||
      !Number.isSafeInteger(last_read_message_id) || last_read_message_id < cursor ||
      typeof unread_count !== 'number' || !Number.isSafeInteger(unread_count) || unread_count < 0) return null;
  return unread_count;
}
