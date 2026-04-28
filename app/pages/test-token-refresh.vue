<!-- 测试Token刷新页面 -->

<template>
  <div class="container mx-auto p-8">
    <h1 class="text-3xl font-bold mb-6">
      {{ t('diagnostics.token.pageTitle') }}
    </h1>

    <div class="space-y-4">
      <!-- Token 信息显示 -->
      <div
        class="p-4 bg-gray-100 dark:bg-gray-800 rounded-lg"
      >
        <h2 class="text-xl font-semibold mb-2">
          {{ t('diagnostics.token.infoTitle') }}
        </h2>
        <div class="space-y-2 text-sm">
          <div>
            <strong>{{
              t('diagnostics.token.sessionId')
            }}</strong>
            {{
              sessionId
                ? sessionId.substring(0, 20) + '...'
                : t('diagnostics.token.none')
            }}
          </div>
          <div>
            <strong>{{
              t('diagnostics.token.tokenTimeLeft')
            }}</strong>
            {{
              timeLeft > 0
                ? t('diagnostics.token.seconds', {
                    count: Math.floor(timeLeft)
                  })
                : t('diagnostics.token.expired')
            }}
          </div>
          <div>
            <strong>{{
              t('diagnostics.token.loginStatus')
            }}</strong>
            <span
              :class="
                isLoggedIn
                  ? 'text-green-600'
                  : 'text-red-600'
              "
            >
              {{
                isLoggedIn
                  ? t('diagnostics.token.loggedIn')
                  : t('diagnostics.token.loggedOut')
              }}
            </span>
          </div>
        </div>
      </div>

      <!-- 操作按钮 -->
      <div class="space-y-2">
        <h2 class="text-xl font-semibold">
          {{ t('diagnostics.token.actionsTitle') }}
        </h2>

        <AppButton
          @click="testApiCall"
          :disabled="loading"
          :loading="loading"
        >
          {{
            loading
              ? t('diagnostics.token.requesting')
              : t('diagnostics.token.authRequest')
          }}
        </AppButton>

        <AppButton
          @click="manualRefresh"
          :disabled="refreshing"
          :loading="refreshing"
          class="ml-2"
        >
          {{
            refreshing
              ? t('diagnostics.token.refreshing')
              : t('diagnostics.token.manualRefresh')
          }}
        </AppButton>

        <AppButton
          @click="invalidateToken"
          variant="secondary"
          class="ml-2"
        >
          {{ t('diagnostics.token.invalidateToken') }}
        </AppButton>

        <AppButton
          @click="clearAllTokens"
          variant="destructive"
          class="ml-2"
        >
          {{ t('diagnostics.token.clearTokens') }}
        </AppButton>
      </div>

      <!-- 日志显示 -->
      <div
        class="p-4 bg-gray-900 text-green-400 rounded-lg"
      >
        <div class="flex justify-between items-center mb-2">
          <h2 class="text-xl font-semibold">
            {{ t('diagnostics.token.logsTitle') }}
          </h2>
          <AppButton
            @click="logs = []"
            size="sm"
            variant="secondary"
          >
            {{ t('diagnostics.token.clearLogs') }}
          </AppButton>
        </div>
        <div
          class="h-64 overflow-y-auto font-mono text-xs space-y-1"
        >
          <div
            v-if="logs.length === 0"
            class="text-gray-500"
          >
            {{ t('diagnostics.token.emptyLogs') }}
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
        <h2 class="text-xl font-semibold mb-2">
          {{ t('diagnostics.token.instructionsTitle') }}
        </h2>
        <ul class="list-disc list-inside space-y-1 text-sm">
          <li>
            <strong>{{
              t('diagnostics.token.instructionsAuthTitle')
            }}</strong
            >{{ t('diagnostics.token.instructionsAuth') }}
          </li>
          <li>
            <strong>{{
              t('diagnostics.token.instructionsRefreshTitle')
            }}</strong
            >{{ t('diagnostics.token.instructionsRefresh') }}
          </li>
          <li>
            <strong>{{
              t('diagnostics.token.instructionsInvalidateTitle')
            }}</strong
            >{{ t('diagnostics.token.instructionsInvalidate') }}
          </li>
          <li>
            <strong>{{
              t('diagnostics.token.instructionsClearTitle')
            }}</strong
            >{{ t('diagnostics.token.instructionsClear') }}
          </li>
        </ul>
        <div
          class="mt-4 p-3 bg-yellow-50 dark:bg-yellow-900/20 rounded"
        >
          <strong>{{
            t('diagnostics.token.tipTitle')
          }}</strong
          >{{ t('diagnostics.token.tip') }}
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted } from 'vue';
import { usePreferenceStore } from '~/stores/user';
import { v2ListNotifications } from '@/services';
import AppButton from '@/components/app/AppButton.vue';

const { t, locale } = useAppLocale();
const preferenceStore = usePreferenceStore();

const loading = ref(false);
const refreshing = ref(false);
const logs = ref<Array<{ time: string; message: string }>>(
  []
);
const timeLeft = ref(0);
let timer: NodeJS.Timeout | null = null;

const sessionId = computed(
  () => preferenceStore.preferences.authSession?.sessionId || ''
);
const isLoggedIn = computed(
  () => preferenceStore.isLoggedIn
);

// 添加日志
const addLog = (message: string) => {
  const now = new Date();
  const time = now.toLocaleTimeString(locale.value, {
    hour12: false
  });
  logs.value.push({ time, message });
};

// 计算 Token 剩余时间
const updateTimeLeft = () => {
  const accessTokenExpiresAt =
    preferenceStore.preferences.authSession
      ?.accessTokenExpiresAt;
  if (!accessTokenExpiresAt) {
    timeLeft.value = 0;
    return;
  }

  try {
    const expiresAt = new Date(accessTokenExpiresAt).getTime();
    const nowInMilliseconds = Date.now();
    timeLeft.value = Math.max(
      0,
      (expiresAt - nowInMilliseconds) / 1000
    );
  } catch (error) {
    timeLeft.value = 0;
    addLog(`❌ ${t('diagnostics.token.decodeFailed')}`);
  }
};

// 测试 API 调用
const testApiCall = async () => {
  loading.value = true;
  addLog(`🚀 ${t('diagnostics.token.apiRequestStart')}`);

  try {
    const response = await v2ListNotifications({
      page: 1,
      pageSize: 1
    });

    addLog(`✅ ${t('diagnostics.token.apiRequestSuccess')}`);
  } catch (error) {
    const message =
      error instanceof Error
        ? error.message
        : t('common.unknownError');
    addLog(
      `❌ ${t('diagnostics.token.apiRequestFailed', {
        message
      })}`
    );
    console.error(t('diagnostics.token.apiErrorLog'), error);
  } finally {
    loading.value = false;
    updateTimeLeft();
  }
};

// 手动刷新 Token
const manualRefresh = async () => {
  refreshing.value = true;
  addLog(`🔄 ${t('diagnostics.token.refreshStart')}`);

  try {
    await preferenceStore.refreshAccessToken();
    addLog(`✅ ${t('diagnostics.token.refreshSuccess')}`);
    updateTimeLeft();
  } catch (error) {
    const message =
      error instanceof Error
        ? error.message
        : t('common.unknownError');
    addLog(
      `❌ ${t('diagnostics.token.refreshFailed', {
        message
      })}`
    );
    console.error(t('diagnostics.token.refreshErrorLog'), error);
  } finally {
    refreshing.value = false;
  }
};

// 篡改 Token
const invalidateToken = () => {
  if (!sessionId.value) {
    addLog(`⚠️ ${t('diagnostics.token.noSession')}`);
    return;
  }
  addLog(
    `⚠️ ${t('diagnostics.token.httpOnlyTamperUnavailable')}`
  );
};

// 清除所有 Token
const clearAllTokens = () => {
  preferenceStore.clearAuthState();
  addLog(`🗑️ ${t('diagnostics.token.tokensCleared')}`);
  updateTimeLeft();
};

// 定时更新剩余时间
onMounted(() => {
  updateTimeLeft();
  timer = setInterval(updateTimeLeft, 1000);
  addLog(`✨ ${t('diagnostics.token.pageLoaded')}`);
});

onUnmounted(() => {
  if (timer) clearInterval(timer);
});
</script>


