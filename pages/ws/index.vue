<!--
  WebSocket 测试页面
  =====================================================
  这是一个完整的 WebSocket 客户端测试界面，提供以下功能：
  
  1. WebSocket 连接管理（连接/断开）
  2. 实时消息发送和接收
  3. 房间功能（加入/离开房间，房间内聊天）
  4. 广播功能（向所有用户发送消息）
  5. 心跳检测（ping/pong）
  6. 消息历史记录显示
  7. 实时连接状态显示
  
  技术栈：
  - Vue 3 Composition API
  - TypeScript
  - WebSocket API
  - shadcn/ui 组件库
  - Tailwind CSS
-->

<template>
  <div class="p-6 max-w-4xl mx-auto">
    <!-- 页面标题 -->
    <h1 class="text-3xl font-bold mb-6">WebSocket 测试页面</h1>

    <!-- ===== 连接状态卡片 ===== -->
    <!-- 显示当前 WebSocket 连接状态和连接控制按钮 -->
    <Card class="mb-6">
      <CardHeader>
        <CardTitle>连接状态</CardTitle>
      </CardHeader>
      <CardContent>
        <div class="flex items-center gap-4">
          <!-- 连接状态徽章 - 根据连接状态动态显示不同颜色 -->
          <Badge :variant="connectionStatus === 'connected' ? 'default' : 'destructive'">
            {{ connectionStatus === 'connected' ? '已连接' : '未连接' }}
          </Badge>

          <!-- 连接按钮 - 只有在未连接状态下才可用 -->
          <Button @click="connectWebSocket" :disabled="connectionStatus === 'connected'" variant="outline">
            连接 WebSocket
          </Button>

          <!-- 断开连接按钮 - 只有在已连接状态下才可用 -->
          <Button @click="disconnectWebSocket" :disabled="connectionStatus !== 'connected'" variant="destructive">
            断开连接
          </Button>
        </div>
      </CardContent>
    </Card>

    <!-- ===== 消息发送区域 ===== -->
    <!-- 提供各种类型的消息发送功能 -->
    <Card class="mb-6">
      <CardHeader>
        <CardTitle>发送消息</CardTitle>
      </CardHeader>
      <CardContent class="space-y-4">

        <!-- 普通消息发送 -->
        <div class="flex gap-2">
          <!-- 消息输入框 - 支持回车键发送 -->
          <Input v-model="messageText" placeholder="输入消息..." @keyup.enter="sendMessage" />
          <!-- 发送按钮 - 只有在连接状态下才可用 -->
          <Button @click="sendMessage" :disabled="connectionStatus !== 'connected'">
            发送
          </Button>
        </div>

        <!-- 心跳检测 -->
        <div class="flex gap-2">
          <!-- Ping 按钮 - 用于测试连接是否正常 -->
          <Button @click="sendPing" :disabled="connectionStatus !== 'connected'" variant="outline">
            发送 Ping
          </Button>
        </div>

        <!-- ===== 房间操作区域 ===== -->
        <div class="flex gap-2 items-center">
          <!-- 房间ID输入框 -->
          <Input v-model="roomId" placeholder="房间ID" />

          <!-- 加入房间按钮 - 需要连接状态且输入房间ID -->
          <Button @click="joinRoom" :disabled="connectionStatus !== 'connected' || !roomId" variant="outline">
            加入房间
          </Button>

          <!-- 离开房间按钮 -->
          <Button @click="leaveRoom" :disabled="connectionStatus !== 'connected' || !roomId" variant="destructive">
            离开房间
          </Button>
        </div>

        <!-- ===== 房间消息发送 ===== -->
        <div class="flex gap-2">
          <!-- 房间消息输入框 -->
          <Input v-model="roomMessage" placeholder="房间消息..." />

          <!-- 发送到房间按钮 - 需要连接状态且已加入房间 -->
          <Button @click="sendRoomMessage" :disabled="connectionStatus !== 'connected' || !roomId" variant="outline">
            发送到房间
          </Button>
        </div>

        <!-- ===== 广播消息发送 ===== -->
        <div class="flex gap-2">
          <!-- 广播消息输入框 -->
          <Input v-model="broadcastMessage" placeholder="广播消息..." />

          <!-- 广播按钮 - 向所有连接的用户发送消息 -->
          <Button @click="sendBroadcast" :disabled="connectionStatus !== 'connected'" variant="outline">
            广播消息
          </Button>
        </div>
      </CardContent>
    </Card>

    <!-- ===== 消息历史区域 ===== -->
    <!-- 显示所有收到和发送的消息 -->
    <Card>
      <CardHeader>
        <CardTitle class="flex justify-between items-center">
          消息历史
          <!-- 清空消息按钮 -->
          <Button @click="clearMessages" variant="secondary" size="sm">
            清空消息
          </Button>
        </CardTitle>
      </CardHeader>
      <CardContent>
        <!-- 可滚动的消息显示区域 -->
        <ScrollArea class="h-64 w-full rounded border p-4">
          <!-- 遍历显示每条消息 -->
          <div v-for="(msg, index) in messages" :key="index" class="mb-2 p-2 bg-gray-50 rounded text-sm">
            <!-- 消息时间戳 -->
            <div class="text-xs text-gray-500">{{ formatTime(msg.timestamp) }}</div>
            <!-- 消息类型 -->
            <div class="font-medium">{{ msg.type }}</div>
            <!-- 消息内容 - 格式化显示 JSON 数据 -->
            <div class="text-gray-700">{{ JSON.stringify(msg.data, null, 2) }}</div>
          </div>

          <!-- 无消息时的提示 -->
          <div v-if="messages.length === 0" class="text-gray-500 text-center">
            暂无消息
          </div>
        </ScrollArea>
      </CardContent>
    </Card>
  </div>
</template>

<!--
  =====================================================
  Vue 3 脚本部分 - Composition API
  =====================================================
  使用 setup 语法糖编写组件逻辑
  管理 WebSocket 连接和所有相关的状态
-->

<script setup>
// ===== 导入依赖 =====
import { ref, onMounted, onUnmounted } from 'vue'

// 导入 UI 组件
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { ScrollArea } from '@/components/ui/scroll-area'

// ===== 响应式状态定义 =====

/**
 * WebSocket 连接状态
 * 可能的值：'disconnected' | 'connecting' | 'connected' | 'error'
 */
const connectionStatus = ref('disconnected')

/**
 * WebSocket 连接实例
 * 用于与服务器进行双向通信
 */
const ws = ref(null)

/**
 * 消息历史记录数组
 * 存储所有收到和发送的消息
 */
const messages = ref([])

/**
 * 普通消息输入框的内容
 */
const messageText = ref('')

/**
 * 当前操作的房间ID
 */
const roomId = ref('')

/**
 * 房间消息输入框的内容
 */
const roomMessage = ref('')

/**
 * 广播消息输入框的内容
 */
const broadcastMessage = ref('')

// ===== WebSocket 连接管理函数 =====

/**
 * 连接到 WebSocket 服务器
 * 
 * 根据当前页面的协议自动选择 ws:// 或 wss://
 * 并设置各种事件监听器
 */
const connectWebSocket = () => {
  // 根据当前网页协议确定 WebSocket 协议
  // HTTPS 页面使用 wss://，HTTP 页面使用 ws://
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'

  // 构建 WebSocket 服务器地址
  // 格式：ws://localhost:3000/_ws 或 wss://example.com/_ws
  const wsUrl = `${protocol}//${window.location.host}/_ws`

  // 创建新的 WebSocket 连接实例
  ws.value = new WebSocket(wsUrl)

  // ===== WebSocket 事件监听器 =====

  /**
   * 连接成功事件
   * 当 WebSocket 连接建立成功时触发
   */
  ws.value.onopen = () => {
    // 更新连接状态
    connectionStatus.value = 'connected'
    // 添加系统消息到消息历史
    addMessage({ type: 'system', data: { message: 'WebSocket 连接已建立' }, timestamp: Date.now() })
  }

  /**
   * 收到消息事件
   * 当从服务器收到消息时触发
   */
  ws.value.onmessage = (event) => {
    try {
      // 尝试解析 JSON 消息
      const message = JSON.parse(event.data)
      addMessage(message)
    } catch (error) {
      // 如果不是 JSON 格式，作为原始文本处理
      addMessage({ type: 'raw', data: { message: event.data }, timestamp: Date.now() })
    }
  }

  /**
   * 连接关闭事件
   * 当 WebSocket 连接关闭时触发
   */
  ws.value.onclose = () => {
    // 更新连接状态
    connectionStatus.value = 'disconnected'
    // 添加系统消息
    addMessage({ type: 'system', data: { message: 'WebSocket 连接已关闭' }, timestamp: Date.now() })
  }

  /**
   * 连接错误事件
   * 当 WebSocket 连接发生错误时触发
   */
  ws.value.onerror = (error) => {
    addMessage({ type: 'error', data: { message: '连接错误', error }, timestamp: Date.now() })
  }
}

/**
 * 断开 WebSocket 连接
 * 手动关闭连接并清理资源
 */
const disconnectWebSocket = () => {
  if (ws.value) {
    // 关闭 WebSocket 连接
    ws.value.close()
    // 清空连接实例
    ws.value = null
  }
}

// ===== 消息发送函数 =====

/**
 * 发送普通文本消息
 * 将输入框中的内容发送到服务器
 */
const sendMessage = () => {
  // 检查连接状态和消息内容
  if (ws.value && messageText.value.trim()) {
    // 发送消息到服务器
    ws.value.send(messageText.value)
    // 清空输入框
    messageText.value = ''
  }
}

/**
 * 发送心跳检测消息（Ping）
 * 用于测试连接是否正常
 */
const sendPing = () => {
  if (ws.value) {
    // 发送标准的 ping 消息
    ws.value.send(JSON.stringify({
      type: 'ping',
      data: {},
      timestamp: Date.now()
    }))
  }
}

// ===== 房间相关函数 =====

/**
 * 加入指定房间
 * 发送加入房间的请求到服务器
 */
const joinRoom = () => {
  if (ws.value && roomId.value.trim()) {
    // 发送加入房间的消息
    ws.value.send(JSON.stringify({
      type: 'join_room',
      data: { roomId: roomId.value.trim() },
      timestamp: Date.now()
    }))
  }
}

/**
 * 离开指定房间
 * 发送离开房间的请求到服务器
 */
const leaveRoom = () => {
  if (ws.value && roomId.value.trim()) {
    // 发送离开房间的消息
    ws.value.send(JSON.stringify({
      type: 'leave_room',
      data: { roomId: roomId.value.trim() },
      timestamp: Date.now()
    }))
  }
}

/**
 * 发送房间消息
 * 向当前房间内的所有用户发送消息
 */
const sendRoomMessage = () => {
  // 检查连接状态、房间ID和消息内容
  if (ws.value && roomId.value.trim() && roomMessage.value.trim()) {
    // 发送房间消息
    ws.value.send(JSON.stringify({
      type: 'room_message',
      data: {
        roomId: roomId.value.trim(),
        message: roomMessage.value.trim()
      },
      timestamp: Date.now()
    }))
    // 清空房间消息输入框
    roomMessage.value = ''
  }
}

/**
 * 发送广播消息
 * 向所有连接的用户发送消息
 */
const sendBroadcast = () => {
  // 检查连接状态和消息内容
  if (ws.value && broadcastMessage.value.trim()) {
    // 发送广播消息
    ws.value.send(JSON.stringify({
      type: 'broadcast',
      data: {
        message: broadcastMessage.value.trim()
      },
      timestamp: Date.now()
    }))
    // 清空广播消息输入框
    broadcastMessage.value = ''
  }
}

// ===== 工具函数 =====

/**
 * 添加消息到历史记录
 * @param {Object} message 要添加的消息对象
 * 
 * 将收到的消息添加到消息历史中，并保持列表长度不超过50条
 */
const addMessage = (message) => {
  messages.value.push(message)

  // 保持最新的 50 条消息，超出部分自动删除最旧的消息
  // 这样可以避免内存无限增长
  if (messages.value.length > 50) {
    messages.value.shift()  // 移除数组的第一个元素（最旧的消息）
  }
}

/**
 * 清空所有消息历史
 * 用户点击"清空消息"按钮时调用
 */
const clearMessages = () => {
  messages.value = []
}

/**
 * 格式化时间戳为可读的时间字符串
 * @param {number} timestamp 时间戳（毫秒）
 * @returns {string} 格式化后的时间字符串（如：14:30:25）
 * 
 * 将时间戳转换为本地时间格式，便于用户查看消息时间
 */
const formatTime = (timestamp) => {
  return new Date(timestamp).toLocaleTimeString()
}

// ===== 生命周期钩子 =====

/**
 * 组件卸载时的清理工作
 * 当用户离开页面或组件被销毁时，自动断开 WebSocket 连接
 * 这样可以避免内存泄漏和无效连接
 */
onUnmounted(() => {
  // 调用断开连接函数，清理 WebSocket 资源
  disconnectWebSocket()
})
</script>

<!--
  =====================================================
  CSS 样式部分
  =====================================================
  使用 Tailwind CSS 提供的工具类进行样式设置
  如需自定义样式，可以在这里添加
-->

<style scoped>
/* 
  作用域样式（scoped styles）
  这里的样式只会应用到当前组件，不会影响其他组件
  
  目前使用 Tailwind CSS 提供足够的样式，
  如果需要特殊的自定义样式，可以在这里添加
*/
</style>