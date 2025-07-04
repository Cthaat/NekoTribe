<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'

// Props to receive the user's auth token
const props = defineProps<{
  token: string | null
}>()

const notifications = ref<any[]>([])
const connectionStatus = ref('Disconnected')
let ws: WebSocket | null = null
let reconnectTimer: number | null = null

function connect() {
  if (!props.token) {
    connectionStatus.value = 'Auth Token Missing'
    return
  }

  // 构建 WebSocket URL - 直接使用当前域名的 WebSocket 端点
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
  const host = window.location.host
  const wsUrl = `${protocol}//${host}/_ws?token=${props.token}`

  // 清理旧的连接和定时器
  if (ws) ws.close()
  if (reconnectTimer) clearTimeout(reconnectTimer)

  ws = new WebSocket(wsUrl)
  connectionStatus.value = 'Connecting...'

  ws.onopen = () => {
    connectionStatus.value = 'Connected'
  }

  ws.onmessage = (event) => {
    try {
      const message = JSON.parse(event.data)
      if (message.type === 'NOTIFICATION') {
        notifications.value.unshift(message.data)
      } else {
        console.log('Received system message:', message)
      }
    } catch (e) {
      console.error('Error parsing WebSocket message:', e)
    }
  }

  ws.onclose = (event) => {
    // 1000 是正常关闭，不重连
    if (event.code !== 1000) {
      connectionStatus.value = `Disconnected. Retrying in 5s...`
      reconnectTimer = window.setTimeout(connect, 5000)
    } else {
      connectionStatus.value = 'Disconnected'
    }
  }

  ws.onerror = () => {
    connectionStatus.value = 'Connection Error'
    ws?.close() // 这将触发 onclose 中的重连逻辑
  }
}

onMounted(() => {
  connect()
})

onUnmounted(() => {
  if (reconnectTimer) clearTimeout(reconnectTimer)
  if (ws) {
    ws.onclose = null // 阻止在组件销毁后重连
    ws.close(1000, 'Component unmounted') // 正常关闭
  }
})

// 将状态和数据暴露给父组件
defineExpose({
  notifications,
  connectionStatus,
})
</script>

<!-- 这个组件没有模板，它只处理逻辑 -->
<template>
  <div />
</template>