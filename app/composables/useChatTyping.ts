import { onBeforeUnmount, ref, watch } from 'vue';
import settings from '../../specifications/requirements/chat-realtime-details.json';
import type { RealtimeMessage } from './useRealtimeSocket';

export function useChatTyping(
  scope: 'channel_id' | 'conversation_id',
  scopeId: () => number | null | undefined,
  userId: () => number,
  send: (event: Record<string, unknown>) => boolean,
) {
  const typingCount = ref(0);
  const senders = new Map<number, { at: number; typing: boolean }>();
  let local: { scope: number; at: number } | null = null;
  let idleTimer: ReturnType<typeof setTimeout> | undefined;
  let expiryTimer: ReturnType<typeof setTimeout> | undefined;

  function stop() {
    clearTimeout(idleTimer);
    if (local) send({ type: 'typing_stop', data: { [scope]: local.scope } });
    local = null;
  }

  function edit(active: boolean) {
    const id = scopeId();
    if (!active || !id) { stop(); return; }
    const now = Date.now();
    if ((!local || now - local.at >= settings.typing_min_interval_ms) &&
        send({ type: 'typing_start', data: { [scope]: id } })) local = { scope: id, at: now };
    clearTimeout(idleTimer);
    idleTimer = setTimeout(stop, 1800);
  }

  function updateCount() {
    clearTimeout(expiryTimer);
    const now = Date.now();
    let expires = Infinity;
    let count = 0;
    for (const [sender, activity] of senders) {
      const expiry = activity.at + settings.typing_ttl_ms;
      if (expiry <= now) { senders.delete(sender); continue; }
      if (activity.typing) count++;
      expires = Math.min(expires, expiry);
    }
    typingCount.value = count;
    if (Number.isFinite(expires)) expiryTimer = setTimeout(updateCount, expires - now);
  }

  function receive(event: RealtimeMessage) {
    const { data, timestamp: at } = event;
    const sender = data?.user_id;
    if ((event.type !== 'typing_start' && event.type !== 'typing_stop') || !scopeId() ||
        data?.[scope] !== scopeId() || typeof sender !== 'number' || !Number.isSafeInteger(sender) || sender <= 0 ||
        sender === userId() || typeof at !== 'number' || at <= (senders.get(sender)?.at ?? 0)) return;
    senders.set(sender, { at: Math.min(at, Date.now()), typing: event.type === 'typing_start' });
    updateCount();
  }

  function reset(announce: boolean) {
    if (announce) stop();
    else { clearTimeout(idleTimer); local = null; }
    senders.clear();
    updateCount();
  }

  watch(scopeId, () => reset(true), { flush: 'sync' });
  watch(userId, () => reset(false), { flush: 'sync' });
  onBeforeUnmount(() => reset(true));
  return { edit, receive, stop, reset, typingCount };
}
