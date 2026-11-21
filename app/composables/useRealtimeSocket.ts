import { useNuxtApp } from '#app';
import { computed, readonly, ref, watch } from 'vue';
import { authQueueFor } from '@/services/auth-request-queue';
import { usePreferenceStore } from '@/stores/user';
import { resolveRealtimeUrl } from '@/utils/apiBase';

export interface RealtimeMessage {
  type: string;
  data?: Record<string, unknown>;
  timestamp?: number;
}

type RemoteEvents = 'unknown' | 'connecting' | 'connected' | 'unavailable';
type RealtimeListener = (message: RealtimeMessage) => void;

declare global {
  interface Window {
    __NEKOTRIBE_DISABLE_REALTIME__?: boolean;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function decodeRemoteEvents(frame: Record<string, unknown>, userId: number): RemoteEvents | null {
  const {type, data, timestamp} = frame;
  if (Object.keys(frame).length !== 3 || type !== 'system_notification' ||
      typeof timestamp !== 'number' || !Number.isSafeInteger(timestamp) || timestamp < 0 ||
      !isRecord(data) || Object.keys(data).length !== 5 ||
      data.code !== 'realtime_status' || data.user_id !== userId ||
      typeof data.server_id !== 'string' || !data.server_id.trim() ||
      data.local_presence !== true) return null;
  const state = data.remote_events;
  return state === 'connecting' || state === 'connected' || state === 'unavailable' ? state : null;
}

function createRealtimeClient(app: ReturnType<typeof useNuxtApp>) {
  const preferences = usePreferenceStore();
  const queue = authQueueFor(app);
  const remoteEvents = ref<RemoteEvents>('unknown');
  const serverReady = computed(() => remoteEvents.value !== 'unknown');
  const recoveryRevision = ref(0);
  const ownerRevision = ref(0);
  const listeners = new Set<RealtimeListener>();
  let socket: WebSocket | null = null;
  let writeFrame: ((frame: string) => boolean) | undefined;
  let reconnect: ReturnType<typeof setTimeout> | undefined;
  let heartbeat: ReturnType<typeof setInterval> | undefined;
  let stopWatching: (() => void) | undefined;
  let stopObserving: (() => void) | undefined;
  let owner: { revision: number; userId: number; endpoint: string } | null = null;
  let needsRecovery = false;

  const userId = () => preferences.preferences.user.id;
  const endpoint = () => resolveRealtimeUrl({config: app.$config.public});
  function isCurrent(candidate: NonNullable<typeof owner>): boolean {
    return owner === candidate && !queue.isIdentityChanging && queue.revision === candidate.revision &&
      userId() === candidate.userId && endpoint() === candidate.endpoint;
  }

  function releaseSocket(): void {
    clearTimeout(reconnect);
    clearInterval(heartbeat);
    reconnect = heartbeat = undefined;
    const previous = socket;
    socket = null;
    writeFrame = undefined;
    if (previous) {
      previous.onopen = previous.onmessage = previous.onclose = previous.onerror = null;
      previous.close();
    }
    remoteEvents.value = 'unknown';
  }

  function invalidateOwner(): void {
    const hadOwner = owner !== null;
    owner = null;
    needsRecovery = false;
    releaseSocket();
    if (hadOwner) ownerRevision.value++;
  }

  function open(candidate: NonNullable<typeof owner>): void {
    if (!isCurrent(candidate) || socket) return;
    const retry = () => {
      if (!isCurrent(candidate) || reconnect !== undefined) return;
      const timer = setTimeout(() => {
        if (reconnect !== timer || !isCurrent(candidate)) return;
        reconnect = undefined;
        open(candidate);
      }, 3000);
      reconnect = timer;
    };
    let connection: WebSocket;
    try { connection = new WebSocket(candidate.endpoint); }
    catch { retry(); return; }
    socket = connection;
    const active = () => socket === connection && isCurrent(candidate);
    const onLost = () => {
      if (!active()) return;
      needsRecovery ||= remoteEvents.value !== 'unknown';
      releaseSocket();
      retry();
    };
    const write = (frame: string): boolean => {
      if (!active() || connection.readyState !== WebSocket.OPEN) return false;
      try {
        connection.send(frame);
        return true;
      } catch {
        onLost();
        return false;
      }
    };
    writeFrame = write;
    connection.onopen = () => {
      if (!active() || heartbeat !== undefined) return;
      const ping = () => write('{"type":"ping"}');
      heartbeat = setInterval(ping, 30000);
      ping();
    };
    connection.onclose = connection.onerror = onLost;
    connection.onmessage = event => {
      if (!active() || typeof event.data !== 'string') return;
      let frame: unknown;
      try { frame = JSON.parse(event.data); } catch { return; }
      if (!isRecord(frame) || typeof frame.type !== 'string') return;
      const data = isRecord(frame.data) ? frame.data : undefined;
      if (data?.code === 'realtime_status') {
        const state = decodeRemoteEvents(frame, candidate.userId);
        if (!state) return;
        if (state === 'unavailable' || (state === 'connecting' && remoteEvents.value === 'connected')) {
          needsRecovery = true;
        }
        remoteEvents.value = state;
        if (state === 'connected' && needsRecovery && active()) {
          needsRecovery = false;
          recoveryRevision.value++;
        }
        return;
      }
      const message = {type: frame.type, data, timestamp: typeof frame.timestamp === 'number' ? frame.timestamp : undefined};
      for (const listener of listeners) {
        if (!active()) return;
        try { listener(message); } catch { /* A consumer must not interrupt socket dispatch. */ }
      }
    };
  }

  function synchronize(): void {
    if (owner && isCurrent(owner)) return;
    invalidateOwner();
    const id = userId();
    if (!preferences.isLoggedIn || !Number.isSafeInteger(id) || id <= 0 || queue.isIdentityChanging) return;
    owner = {revision: queue.revision, userId: id, endpoint: endpoint()};
    open(owner);
    ownerRevision.value++;
  }

  function connect(): void {
    if (!import.meta.client || window.__NEKOTRIBE_DISABLE_REALTIME__ || stopWatching) return;
    const unsubscribe = queue.subscribe(() => {
      if (owner && !isCurrent(owner)) invalidateOwner();
      // Store updates such as clearAuthState finish in the same turn.
      queueMicrotask(() => { if (stopObserving === unsubscribe) synchronize(); });
    });
    stopObserving = unsubscribe;
    stopWatching = watch([userId, endpoint], synchronize, {flush: 'sync'});
    synchronize();
  }

  function disconnect(): void {
    stopWatching?.();
    stopObserving?.();
    stopWatching = stopObserving = undefined;
    invalidateOwner();
  }

  function subscribe(listener: RealtimeListener): () => void {
    listeners.add(listener);
    connect();
    return () => { listeners.delete(listener); };
  }

  function send(payload: Record<string, unknown>): boolean {
    if (!serverReady.value || !writeFrame) return false;
    try {
      return writeFrame(JSON.stringify(payload));
    } catch {
      return false;
    }
  }

  return {
    connect, disconnect, subscribe, send, serverReady,
    remoteEvents: readonly(remoteEvents),
    recoveryRevision: readonly(recoveryRevision),
    ownerRevision: readonly(ownerRevision)
  };
}

const clients = new WeakMap<object, ReturnType<typeof createRealtimeClient>>();

export function useRealtimeSocket() {
  const app = useNuxtApp();
  let client = clients.get(app);
  if (!client) {
    client = createRealtimeClient(app);
    clients.set(app, client);
  }
  return client;
}
