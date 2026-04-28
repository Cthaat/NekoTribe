<script setup lang="ts">
import { ref, onUnmounted } from 'vue';
import { Button } from '@/components/ui/button';
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle
} from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Badge } from '@/components/ui/badge';
import { ScrollArea } from '@/components/ui/scroll-area';

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

const connectionStatus =
  ref<ConnectionStatus>('disconnected');
const ws = ref<WebSocket | null>(null);
const messages = ref<WebSocketMessage[]>([]);
const messageText = ref('');
const roomId = ref('');
const roomMessage = ref('');
const broadcastMessage = ref('');

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
  const protocol =
    window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  const wsUrl = `${protocol}//${window.location.host}/_ws`;
  ws.value = new WebSocket(wsUrl);

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
  <div class="p-6 max-w-4xl mx-auto">
    <h1 class="text-3xl font-bold mb-6">
      {{ t('diagnostics.websocket.title') }}
    </h1>

    <Card class="mb-6">
      <CardHeader>
        <CardTitle>{{
          t('diagnostics.websocket.connectionStatus')
        }}</CardTitle>
      </CardHeader>
      <CardContent>
        <div class="flex items-center gap-4">
          <Badge
            :variant="
              connectionStatus === 'connected'
                ? 'default'
                : 'destructive'
            "
          >
            {{
              connectionStatus === 'connected'
                ? t('diagnostics.websocket.connected')
                : t('diagnostics.websocket.disconnected')
            }}
          </Badge>

          <Button
            @click="connectWebSocket"
            :disabled="connectionStatus === 'connected'"
            variant="outline"
          >
            {{ t('diagnostics.websocket.connect') }}
          </Button>

          <Button
            @click="disconnectWebSocket"
            :disabled="connectionStatus !== 'connected'"
            variant="destructive"
          >
            {{ t('diagnostics.websocket.disconnect') }}
          </Button>
        </div>
      </CardContent>
    </Card>

    <Card class="mb-6">
      <CardHeader>
        <CardTitle>{{
          t('diagnostics.websocket.sendMessageTitle')
        }}</CardTitle>
      </CardHeader>
      <CardContent class="space-y-4">
        <div class="flex gap-2">
          <Input
            v-model="messageText"
            :placeholder="
              t('diagnostics.websocket.messagePlaceholder')
            "
            @keyup.enter="sendMessage"
          />
          <Button
            @click="sendMessage"
            :disabled="connectionStatus !== 'connected'"
          >
            {{ t('diagnostics.websocket.send') }}
          </Button>
        </div>

        <div class="flex gap-2">
          <Button
            @click="sendPing"
            :disabled="connectionStatus !== 'connected'"
            variant="outline"
          >
            {{ t('diagnostics.websocket.sendPing') }}
          </Button>
        </div>

        <div class="flex gap-2 items-center">
          <Input
            v-model="roomId"
            :placeholder="
              t('diagnostics.websocket.roomIdPlaceholder')
            "
          />
          <Button
            @click="joinRoom"
            :disabled="
              connectionStatus !== 'connected' || !roomId
            "
            variant="outline"
          >
            {{ t('diagnostics.websocket.joinRoom') }}
          </Button>
          <Button
            @click="leaveRoom"
            :disabled="
              connectionStatus !== 'connected' || !roomId
            "
            variant="destructive"
          >
            {{ t('diagnostics.websocket.leaveRoom') }}
          </Button>
        </div>

        <div class="flex gap-2">
          <Input
            v-model="roomMessage"
            :placeholder="
              t('diagnostics.websocket.roomMessagePlaceholder')
            "
          />
          <Button
            @click="sendRoomMessage"
            :disabled="
              connectionStatus !== 'connected' || !roomId
            "
            variant="outline"
          >
            {{ t('diagnostics.websocket.sendToRoom') }}
          </Button>
        </div>

        <div class="flex gap-2">
          <Input
            v-model="broadcastMessage"
            :placeholder="
              t('diagnostics.websocket.broadcastPlaceholder')
            "
          />
          <Button
            @click="sendBroadcast"
            :disabled="connectionStatus !== 'connected'"
            variant="outline"
          >
            {{ t('diagnostics.websocket.broadcast') }}
          </Button>
        </div>
      </CardContent>
    </Card>

    <Card>
      <CardHeader>
        <CardTitle
          class="flex justify-between items-center"
        >
          {{ t('diagnostics.websocket.messageHistory') }}
          <Button
            @click="clearMessages"
            variant="secondary"
            size="sm"
          >
            {{ t('diagnostics.websocket.clearMessages') }}
          </Button>
        </CardTitle>
      </CardHeader>
      <CardContent>
        <ScrollArea class="h-64 w-full rounded border p-4">
          <div
            v-for="(msg, index) in messages"
            :key="index"
            class="mb-2 p-2 bg-gray-50 rounded text-sm"
          >
            <div class="text-xs text-gray-500">
              {{ formatTime(msg.timestamp) }}
            </div>
            <div class="font-medium">{{ msg.type }}</div>
            <div class="text-gray-700">
              {{ JSON.stringify(msg.data, null, 2) }}
            </div>
          </div>

          <div
            v-if="messages.length === 0"
            class="text-gray-500 text-center"
          >
            {{ t('diagnostics.websocket.emptyMessages') }}
          </div>
        </ScrollArea>
      </CardContent>
    </Card>
  </div>
</template>
