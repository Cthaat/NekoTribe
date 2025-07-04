<template>
  <div class="container">
    <h1>生产级实时推送演示</h1>

    <div class="auth-section">
      <h2>1. 用户认证</h2>
      <p>当前用户: <strong>{{ userId || '未登录' }}</strong></p>
      <p>认证 Token: <small>{{ authToken || 'N/A' }}</small></p>
      <div class="user-buttons">
        <button @click="login('user-123')">登录为 User 123</button>
        <button @click="login('user-456')">登录为 User 456</button>
      </div>
    </div>

    <!-- 只有登录后才加载 WebSocket 处理器 -->
    <NotificationHandler v-if="authToken" :token="authToken" ref="notificationHandlerRef" />

    <div class="push-section">
      <h2>2. 触发推送</h2>
      <p>向指定用户发送消息:</p>
      <input v-model="targetUserId" placeholder="目标用户ID (e.g., user-123)" />
      <input v-model="pushMessage" placeholder="消息内容" />
      <button @click="triggerPush" :disabled="!targetUserId || !pushMessage">发送推送</button>
      <p v-if="pushStatus">{{ pushStatus }}</p>
    </div>

    <div class="display-section">
      <h2>3. 接收到的通知</h2>
      <p>WebSocket 状态: <strong>{{ connectionStatus }}</strong></p>
      <ul v-if="notifications.length > 0">
        <li v-for="n in notifications" :key="n.id">
          <p>{{ n.text }}</p>
          <small>{{ new Date(n.timestamp).toLocaleString() }}</small>
        </li>
      </ul>
      <p v-else>暂无通知</p>
    </div>
  </div>
  <div>
    <Button>
      <NuxtLink to="/dashboard">Go to Dashboard</NuxtLink>
    </Button>
  </div>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue'
import { generateFakeToken } from '~/server/utils/auth' // Nuxt 自动处理路径
import NotificationHandler from '~/components/NotificationHandler.vue'

// 认证状态
const userId = ref < string | null > (null)
const authToken = ref < string | null > (null)

// 推送表单状态
const targetUserId = ref('user-123')
const pushMessage = ref('这是一条测试消息！')
const pushStatus = ref('')

// WebSocket 组件的引用
const notificationHandlerRef = ref < { notifications: any[], connectionStatus: string } | null > (null)

// 从子组件获取数据
const notifications = computed(() => notificationHandlerRef.value?.notifications || [])
const connectionStatus = computed(() => notificationHandlerRef.value?.connectionStatus || 'Not Initialized')

import { Button } from '@/components/ui/button';

function login(id: string) {
  userId.value = id
  authToken.value = generateFakeToken(id)
}

async function triggerPush() {
  pushStatus.value = '发送中...'
  try {
    const response = await $fetch('/api/push', {
      method: 'POST',
      body: {
        userId: targetUserId.value,
        message: pushMessage.value,
      },
    })
    pushStatus.value = `发送成功！详情: ${(response as any).detail}`
  } catch (error: any) {
    pushStatus.value = `发送失败: ${error.data?.statusMessage || error.message}`
  }
}
</script>

<style scoped>
.container {
  max-width: 800px;
  margin: auto;
  font-family: sans-serif;
}

.auth-section,
.push-section,
.display-section {
  border: 1px solid #ccc;
  padding: 1rem;
  margin-bottom: 1rem;
  border-radius: 8px;
}

input {
  display: block;
  width: calc(100% - 20px);
  padding: 8px;
  margin-bottom: 10px;
}

button {
  margin-right: 10px;
}

ul {
  list-style: none;
  padding: 0;
}

li {
  background: #f4f4f4;
  padding: 10px;
  border-radius: 4px;
  margin-bottom: 8px;
}
</style>