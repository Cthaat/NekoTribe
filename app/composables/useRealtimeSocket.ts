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

function normalizedHostname(hostname: string): string {
  return hostname.trim().replace(/^\[|\]$/g, '').toLowerCase();
}

function isLocalOnlyHostname(hostname: string): boolean {
  const normalized = normalizedHostname(hostname);
  return (
    !normalized ||
    normalized === 'localhost' ||
    normalized === '0.0.0.0' ||
    normalized === '::' ||
    normalized === '::1' ||
    normalized.startsWith('127.')
  );
}

function browserRealtimeUrl(): string {
  const protocol =
    window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${protocol}//${window.location.host}/_ws`;
}

function browserReachableHostname(): string {
  const hostname = window.location.hostname;
  if (isLocalOnlyHostname(hostname)) {
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

    const configuredHostIsLocal = isLocalOnlyHostname(
      url.hostname
    );
    const browserHostIsLocal = isLocalOnlyHostname(
      window.location.hostname
    );

    if (configuredHostIsLocal && !browserHostIsLocal) {
      return null;
    }

    if (
      ['0.0.0.0', '::', '[::]'].includes(url.hostname)
    ) {
      url.hostname = browserReachableHostname();
    }

    if (
      window.location.protocol === 'https:' &&
      url.protocol === 'ws:'
    ) {
      url.protocol = 'wss:';
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
