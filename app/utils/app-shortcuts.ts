type ShortcutEvent = Pick<KeyboardEvent,
  'key' | 'altKey' | 'ctrlKey' | 'metaKey' | 'shiftKey' | 'isComposing' | 'defaultPrevented' | 'repeat'
>;

const timelineKeys = {
  j: 'next',
  k: 'previous',
  l: 'like',
  b: 'bookmark',
  r: 'reply',
  n: 'compose',
  '?': 'help'
} as const;

export function readAppShortcut(
  event: ShortcutEvent,
  context: { editable?: boolean; modalOpen?: boolean } = {}
) {
  if (event.defaultPrevented || event.isComposing || event.altKey || event.repeat) return null;
  const key = event.key.toLowerCase();
  if (!event.shiftKey && event.ctrlKey !== event.metaKey && key === 'k') return 'palette';
  if (event.ctrlKey || event.metaKey || context.editable || context.modalOpen) return null;
  if (event.shiftKey && key !== '?') return null;
  return Object.hasOwn(timelineKeys, key) ? timelineKeys[key as keyof typeof timelineKeys] : null;
}
