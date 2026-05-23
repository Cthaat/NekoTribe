import { usePreferenceStore } from '@/stores/user';
import { resolveRealtimeUrl } from '@/utils/apiBase';

export interface RealtimeMessage {
  type: string;
  data?: Record<string, unknown>;
  timestamp?: number;
}

type RealtimeListener = (message: RealtimeMessage) => void;

declare global {
  interface Window {
    __NEKOTRIBE_DISABLE_REALTIME__?: boolean;
  }
}

let socket: WebSocket | null = null;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let heartbeatTimer: ReturnType<typeof setInterval> | null = null;
let shouldReconnect = true;

const listeners = new Set<RealtimeListener>();

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
  if (window.__NEKOTRIBE_DISABLE_REALTIME__) return;

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
