export type RemoteRealtimeState = 'connecting' | 'connected' | 'unavailable';

export interface RealtimeTransport {
  connect(onMessage: (channel: string, raw: string) => void, onLost: () => void): Promise<void>;
  subscribe(channels: string[]): Promise<void>;
  unsubscribe(channels: string[]): Promise<void>;
  close(): void;
}
export interface RealtimeSubscription {
  close(): void;
  joinChat(channelId: number): boolean;
  leaveChat(channelId: number): void;
}
export interface RealtimeSubscriptionOptions {
  userId: number;
  serverId: string;
  createTransport: () => RealtimeTransport;
  onState: (state: RemoteRealtimeState) => void;
  onMessage: (raw: string) => void;
  onChatReady?: (channelId: number) => void;
}

const notifications = new Set([
  'notification_created', 'notification_read_status_updated',
  'notifications_read_status_updated', 'notification_deleted', 'notification_restored'
]);
const chatEvents = new Set([
  'chat_message', 'chat_message_updated', 'chat_message_deleted',
  'chat_reaction_updated', 'chat_channel_updated', 'room_message'
]);
const chatPrefix = 'ws:chat:channel:';
export const MAX_REALTIME_CHAT_CHANNELS = 64;
const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);
const positiveId = (value: unknown): value is number =>
  typeof value === 'number' && Number.isSafeInteger(value) && value > 0;

/** Validate broker input without rewriting valid private notification JSON. */
export function allowRealtimeFrame(
  channel: string, raw: string, userId: number, serverId: string
): boolean {
  if (typeof raw !== 'string' || new TextEncoder().encode(raw).byteLength > 262144) return false;
  let event: unknown;
  try { event = JSON.parse(raw) as unknown; } catch { return false; }
  if (!isRecord(event) || typeof event.type !== 'string' || !isRecord(event.data) ||
      !Number.isSafeInteger(event.timestamp) || (event.timestamp as number) < 0) return false;
  if (event.type === 'system_notification' &&
      (event.data.code === 'realtime_status' || event.data.code === 'chat_channel_ready')) return false;
  if (channel === 'ws:presence') {
    const data = event.data;
    return event.type === 'presence_update' && Object.keys(event).length === 3 &&
      Object.keys(data).length === 4 && positiveId(data.user_id) &&
      typeof data.server_id === 'string' && data.server_id.length > 0 && data.server_id !== serverId &&
      ((data.online_status === 'hidden' && data.last_seen_at === null) ||
       ((data.online_status === 'online' || data.online_status === 'offline') &&
        (data.last_seen_at === null || typeof data.last_seen_at === 'string')));
  }
  if (channel === 'ws:user:' + userId) {
    if (notifications.has(event.type)) return true;
    if (event.type === 'direct_message_deleted') {
      return positiveId(event.data.conversation_id) && positiveId(event.data.message_id) &&
        (event.data.server_id === undefined || typeof event.data.server_id === 'string' && event.data.server_id.length > 0) &&
        Object.keys(event.data).every(key => ['conversation_id', 'message_id', 'server_id'].includes(key));
    }
    const message = event.data.direct_message;
    return event.type === 'direct_message' && positiveId(event.data.conversation_id) &&
      isRecord(message) && message.conversation_id === event.data.conversation_id &&
      positiveId(message.message_id);
  }
  if (channel === 'ws:broadcast') return event.type === 'broadcast';
  if (channel === 'ws:system') return event.type === 'system_notification';
  if (channel.startsWith(chatPrefix)) {
    const channelId = Number(channel.slice(chatPrefix.length));
    return positiveId(channelId) && channel === chatPrefix + channelId &&
      chatEvents.has(event.type) &&
      event.data.channel_id === channelId &&
      (event.room == null || event.room === 'chat:channel:' + channelId);
  }
  return false;
}

function bounded<T>(operation: () => Promise<T>, signal: AbortSignal): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const finish = (error: boolean, value?: T) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      signal.removeEventListener('abort', cancel);
      if (error) reject(new Error('Realtime subscription unavailable'));
      else resolve(value as T);
    };
    const cancel = () => finish(true);
    if (signal.aborted) { finish(true); return; }
    signal.addEventListener('abort', cancel, {once: true});
    timer = setTimeout(cancel, 1500);
    timer.unref?.();
    void Promise.resolve().then(() => {
      if (signal.aborted) throw new Error('Realtime subscription unavailable');
      return operation();
    }).then(
      value => finish(false, value), () => finish(true)
    );
  });
}

interface Attempt {
  transport: RealtimeTransport;
  abort: AbortController;
  connected: boolean;
  syncing: boolean;
  acknowledged: Set<string>;
  early: Array<{channel: string; raw: string}>;
}

/** Connection-owned state: one attempt, bounded channel set and one retry timer. */
export function createRealtimeSubscription(options: RealtimeSubscriptionOptions): RealtimeSubscription {
  if (!positiveId(options.userId) || typeof options.serverId !== 'string' || !options.serverId) {
    throw new Error('Invalid realtime subscription');
  }
  const wanted = new Set(['ws:user:' + options.userId, 'ws:presence', 'ws:broadcast', 'ws:system']);
  let current: Attempt | undefined;
  let retry: ReturnType<typeof setTimeout> | undefined;
  let stopped = false;
  let last: RemoteRealtimeState | undefined;
  const active = (attempt: Attempt) => !stopped && current === attempt && !attempt.abort.signal.aborted;

  function dispose(attempt: Attempt): void {
    attempt.abort.abort();
    attempt.early.length = 0;
    try { attempt.transport.close(); } catch { /* Already closed. */ }
  }
  function close(): void {
    if (stopped) return;
    stopped = true;
    if (retry) clearTimeout(retry);
    retry = undefined;
    const previous = current;
    current = undefined;
    wanted.clear();
    if (previous) dispose(previous);
  }
  function state(value: RemoteRealtimeState): void {
    if (stopped || value === last) return;
    last = value;
    try { options.onState(value); } catch { close(); }
  }
  function scheduleRetry(): void {
    if (stopped || retry) return;
    retry = setTimeout(() => { retry = undefined; begin(); }, 1000);
    retry.unref?.();
  }
  function failed(attempt: Attempt): void {
    if (!active(attempt)) return;
    current = undefined;
    dispose(attempt);
    state('unavailable');
    scheduleRetry();
  }
  function deliver(attempt: Attempt, raw: string): void {
    if (!active(attempt)) return;
    try { options.onMessage(raw); } catch { close(); }
  }
  function received(attempt: Attempt, channel: string, raw: string): void {
    if (!active(attempt) || !wanted.has(channel) ||
        !allowRealtimeFrame(channel, raw, options.userId, options.serverId)) return;
    if (attempt.acknowledged.has(channel)) { deliver(attempt, raw); return; }
    if (attempt.early.length >= 16) { failed(attempt); return; }
    attempt.early.push({channel, raw});
  }
  async function synchronize(attempt: Attempt): Promise<void> {
    if (!active(attempt) || !attempt.connected || attempt.syncing) return;
    attempt.syncing = true;
    try {
      while (active(attempt)) {
        const removed = [...attempt.acknowledged].filter(channel => !wanted.has(channel));
        if (removed.length) {
          state('connecting');
          await bounded(() => attempt.transport.unsubscribe(removed), attempt.abort.signal);
          if (!active(attempt)) return;
          removed.forEach(channel => attempt.acknowledged.delete(channel));
          continue;
        }
        const added = [...wanted].filter(channel => !attempt.acknowledged.has(channel));
        if (added.length) {
          state('connecting');
          await bounded(() => attempt.transport.subscribe(added), attempt.abort.signal);
          if (!active(attempt)) return;
          for (const channel of added) {
            attempt.acknowledged.add(channel);
            if (channel.startsWith(chatPrefix) && wanted.has(channel)) {
              options.onChatReady?.(Number(channel.slice(chatPrefix.length)));
            }
          }
          continue;
        }
        state('connected');
        const early = attempt.early.splice(0);
        for (const item of early) {
          if (wanted.has(item.channel) && attempt.acknowledged.has(item.channel)) deliver(attempt, item.raw);
        }
        return;
      }
    } catch { failed(attempt); }
    finally {
      attempt.syncing = false;
      if (active(attempt) && (
        [...wanted].some(channel => !attempt.acknowledged.has(channel)) ||
        [...attempt.acknowledged].some(channel => !wanted.has(channel))
      )) queueMicrotask(() => { void synchronize(attempt); });
    }
  }
  function begin(): void {
    if (stopped || current) return;
    let transport: RealtimeTransport;
    try { transport = options.createTransport(); }
    catch { state('unavailable'); scheduleRetry(); return; }
    const attempt: Attempt = {
      transport, abort: new AbortController(), connected: false, syncing: false,
      acknowledged: new Set(), early: []
    };
    current = attempt;
    void bounded(() => transport.connect(
      (channel, raw) => received(attempt, channel, raw),
      () => failed(attempt)
    ), attempt.abort.signal).then(async () => {
      if (!active(attempt)) return;
      attempt.connected = true;
      await synchronize(attempt);
    }).catch(() => failed(attempt));
  }
  state('connecting');
  queueMicrotask(begin);
  return {
    close,
    joinChat(channelId) {
      if (stopped || !positiveId(channelId)) return false;
      const channel = chatPrefix + channelId;
      if (wanted.has(channel)) return true;
      if (wanted.size >= 4 + MAX_REALTIME_CHAT_CHANNELS) return false;
      wanted.add(channel);
      if (current) void synchronize(current);
      return true;
    },
    leaveChat(channelId) {
      if (stopped || !positiveId(channelId)) return;
      wanted.delete(chatPrefix + channelId);
      if (current) void synchronize(current);
    }
  };
}
