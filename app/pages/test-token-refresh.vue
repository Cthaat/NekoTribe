<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted } from 'vue';
import {
  Clock,
  Info,
  KeyRound,
  Lightbulb,
  Loader2,
  RefreshCw,
  ShieldAlert,
  Sparkles,
  Terminal,
  Trash2
} from 'lucide-vue-next';
import { usePreferenceStore } from '~/stores/user';
import { v2ListNotifications } from '@/services';
import AppButton from '@/components/app/AppButton.vue';
import { ScrollArea } from '@/components/ui/scroll-area';

const { t, locale } = useAppLocale();
const preferenceStore = usePreferenceStore();

const loading = ref(false);
const refreshing = ref(false);
const logs = ref<Array<{ time: string; message: string }>>([]);
const timeLeft = ref(0);
let timer: NodeJS.Timeout | null = null;

const sessionId = computed(
  () => preferenceStore.preferences.authSession?.sessionId || ''
);
const isLoggedIn = computed(() => preferenceStore.isLoggedIn);

const addLog = (message: string) => {
  const now = new Date();
  const time = now.toLocaleTimeString(locale.value, {
    hour12: false
  });
  logs.value.push({ time, message });
};

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
  } catch {
    timeLeft.value = 0;
    addLog(`❌ ${t('diagnostics.token.decodeFailed')}`);
  }
};

const testApiCall = async () => {
  loading.value = true;
  addLog(`🚀 ${t('diagnostics.token.apiRequestStart')}`);

  try {
    await v2ListNotifications({
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
  } finally {
    loading.value = false;
    updateTimeLeft();
  }
};

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
  } finally {
    refreshing.value = false;
  }
};

const invalidateToken = () => {
  if (!sessionId.value) {
    addLog(`⚠️ ${t('diagnostics.token.noSession')}`);
    return;
  }
  addLog(
    `⚠️ ${t('diagnostics.token.httpOnlyTamperUnavailable')}`
  );
};

const clearAllTokens = () => {
  preferenceStore.clearAuthState();
  addLog(`🗑️ ${t('diagnostics.token.tokensCleared')}`);
  updateTimeLeft();
};

onMounted(() => {
  updateTimeLeft();
  timer = setInterval(updateTimeLeft, 1000);
  addLog(`✨ ${t('diagnostics.token.pageLoaded')}`);
});

onUnmounted(() => {
  if (timer) clearInterval(timer);
});
</script>

<template>
  <div class="mx-auto max-w-4xl space-y-6 p-4 sm:p-6">
    <header class="flex items-start gap-3">
      <span
        class="flex h-10 w-10 items-center justify-center rounded-lg bg-amber-500/10 text-amber-600 ring-1 ring-amber-200/60 dark:text-amber-400 dark:ring-amber-900/40"
      >
        <KeyRound class="h-5 w-5" />
      </span>
      <div class="min-w-0 flex-1">
        <h1 class="text-2xl font-semibold tracking-tight">
          {{ t('diagnostics.token.pageTitle') }}
        </h1>
        <p class="mt-1 text-sm text-muted-foreground">
          Token refresh diagnostics & lifecycle testing
        </p>
      </div>
    </header>

    <section
      class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <div class="flex items-center gap-2">
        <span
          class="flex h-9 w-9 items-center justify-center rounded-md bg-sky-500/10 text-sky-600 dark:text-sky-400"
        >
          <Info class="h-4 w-4" />
        </span>
        <h2 class="text-sm font-semibold tracking-tight">
          {{ t('diagnostics.token.infoTitle') }}
        </h2>
      </div>

      <div class="grid gap-3 sm:grid-cols-3">
        <div
          class="rounded-lg border border-border/60 bg-muted/20 p-3"
        >
          <div
            class="text-[11px] font-medium uppercase tracking-wider text-muted-foreground"
          >
            {{ t('diagnostics.token.sessionId') }}
          </div>
          <div
            class="mt-1 truncate font-mono text-xs text-foreground"
          >
            {{
              sessionId
                ? sessionId.substring(0, 20) + '...'
                : t('diagnostics.token.none')
            }}
          </div>
        </div>
        <div
          class="rounded-lg border border-border/60 bg-muted/20 p-3"
        >
          <div
            class="text-[11px] font-medium uppercase tracking-wider text-muted-foreground"
          >
            {{ t('diagnostics.token.tokenTimeLeft') }}
          </div>
          <div
            class="mt-1 flex items-center gap-1.5 text-sm font-semibold tabular-nums"
            :class="
              timeLeft > 0
                ? 'text-foreground'
                : 'text-rose-600 dark:text-rose-400'
            "
          >
            <Clock class="h-3.5 w-3.5 text-muted-foreground" />
            {{
              timeLeft > 0
                ? t('diagnostics.token.seconds', {
                    count: Math.floor(timeLeft)
                  })
                : t('diagnostics.token.expired')
            }}
          </div>
        </div>
        <div
          class="rounded-lg border border-border/60 bg-muted/20 p-3"
        >
          <div
            class="text-[11px] font-medium uppercase tracking-wider text-muted-foreground"
          >
            {{ t('diagnostics.token.loginStatus') }}
          </div>
          <div class="mt-1">
            <span
              :class="[
                'inline-flex items-center gap-1.5 rounded-full border px-2 py-0.5 text-[11px] font-medium',
                isLoggedIn
                  ? 'border-emerald-200/60 bg-emerald-100/60 text-emerald-700 dark:border-emerald-900/40 dark:bg-emerald-950/40 dark:text-emerald-300'
                  : 'border-rose-200/60 bg-rose-100/60 text-rose-700 dark:border-rose-900/40 dark:bg-rose-950/40 dark:text-rose-300'
              ]"
            >
              <span
                :class="[
                  'h-1.5 w-1.5 rounded-full',
                  isLoggedIn
                    ? 'bg-emerald-500 animate-pulse'
                    : 'bg-rose-500'
                ]"
              />
              {{
                isLoggedIn
                  ? t('diagnostics.token.loggedIn')
                  : t('diagnostics.token.loggedOut')
              }}
            </span>
          </div>
        </div>
      </div>
    </section>

    <section
      class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <div class="flex items-center gap-2">
        <span
          class="flex h-9 w-9 items-center justify-center rounded-md bg-emerald-500/10 text-emerald-600 dark:text-emerald-400"
        >
          <Sparkles class="h-4 w-4" />
        </span>
        <h2 class="text-sm font-semibold tracking-tight">
          {{ t('diagnostics.token.actionsTitle') }}
        </h2>
      </div>

      <div class="grid gap-2 sm:flex sm:flex-wrap">
        <AppButton
          class="h-9 w-full rounded-md shadow-xs sm:w-auto"
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
          class="h-9 w-full rounded-md shadow-xs sm:w-auto"
          @click="manualRefresh"
          :disabled="refreshing"
          :loading="refreshing"
          variant="outline"
        >
          <RefreshCw class="h-3.5 w-3.5" />
          {{
            refreshing
              ? t('diagnostics.token.refreshing')
              : t('diagnostics.token.manualRefresh')
          }}
        </AppButton>

        <AppButton
          class="h-9 w-full rounded-md shadow-xs sm:w-auto"
          @click="invalidateToken"
          variant="outline"
        >
          <ShieldAlert class="h-3.5 w-3.5" />
          {{ t('diagnostics.token.invalidateToken') }}
        </AppButton>

        <AppButton
          class="h-9 w-full rounded-md shadow-xs sm:w-auto"
          @click="clearAllTokens"
          variant="destructive"
        >
          <Trash2 class="h-3.5 w-3.5" />
          {{ t('diagnostics.token.clearTokens') }}
        </AppButton>
      </div>
    </section>

    <section
      class="grid gap-3 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <div class="flex items-center justify-between gap-3">
        <div class="flex items-center gap-2">
          <span
            class="flex h-9 w-9 items-center justify-center rounded-md bg-violet-500/10 text-violet-600 dark:text-violet-400"
          >
            <Terminal class="h-4 w-4" />
          </span>
          <h2 class="text-sm font-semibold tracking-tight">
            {{ t('diagnostics.token.logsTitle') }}
          </h2>
          <span
            class="ml-1 inline-flex items-center rounded-full border border-border/60 bg-muted/40 px-2 py-0.5 text-[10px] font-medium tabular-nums text-muted-foreground"
          >
            {{ logs.length }}
          </span>
        </div>
        <AppButton
          @click="logs = []"
          size="sm"
          variant="ghost"
          class="h-8 rounded-md text-muted-foreground hover:text-foreground"
          :disabled="logs.length === 0"
        >
          <Trash2 class="h-3.5 w-3.5" />
          {{ t('diagnostics.token.clearLogs') }}
        </AppButton>
      </div>

      <ScrollArea
        class="h-64 w-full rounded-lg border border-border/60 bg-zinc-950 font-mono text-xs dark:bg-zinc-950/80"
      >
        <div class="space-y-1 p-3">
          <div
            v-if="logs.length === 0"
            class="flex items-center gap-2 py-2 text-zinc-500"
          >
            <Loader2 class="h-3 w-3 animate-spin opacity-50" />
            {{ t('diagnostics.token.emptyLogs') }}
          </div>
          <div
            v-for="(log, index) in logs"
            :key="index"
            class="flex gap-2 leading-relaxed"
          >
            <span class="shrink-0 tabular-nums text-zinc-500">
              {{ log.time }}
            </span>
            <span class="text-emerald-300">{{ log.message }}</span>
          </div>
        </div>
      </ScrollArea>
    </section>

    <section
      class="grid gap-3 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <div class="flex items-center gap-2">
        <span
          class="flex h-9 w-9 items-center justify-center rounded-md bg-amber-500/10 text-amber-600 dark:text-amber-400"
        >
          <Lightbulb class="h-4 w-4" />
        </span>
        <h2 class="text-sm font-semibold tracking-tight">
          {{ t('diagnostics.token.instructionsTitle') }}
        </h2>
      </div>

      <ul class="grid gap-2 text-sm">
        <li
          class="flex gap-2 rounded-lg border border-border/60 bg-muted/20 p-3"
        >
          <span class="text-sky-600 dark:text-sky-400">→</span>
          <div>
            <strong class="font-medium">
              {{ t('diagnostics.token.instructionsAuthTitle') }}
            </strong>
            <span class="text-muted-foreground">
              {{ t('diagnostics.token.instructionsAuth') }}
            </span>
          </div>
        </li>
        <li
          class="flex gap-2 rounded-lg border border-border/60 bg-muted/20 p-3"
        >
          <span class="text-emerald-600 dark:text-emerald-400">→</span>
          <div>
            <strong class="font-medium">
              {{ t('diagnostics.token.instructionsRefreshTitle') }}
            </strong>
            <span class="text-muted-foreground">
              {{ t('diagnostics.token.instructionsRefresh') }}
            </span>
          </div>
        </li>
        <li
          class="flex gap-2 rounded-lg border border-border/60 bg-muted/20 p-3"
        >
          <span class="text-amber-600 dark:text-amber-400">→</span>
          <div>
            <strong class="font-medium">
              {{ t('diagnostics.token.instructionsInvalidateTitle') }}
            </strong>
            <span class="text-muted-foreground">
              {{ t('diagnostics.token.instructionsInvalidate') }}
            </span>
          </div>
        </li>
        <li
          class="flex gap-2 rounded-lg border border-border/60 bg-muted/20 p-3"
        >
          <span class="text-rose-600 dark:text-rose-400">→</span>
          <div>
            <strong class="font-medium">
              {{ t('diagnostics.token.instructionsClearTitle') }}
            </strong>
            <span class="text-muted-foreground">
              {{ t('diagnostics.token.instructionsClear') }}
            </span>
          </div>
        </li>
      </ul>

      <div
        class="flex gap-3 rounded-lg border border-amber-200/60 bg-amber-50/50 p-3 dark:border-amber-900/40 dark:bg-amber-950/30"
      >
        <Lightbulb
          class="h-4 w-4 shrink-0 text-amber-600 dark:text-amber-400"
        />
        <div class="text-sm text-amber-900 dark:text-amber-200">
          <strong class="font-medium">
            {{ t('diagnostics.token.tipTitle') }}
          </strong>
          {{ t('diagnostics.token.tip') }}
        </div>
      </div>
    </section>
  </div>
</template>
