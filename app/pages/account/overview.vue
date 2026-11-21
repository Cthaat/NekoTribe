<script setup lang="ts">
import {
  v2GetMe,
  v2GetUserAnalytics,
  v2GetUserDailyAnalytics
} from '@/services';
import { onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { BarChart3 } from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import { authQueueFor } from '@/services/auth-request-queue';
import type { UserDailyAnalyticsVM } from '@/types/users';

const { t } = useAppLocale();
const app = useNuxtApp();
const auth = authQueueFor(app);

interface UserAnalyticsData {
  totalTweets: number;
  tweetsThisWeek: number;
  totalLikesReceived: number;
  avgLikesPerTweet: number;
  totalLikesGiven: number;
  totalCommentsMade: number;
  engagementScore: number;
}

const userAnalytics = ref<UserAnalyticsData | null>(null);
const dailyAnalytics = ref<UserDailyAnalyticsVM[]>([]);
const periods = [7, 14, 30, 90] as const;
const days = ref<number>(14);
const overviewLoading = ref(true);
const overviewFailed = ref(false);
const dailyState = ref<'loading' | 'ready' | 'failed'>('loading');
const expired = ref(false);
let meId: number | undefined;
let overviewRevision = 0;
let dailyRequest: AbortController | undefined;
let unsubscribe: (() => void) | undefined;

async function loadDaily() {
  const userId = meId;
  if (userId === undefined || expired.value || auth.isIdentityChanging) return;
  dailyRequest?.abort();
  const request = new AbortController();
  const authRevision = auth.revision;
  dailyRequest = request;
  const current = () => dailyRequest === request && auth.revision === authRevision;
  dailyAnalytics.value = [];
  dailyState.value = 'loading';
  try {
    const rows = await app.runWithContext(() => v2GetUserDailyAnalytics(userId, { days: days.value }, request.signal));
    if (!current()) return;
    dailyAnalytics.value = rows;
    dailyState.value = 'ready';
  } catch {
    if (current()) dailyState.value = 'failed';
  }
}

async function loadOverview() {
  if (expired.value || auth.isIdentityChanging) return;
  const request = ++overviewRevision;
  const authRevision = auth.revision;
  const current = () => request === overviewRevision && auth.revision === authRevision;
  overviewLoading.value = true;
  overviewFailed.value = false;
  try {
    const me = await app.runWithContext(() => v2GetMe());
    if (!current()) return;
    const analytics = await app.runWithContext(() => v2GetUserAnalytics(me.id));
    if (!current()) return;
    meId = me.id;
    userAnalytics.value = {
      totalTweets: analytics.totalPosts,
      tweetsThisWeek: analytics.postsThisWeek,
      totalLikesReceived: analytics.totalLikesReceived,
      avgLikesPerTweet: analytics.avgLikesPerPost,
      totalLikesGiven: analytics.totalLikesGiven,
      totalCommentsMade: analytics.totalCommentsMade,
      engagementScore: analytics.engagementScore
    };
    void loadDaily();
  } catch {
    if (current()) overviewFailed.value = true;
  } finally {
    if (current()) overviewLoading.value = false;
  }
}

function clearRequests() {
  overviewRevision++;
  dailyRequest?.abort();
  dailyRequest = undefined;
}

watch(days, loadDaily);
onMounted(() => {
  unsubscribe = auth.subscribe(() => {
    clearRequests();
    expired.value = true;
    meId = undefined;
    userAnalytics.value = null;
    dailyAnalytics.value = [];
  });
  expired.value = auth.isIdentityChanging;
  void loadOverview();
});
onBeforeUnmount(() => {
  unsubscribe?.();
  clearRequests();
});
</script>

<template>
  <section
    class="grid gap-5 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
  >
    <header class="flex items-start gap-3">
      <span
        class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-sky-500/10 text-sky-600 dark:text-sky-400"
      >
        <BarChart3 class="h-4 w-4" />
      </span>
      <div class="min-w-0 grid gap-0.5">
        <h2 class="text-lg font-semibold tracking-tight">
          {{ t('account.overview.title') }}
        </h2>
        <p class="text-xs text-muted-foreground">
          {{ t('account.overview.description') }}
        </p>
      </div>
    </header>
    <p v-if="expired" role="status">{{ t('visibility.sessionChanged') }}</p>
    <p v-else-if="overviewLoading" role="status">{{ t('common.loading') }}</p>
    <div v-else-if="overviewFailed" class="flex flex-wrap items-center gap-2">
      <p role="alert">{{ t('account.errors.loadAnalytics') }}</p>
      <Button variant="outline" size="sm" @click="loadOverview">{{ t('common.retry') }}</Button>
    </div>
    <OverAllPanel v-else-if="userAnalytics"
      :userAnalytics="userAnalytics"
      :dailyAnalytics="dailyAnalytics"
      :daily-ready="dailyState === 'ready'"
    >
      <template #daily-controls>
        <div class="flex flex-wrap items-center gap-3 md:col-span-2 lg:col-span-3">
          <label class="flex items-center gap-2 text-sm">
            {{ t('account.overview.overallPanel.dailyRange') }}
            <select v-model.number="days" class="rounded-md border bg-background px-2 py-1.5">
              <option v-for="period in periods" :key="period" :value="period">
                {{ t('account.overview.overallPanel.rangeDays', { days: period }) }}
              </option>
            </select>
          </label>
          <p v-if="dailyState === 'loading'" role="status">{{ t('common.loading') }}</p>
          <template v-if="dailyState === 'failed'">
            <p role="alert">{{ t('account.overview.overallPanel.dailyFailed') }}</p>
            <Button variant="outline" size="sm" @click="loadDaily">{{ t('common.retry') }}</Button>
          </template>
        </div>
      </template>
    </OverAllPanel>
  </section>
</template>
