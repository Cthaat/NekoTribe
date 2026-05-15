import { usePreferenceStore } from '@/stores/user';

export interface RealtimeMessage {
  type: string;
  data?: Record<string, unknown>;
  timestamp?: number;
}

type RealtimeListener = (message: RealtimeMessage) => void;

let socket: WebSocket | null = null;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let heartbeatTimer: ReturnType<typeof setInterval> | null = null;
let shouldReconnect = true;

const listeners = new Set<RealtimeListener>();

function browserRealtimeUrl(): string {
  const protocol =
    window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${protocol}//${window.location.host}/_ws`;
}

function browserReachableHostname(): string {
  const hostname = window.location.hostname;
  if (
    !hostname ||
    hostname === '0.0.0.0' ||
    hostname === '::' ||
    hostname === '[::]'
  ) {
    return 'localhost';
  }
  return hostname;
}

function normalizeConfiguredRealtimeUrl(
  configured: string
): string | null {
  if (!configured || configured.includes('localhost:3000')) {
    return null;
  }

  try {
    const url = new URL(configured, window.location.origin);
    if (url.protocol === 'http:') url.protocol = 'ws:';
    if (url.protocol === 'https:') url.protocol = 'wss:';

    if (
      url.hostname === '0.0.0.0' ||
      url.hostname === '::' ||
      url.hostname === '[::]'
    ) {
      url.hostname = browserReachableHostname();
    }

    return url.toString();
  } catch {
    return null;
  }
}

function resolveRealtimeUrl(): string {
  const config = useRuntimeConfig();
  const configured = String(config.public.wsUrl || '').trim();
  return (
    normalizeConfiguredRealtimeUrl(configured) ||
    browserRealtimeUrl()
  );
}

function emitRealtimeMessage(message: RealtimeMessage): void {
  for (const listener of listeners) {
    listener(message);
  }
}

function stopHeartbeat(): void {
  if (heartbeatTimer) {
    clearInterval(heartbeatTimer);
    heartbeatTimer = null;
  }
}

function sendHeartbeat(): void {
  if (socket?.readyState !== WebSocket.OPEN) return;
  socket.send(JSON.stringify({ type: 'ping' }));
}

function startHeartbeat(): void {
  stopHeartbeat();
  sendHeartbeat();
  heartbeatTimer = setInterval(sendHeartbeat, 30000);
}

function scheduleReconnect(): void {
  if (!shouldReconnect || reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectRealtimeSocket();
  }, 3000);
}

export function connectRealtimeSocket(): void {
  if (!import.meta.client || socket) return;

  const preferenceStore = usePreferenceStore();
  if (!preferenceStore.isLoggedIn) return;

  shouldReconnect = true;
  socket = new WebSocket(resolveRealtimeUrl());
  socket.onopen = () => {
    startHeartbeat();
  };
  socket.onmessage = event => {
    try {
      emitRealtimeMessage(
        JSON.parse(event.data) as RealtimeMessage
      );
    } catch {
      // Ignore malformed diagnostics from old websocket tools.
    }
  };
  socket.onclose = () => {
    socket = null;
    stopHeartbeat();
    if (usePreferenceStore().isLoggedIn) {
      scheduleReconnect();
    }
  };
  socket.onerror = () => {
    socket?.close();
  };
}

export function disconnectRealtimeSocket(): void {
  shouldReconnect = false;
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
  stopHeartbeat();
  socket?.close();
  socket = null;
}

export function useRealtimeSocket() {
  function subscribe(listener: RealtimeListener): () => void {
    listeners.add(listener);
    connectRealtimeSocket();
    return () => {
      listeners.delete(listener);
    };
  }

  return {
    connect: connectRealtimeSocket,
    disconnect: disconnectRealtimeSocket,
    subscribe
  };
}
