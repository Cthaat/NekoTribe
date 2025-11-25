<!-- 测试Token刷新页面 -->

<template>
  <div class="container mx-auto p-8">
    <h1 class="text-3xl font-bold mb-6">
      Token 刷新测试页面
    </h1>

    <div class="space-y-4">
      <!-- Token 信息显示 -->
      <div
        class="p-4 bg-gray-100 dark:bg-gray-800 rounded-lg"
      >
        <h2 class="text-xl font-semibold mb-2">
          当前 Token 信息
        </h2>
        <div class="space-y-2 text-sm">
          <div>
            <strong>Access Token (前20字符):</strong>
            {{
              accessToken
                ? accessToken.substring(0, 20) + '...'
                : '无'
            }}
          </div>
          <div>
            <strong>Token 剩余时间:</strong>
            {{
              timeLeft > 0
                ? `${Math.floor(timeLeft)} 秒`
                : 'Token 已过期或无效'
            }}
          </div>
          <div>
            <strong>登录状态:</strong>
            <span
              :class="
                isLoggedIn
                  ? 'text-green-600'
                  : 'text-red-600'
              "
            >
              {{ isLoggedIn ? '已登录' : '未登录' }}
            </span>
          </div>
        </div>
      </div>

      <!-- 操作按钮 -->
      <div class="space-y-2">
        <h2 class="text-xl font-semibold">测试操作</h2>

        <button
          @click="testApiCall"
          :disabled="loading"
          class="px-4 py-2 bg-blue-500 text-white rounded hover:bg-blue-600 disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {{
            loading
              ? '请求中...'
              : '发起需要认证的 API 请求'
          }}
        </button>

        <button
          @click="manualRefresh"
          :disabled="refreshing"
          class="px-4 py-2 bg-green-500 text-white rounded hover:bg-green-600 disabled:opacity-50 disabled:cursor-not-allowed ml-2"
        >
          {{ refreshing ? '刷新中...' : '手动刷新 Token' }}
        </button>

        <button
          @click="invalidateToken"
          class="px-4 py-2 bg-yellow-500 text-white rounded hover:bg-yellow-600 ml-2"
        >
          篡改 Token（模拟过期）
        </button>

        <button
          @click="clearAllTokens"
          class="px-4 py-2 bg-red-500 text-white rounded hover:bg-red-600 ml-2"
        >
          清除所有 Token
        </button>
      </div>

      <!-- 日志显示 -->
      <div
        class="p-4 bg-gray-900 text-green-400 rounded-lg"
      >
        <div class="flex justify-between items-center mb-2">
          <h2 class="text-xl font-semibold">操作日志</h2>
          <button
            @click="logs = []"
            class="px-3 py-1 bg-gray-700 text-white rounded text-sm hover:bg-gray-600"
          >
            清空日志
          </button>
        </div>
        <div
          class="h-64 overflow-y-auto font-mono text-xs space-y-1"
        >
          <div
            v-if="logs.length === 0"
            class="text-gray-500"
          >
            暂无日志...
          </div>
          <div v-for="(log, index) in logs" :key="index">
            <span class="text-gray-500">{{
              log.time
            }}</span>
            - {{ log.message }}
          </div>
        </div>
      </div>

      <!-- 说明 -->
      <div
        class="p-4 bg-blue-50 dark:bg-blue-900/20 rounded-lg"
      >
        <h2 class="text-xl font-semibold mb-2">测试说明</h2>
        <ul class="list-disc list-inside space-y-1 text-sm">
          <li>
            <strong>发起需要认证的 API 请求：</strong
            >会调用一个需要认证的接口，如果 Token
            过期会自动刷新并重试
          </li>
          <li>
            <strong>手动刷新 Token：</strong
            >直接调用刷新接口，更新 Token
          </li>
          <li>
            <strong>篡改 Token：</strong>修改 Token
            使其无效，模拟过期场景
          </li>
          <li>
            <strong>清除所有 Token：</strong
            >删除所有认证信息，需要重新登录
          </li>
        </ul>
        <div
          class="mt-4 p-3 bg-yellow-50 dark:bg-yellow-900/20 rounded"
        >
          <strong>⚠️ 提示：</strong
          >打开浏览器控制台可以查看详细的刷新日志
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted } from 'vue';
import { usePreferenceStore } from '~/stores/user';
import { apiFetch } from '@/composables/useApi';
import { jwtDecode } from 'jwt-decode';

const preferenceStore = usePreferenceStore();

const loading = ref(false);
const refreshing = ref(false);
const logs = ref<Array<{ time: string; message: string }>>(
  []
);
const timeLeft = ref(0);
let timer: NodeJS.Timeout | null = null;

const accessToken = computed(
  () => preferenceStore.preferences.access_token
);
const isLoggedIn = computed(
  () => preferenceStore.isLoggedIn
);

// 添加日志
const addLog = (message: string) => {
  const now = new Date();
  const time = now.toLocaleTimeString('zh-CN', {
    hour12: false
  });
  logs.value.push({ time, message });
  console.log(`[TokenTest ${time}] ${message}`);
};

// 计算 Token 剩余时间
const updateTimeLeft = () => {
  if (!accessToken.value) {
    timeLeft.value = 0;
    return;
  }

  try {
    const decoded = jwtDecode<{ exp: number }>(
      accessToken.value
    );
    const nowInSeconds = Date.now() / 1000;
    timeLeft.value = Math.max(
      0,
      decoded.exp - nowInSeconds
    );
  } catch (error) {
    timeLeft.value = 0;
    addLog('❌ Token 解码失败');
  }
};

// 测试 API 调用
const testApiCall = async () => {
  loading.value = true;
  addLog('🚀 发起 API 请求...');

  try {
    const response = await apiFetch(
      '/api/v1/notifications',
      {
        method: 'GET'
      }
    );

    addLog('✅ API 请求成功');
    console.log('API 响应:', response);
  } catch (error: any) {
    addLog(
      `❌ API 请求失败: ${error.message || '未知错误'}`
    );
    console.error('API 错误:', error);
  } finally {
    loading.value = false;
    updateTimeLeft();
  }
};

// 手动刷新 Token
const manualRefresh = async () => {
  refreshing.value = true;
  addLog('🔄 手动刷新 Token...');

  try {
    await preferenceStore.refreshAccessToken();
    addLog('✅ Token 刷新成功');
    updateTimeLeft();
  } catch (error: any) {
    addLog(
      `❌ Token 刷新失败: ${error.message || '未知错误'}`
    );
    console.error('刷新错误:', error);
  } finally {
    refreshing.value = false;
  }
};

// 篡改 Token
const invalidateToken = () => {
  if (!accessToken.value) {
    addLog('⚠️ 当前没有 Token');
    return;
  }

  const invalidToken =
    accessToken.value.substring(
      0,
      accessToken.value.length - 5
    ) + 'xxxxx';
  preferenceStore.updatePreference(
    'access_token',
    invalidToken
  );
  addLog('⚠️ Token 已被篡改（模拟过期）');
  updateTimeLeft();
};

// 清除所有 Token
const clearAllTokens = () => {
  preferenceStore.clearAuthTokens();
  addLog('🗑️ 所有 Token 已清除');
  updateTimeLeft();
};

// 定时更新剩余时间
onMounted(() => {
  updateTimeLeft();
  timer = setInterval(updateTimeLeft, 1000);
  addLog('✨ 测试页面已加载');
});

onUnmounted(() => {
  if (timer) clearInterval(timer);
});
</script>
