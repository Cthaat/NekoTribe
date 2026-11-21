export function validateAiConversationPage(
  ids: readonly unknown[],
  cursor: string | null,
  next: unknown,
): string | null {
  if (ids.length > 50) throw new Error('Invalid AI conversation page size');
  let lastId = cursor;
  for (const id of ids) {
    if (typeof id !== 'string' || !id || (lastId !== null && id <= lastId)) {
      throw new Error('Invalid AI conversation order');
    }
    lastId = id;
  }
  if (next === null) return null;
  if (!ids.length || typeof next !== 'string' || next !== lastId) {
    throw new Error('Invalid AI conversation cursor');
  }
  return next;
}
