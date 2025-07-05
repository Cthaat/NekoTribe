<template>
  <Card class="w-[480px] mx-auto mt-10 shadow-lg">
    <CardHeader>
      <CardTitle class="flex items-center gap-2">
        Vue WebSocket 测试
        <Badge :variant="connectionStatus.variant">{{ connectionStatus.text }}</Badge>
      </CardTitle>
      <CardDescription>使用 shadcn-vue 组件连接到 Nitro WebSocket 服务器</CardDescription>
    </CardHeader>
    <CardContent class="grid gap-6">
      <!-- 消息显示区域 -->
      <ScrollArea class="h-[250px] w-full rounded-md border p-4 bg-muted/50">
        <div v-if="receivedMessages.length === 0" class="text-sm text-muted-foreground">
          连接成功后，这里会显示消息...
        </div>
        <div v-for="(msg, index) in receivedMessages" :key="index" class="text-sm mb-2">
          <span :class="getMessageClass(msg)">{{ msg.text }}</span>
        </div>
      </ScrollArea>

      <!-- 消息发送区域 -->
      <div class="flex w-full items-center space-x-2">
        <Input id="message" v-model="message" placeholder="输入 'ping' 或其他内容..." :disabled="!isConnected"
          @keyup.enter="sendMessage" />
        <Button @click="sendMessage" :disabled="!isConnected">
          发送
        </Button>
      </div>
    </CardContent>
    <CardFooter>
      <p class="text-xs text-muted-foreground">
        在组件卸载时会自动断开连接。
      </p>
    </CardFooter>
  </Card>
</template>

<script setup lang="ts">
import { ref, onMounted, onUnmounted, computed } from 'vue'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { ScrollArea } from '@/components/ui/scroll-area'

// 定义消息对象的类型
interface Message {
  type: 'system' | 'sent' | 'received';
  text: string;
}

// 响应式状态
const message = ref('')
const receivedMessages = ref<Message[]>([])
const isConnected = ref(false)
let socket: WebSocket | null = null

// 计算连接状态，用于 Badge 组件
const connectionStatus = computed(() => {
  if (isConnected.value) {
    return { text: '已连接', variant: 'default' as const };
  }
  return { text: '已断开', variant: 'destructive' as const };
})

// 根据消息类型返回不同的 CSS 类
const getMessageClass = (msg: Message) => {
  switch (msg.type) {
    case 'system': return 'text-muted-foreground italic';
    case 'sent': return 'text-blue-600';
    case 'received': return 'text-green-700';
    default: return '';
  }
}

// 组件挂载时执行
onMounted(() => {
  const wsUrl = `ws://${window.location.host}/_ws`

  receivedMessages.value.push({ type: 'system', text: `正在连接到 ${wsUrl}...` })
  socket = new WebSocket(wsUrl)

  socket.onopen = () => {
    isConnected.value = true
    receivedMessages.value.push({ type: 'system', text: '✅ WebSocket 连接成功！' })
  }

  socket.onmessage = (event) => {
    receivedMessages.value.push({ type: 'received', text: `[服务器]: ${event.data}` })
  }

  socket.onclose = () => {
    isConnected.value = false
    if (receivedMessages.value.at(-1)?.text !== '❌ WebSocket 连接已关闭。') {
      receivedMessages.value.push({ type: 'system', text: '❌ WebSocket 连接已关闭。' })
    }
  }

  socket.onerror = (error) => {
    console.error('WebSocket Error:', error)
    receivedMessages.value.push({ type: 'system', text: `[错误]: ${error.type}` })
  }
})

// 组件卸载时执行
onUnmounted(() => {
  if (socket) {
    receivedMessages.value.push({ type: 'system', text: '❌ WebSocket 连接已关闭。' })
    socket.close()
  }
})

// 发送消息的方法
const sendMessage = () => {
  if (socket && isConnected.value && message.value) {
    socket.send(message.value)
    receivedMessages.value.push({ type: 'sent', text: `[我]: ${message.value}` })
    message.value = ''
  }
}
</script>

<style scoped>
/* 可选：为不同来源的消息添加一些样式 */
.text-blue-600 {
  color: #2563eb;
}

.text-green-700 {
  color: #15803d;
}
</style>