<template>
  <div>
    <Button>
      <NuxtLink to="/dashboard">Go to Dashboard</NuxtLink>
    </Button>
  </div>
  <div>
    <Button>
      <NuxtLink to="/ws">Go to ws demo</NuxtLink>
    </Button>
  </div>
</template>

<script setup lang="ts">
import { Button } from '@/components/ui/button';

import { onMounted } from 'vue'

onMounted(() => {
  const ws = new WebSocket('ws://localhost:3000/_ws')

  ws.onopen = () => {
    console.log('WebSocket 已连接')
    ws.send('ping')
  }

  ws.onmessage = (event) => {
    console.log('收到消息:', event.data)
  }

  ws.onclose = () => {
    console.log('WebSocket 已关闭')
  }

  ws.onerror = (error) => {
    console.log('WebSocket 发生错误:', error)
  }
})
</script>