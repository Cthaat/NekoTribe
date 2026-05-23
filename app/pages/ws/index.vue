<script setup lang="ts">
import { computed, ref, onUnmounted } from 'vue';
import {
  Activity,
  AlertTriangle,
  Inbox,
  Link2,
  Loader2,
  PlugZap,
  Radio,
  Send,
  Trash2,
  Unplug,
  Users,
  Zap
} from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { ScrollArea } from '@/components/ui/scroll-area';
import { resolveRealtimeUrl } from '@/utils/apiBase';

type ConnectionStatus =
  | 'disconnected'
  | 'connecting'
  | 'connected'
  | 'error';

interface WebSocketMessage {
  type: string;
  data: unknown;
  timestamp: number;
}

const { t, locale } = useAppLocale();

const connectionStatus = ref<ConnectionStatus>('disconnected');
const ws = ref<WebSocket | null>(null);
const messages = ref<WebSocketMessage[]>([]);
const messageText = ref('');
const roomId = ref('');
const roomMessage = ref('');
const broadcastMessage = ref('');

const isConnected = computed(
  () => connectionStatus.value === 'connected'
);
const isConnecting = computed(
  () => connectionStatus.value === 'connecting'
);

const statusBadgeClass = computed(() => {
  switch (connectionStatus.value) {
    case 'connected':
      return 'border-emerald-200/60 bg-emerald-100/60 text-emerald-700 dark:border-emerald-900/40 dark:bg-emerald-950/40 dark:text-emerald-300';
    case 'connecting':
      return 'border-sky-200/60 bg-sky-100/60 text-sky-700 dark:border-sky-900/40 dark:bg-sky-950/40 dark:text-sky-300';
    case 'error':
      return 'border-rose-200/60 bg-rose-100/60 text-rose-700 dark:border-rose-900/40 dark:bg-rose-950/40 dark:text-rose-300';
    default:
      return 'border-border/60 bg-muted/40 text-muted-foreground';
  }
});

const statusLabel = computed(() => {
  switch (connectionStatus.value) {
    case 'connected':
      return t('diagnostics.websocket.connected');
    case 'connecting':
      return t('diagnostics.websocket.connecting') ||
        t('diagnostics.websocket.connected');
    case 'error':
      return t('diagnostics.websocket.error') ||
        t('diagnostics.websocket.disconnected');
    default:
      return t('diagnostics.websocket.disconnected');
  }
});

const messageTypeToneClass = (type: string): string => {
  if (type === 'system') {
    return 'border-sky-200/60 bg-sky-100/60 text-sky-700 dark:border-sky-900/40 dark:bg-sky-950/40 dark:text-sky-300';
  }
  if (type === 'error') {
    return 'border-rose-200/60 bg-rose-100/60 text-rose-700 dark:border-rose-900/40 dark:bg-rose-950/40 dark:text-rose-300';
  }
  if (type === 'broadcast') {
    return 'border-violet-200/60 bg-violet-100/60 text-violet-700 dark:border-violet-900/40 dark:bg-violet-950/40 dark:text-violet-300';
  }
  if (type === 'room_message' || type === 'join_room' || type === 'leave_room') {
    return 'border-amber-200/60 bg-amber-100/60 text-amber-700 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-300';
  }
  if (type === 'ping' || type === 'pong') {
    return 'border-emerald-200/60 bg-emerald-100/60 text-emerald-700 dark:border-emerald-900/40 dark:bg-emerald-950/40 dark:text-emerald-300';
  }
  return 'border-border/60 bg-muted/40 text-muted-foreground';
};

const addMessage = (message: WebSocketMessage): void => {
  messages.value.push(message);
  if (messages.value.length > 50) {
    messages.value.shift();
  }
};

const connectWebSocket = (): void => {
  if (!import.meta.client) {
    return;
  }

  connectionStatus.value = 'connecting';
  ws.value = new WebSocket(resolveRealtimeUrl());

  ws.value.onopen = () => {
    connectionStatus.value = 'connected';
    addMessage({
      type: 'system',
      data: {
        message: t('diagnostics.websocket.connectedMessage')
      },
      timestamp: Date.now()
    });
  };

  ws.value.onmessage = event => {
    try {
      const parsedMessage = JSON.parse(
        event.data
      ) as WebSocketMessage;
      addMessage(parsedMessage);
    } catch {
      addMessage({
        type: 'raw',
        data: { message: String(event.data) },
        timestamp: Date.now()
      });
    }
  };

  ws.value.onclose = () => {
    connectionStatus.value = 'disconnected';
    addMessage({
      type: 'system',
      data: {
        message: t('diagnostics.websocket.closedMessage')
      },
      timestamp: Date.now()
    });
  };

  ws.value.onerror = error => {
    connectionStatus.value = 'error';
    addMessage({
      type: 'error',
      data: {
        message: t('diagnostics.websocket.connectionError'),
        error: String(error)
      },
      timestamp: Date.now()
    });
  };
};

const disconnectWebSocket = (): void => {
  ws.value?.close();
  ws.value = null;
};

const sendMessage = (): void => {
  const message = messageText.value.trim();
  if (ws.value && message) {
    ws.value.send(message);
    messageText.value = '';
  }
};

const sendPing = (): void => {
  ws.value?.send(
    JSON.stringify({
      type: 'ping',
      data: {},
      timestamp: Date.now()
    })
  );
};

const joinRoom = (): void => {
  const targetRoomId = roomId.value.trim();
  if (ws.value && targetRoomId) {
    ws.value.send(
      JSON.stringify({
        type: 'join_room',
        data: { roomId: targetRoomId },
        timestamp: Date.now()
      })
    );
  }
};

const leaveRoom = (): void => {
  const targetRoomId = roomId.value.trim();
  if (ws.value && targetRoomId) {
    ws.value.send(
      JSON.stringify({
        type: 'leave_room',
        data: { roomId: targetRoomId },
        timestamp: Date.now()
      })
    );
  }
};

const sendRoomMessage = (): void => {
  const targetRoomId = roomId.value.trim();
  const message = roomMessage.value.trim();
  if (ws.value && targetRoomId && message) {
    ws.value.send(
      JSON.stringify({
        type: 'room_message',
        data: {
          roomId: targetRoomId,
          message
        },
        timestamp: Date.now()
      })
    );
    roomMessage.value = '';
  }
};

const sendBroadcast = (): void => {
  const message = broadcastMessage.value.trim();
  if (ws.value && message) {
    ws.value.send(
      JSON.stringify({
        type: 'broadcast',
        data: { message },
        timestamp: Date.now()
      })
    );
    broadcastMessage.value = '';
  }
};

const clearMessages = (): void => {
  messages.value = [];
};

const formatTime = (timestamp: number): string =>
  new Date(timestamp).toLocaleTimeString(locale.value);

onUnmounted(() => {
  disconnectWebSocket();
});
</script>

<template>
  <div class="mx-auto max-w-4xl space-y-6 p-4 sm:p-6">
    <header class="flex items-start gap-3">
      <span
        class="flex h-10 w-10 items-center justify-center rounded-lg bg-violet-500/10 text-violet-600 ring-1 ring-violet-200/60 dark:text-violet-400 dark:ring-violet-900/40"
      >
        <Activity class="h-5 w-5" />
      </span>
      <div class="min-w-0 flex-1">
        <h1 class="text-2xl font-semibold tracking-tight">
          {{ t('diagnostics.websocket.title') }}
        </h1>
        <p class="mt-1 text-sm text-muted-foreground">
          WebSocket diagnostics & live debugging
        </p>
      </div>
    </header>

    <section
      class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <div class="flex items-center justify-between gap-3">
        <div class="flex items-center gap-2">
          <span
            class="flex h-9 w-9 items-center justify-center rounded-md bg-sky-500/10 text-sky-600 dark:text-sky-400"
          >
            <Link2 class="h-4 w-4" />
          </span>
          <h2 class="text-sm font-semibold tracking-tight">
            {{ t('diagnostics.websocket.connectionStatus') }}
          </h2>
        </div>
        <span
          :class="[
            'inline-flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-[11px] font-medium',
            statusBadgeClass
          ]"
        >
          <Loader2
            v-if="isConnecting"
            class="h-3 w-3 animate-spin"
          />
          <span
            v-else
            :class="[
              'h-1.5 w-1.5 rounded-full',
              isConnected
                ? 'bg-emerald-500 animate-pulse'
                : connectionStatus === 'error'
                  ? 'bg-rose-500'
                  : 'bg-muted-foreground/60'
            ]"
          />
          {{ statusLabel }}
        </span>
      </div>

      <div class="flex flex-wrap items-center gap-2">
        <Button
          size="sm"
          class="h-9 rounded-md shadow-xs"
          :disabled="isConnected || isConnecting"
          @click="connectWebSocket"
        >
          <Loader2
            v-if="isConnecting"
            class="h-3.5 w-3.5 animate-spin"
          />
          <PlugZap v-else class="h-3.5 w-3.5" />
          {{ t('diagnostics.websocket.connect') }}
        </Button>
        <Button
          size="sm"
          variant="outline"
          class="h-9 rounded-md shadow-xs"
          :disabled="!isConnected"
          @click="disconnectWebSocket"
        >
          <Unplug class="h-3.5 w-3.5" />
          {{ t('diagnostics.websocket.disconnect') }}
        </Button>
      </div>
    </section>

    <section
      class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <div class="flex items-center gap-2">
        <span
          class="flex h-9 w-9 items-center justify-center rounded-md bg-emerald-500/10 text-emerald-600 dark:text-emerald-400"
        >
          <Send class="h-4 w-4" />
        </span>
        <h2 class="text-sm font-semibold tracking-tight">
          {{ t('diagnostics.websocket.sendMessageTitle') }}
        </h2>
      </div>

      <div class="grid gap-4">
        <div class="flex flex-col gap-2 sm:flex-row">
          <Input
            v-model="messageText"
            :placeholder="t('diagnostics.websocket.messagePlaceholder')"
            class="h-9 shadow-xs"
            @keyup.enter="sendMessage"
          />
          <Button
            size="sm"
            class="h-9 shrink-0 rounded-md shadow-xs"
            :disabled="!isConnected || !messageText.trim()"
            @click="sendMessage"
          >
            <Send class="h-3.5 w-3.5" />
            {{ t('diagnostics.websocket.send') }}
          </Button>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <Button
            size="sm"
            variant="outline"
            class="h-8 rounded-md shadow-xs"
            :disabled="!isConnected"
            @click="sendPing"
          >
            <Zap class="h-3.5 w-3.5" />
            {{ t('diagnostics.websocket.sendPing') }}
          </Button>
        </div>

        <div
          class="grid gap-3 rounded-lg border border-border/60 bg-muted/20 p-3"
        >
          <div class="flex items-center gap-2 text-xs font-medium text-muted-foreground">
            <Users class="h-3.5 w-3.5" />
            Room
          </div>
          <div class="flex flex-col gap-2 sm:flex-row sm:items-center">
            <Input
              v-model="roomId"
              :placeholder="t('diagnostics.websocket.roomIdPlaceholder')"
              class="h-9 shadow-xs"
            />
            <div class="flex gap-2">
              <Button
                size="sm"
                variant="outline"
                class="h-9 rounded-md shadow-xs"
                :disabled="!isConnected || !roomId.trim()"
                @click="joinRoom"
              >
                {{ t('diagnostics.websocket.joinRoom') }}
              </Button>
              <Button
                size="sm"
                variant="outline"
                class="h-9 rounded-md text-rose-600 shadow-xs hover:bg-rose-50 hover:text-rose-700 dark:text-rose-400 dark:hover:bg-rose-950/40"
                :disabled="!isConnected || !roomId.trim()"
                @click="leaveRoom"
              >
                {{ t('diagnostics.websocket.leaveRoom') }}
              </Button>
            </div>
          </div>
          <div class="flex flex-col gap-2 sm:flex-row">
            <Input
              v-model="roomMessage"
              :placeholder="t('diagnostics.websocket.roomMessagePlaceholder')"
              class="h-9 shadow-xs"
              @keyup.enter="sendRoomMessage"
            />
            <Button
              size="sm"
              class="h-9 shrink-0 rounded-md shadow-xs"
              :disabled="!isConnected || !roomId.trim() || !roomMessage.trim()"
              @click="sendRoomMessage"
            >
              <Send class="h-3.5 w-3.5" />
              {{ t('diagnostics.websocket.sendToRoom') }}
            </Button>
          </div>
        </div>

        <div
          class="grid gap-2 rounded-lg border border-border/60 bg-muted/20 p-3"
        >
          <div class="flex items-center gap-2 text-xs font-medium text-muted-foreground">
            <Radio class="h-3.5 w-3.5" />
            Broadcast
          </div>
          <div class="flex flex-col gap-2 sm:flex-row">
            <Input
              v-model="broadcastMessage"
              :placeholder="t('diagnostics.websocket.broadcastPlaceholder')"
              class="h-9 shadow-xs"
              @keyup.enter="sendBroadcast"
            />
            <Button
              size="sm"
              variant="outline"
              class="h-9 shrink-0 rounded-md shadow-xs"
              :disabled="!isConnected || !broadcastMessage.trim()"
              @click="sendBroadcast"
            >
              <Radio class="h-3.5 w-3.5" />
              {{ t('diagnostics.websocket.broadcast') }}
            </Button>
          </div>
        </div>
      </div>
    </section>

    <section
      class="grid gap-3 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <div class="flex items-center justify-between gap-3">
        <div class="flex items-center gap-2">
          <span
            class="flex h-9 w-9 items-center justify-center rounded-md bg-amber-500/10 text-amber-600 dark:text-amber-400"
          >
            <Inbox class="h-4 w-4" />
          </span>
          <h2 class="text-sm font-semibold tracking-tight">
            {{ t('diagnostics.websocket.messageHistory') }}
          </h2>
          <span
            class="ml-1 inline-flex items-center rounded-full border border-border/60 bg-muted/40 px-2 py-0.5 text-[10px] font-medium tabular-nums text-muted-foreground"
          >
            {{ messages.length }}
          </span>
        </div>
        <Button
          size="sm"
          variant="ghost"
          class="h-8 rounded-md text-muted-foreground hover:text-foreground"
          :disabled="messages.length === 0"
          @click="clearMessages"
        >
          <Trash2 class="h-3.5 w-3.5" />
          {{ t('diagnostics.websocket.clearMessages') }}
        </Button>
      </div>

      <ScrollArea
        class="h-72 w-full rounded-lg border border-border/60 bg-muted/10"
      >
        <div class="space-y-2 p-3">
          <div
            v-if="messages.length === 0"
            class="flex flex-col items-center gap-3 rounded-lg border border-dashed border-border/60 bg-muted/20 p-8 text-center text-sm text-muted-foreground"
          >
            <span
              class="flex h-12 w-12 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
            >
              <Inbox class="h-5 w-5" />
            </span>
            {{ t('diagnostics.websocket.emptyMessages') }}
          </div>
          <div
            v-for="(msg, index) in messages"
            :key="index"
            class="grid gap-1 rounded-lg border border-border/60 bg-card p-3 shadow-none"
          >
            <div class="flex items-center justify-between gap-2">
              <span
                :class="[
                  'inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[10px] font-medium uppercase tracking-wider',
                  messageTypeToneClass(msg.type)
                ]"
              >
                <AlertTriangle
                  v-if="msg.type === 'error'"
                  class="h-3 w-3"
                />
                {{ msg.type }}
              </span>
              <span class="text-[10px] tabular-nums text-muted-foreground">
                {{ formatTime(msg.timestamp) }}
              </span>
            </div>
            <pre
              class="overflow-x-auto whitespace-pre-wrap break-words rounded-md bg-muted/30 px-2 py-1.5 font-mono text-[11px] leading-relaxed text-foreground/80"
            >{{ JSON.stringify(msg.data, null, 2) }}</pre>
          </div>
        </div>
      </ScrollArea>
    </section>
  </div>
</template>
