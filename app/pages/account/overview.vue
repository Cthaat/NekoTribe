<script setup lang="ts">
import {
  v2GetMe,
  v2GetUserAnalytics,
  v2GetUserDailyAnalytics
} from '@/services';
import { onBeforeUnmount, onMounted, ref, watch } from 'vue';
import {
  BarChart3,
  Bot,
  CreditCard,
  FileText,
  Settings,
  Shield,
  Smartphone,
  Sparkles
} from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@/components/ui/select';
import { authQueueFor } from '@/services/auth-request-queue';
import type { UserDailyAnalyticsVM } from '@/types/users';

const { t } = useAppLocale();
const localePath = useLocalePath();
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
  <div class="space-y-5">
  <section
    class="grid gap-5 rounded-[20px] bg-card p-5 shadow-[0_1px_3px_rgba(15,23,42,0.03)] dark:shadow-none sm:p-6"
  >
    <header class="flex items-start gap-3">
      <span
        class="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-secondary text-foreground"
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
      <Button variant="secondary" size="sm" class="rounded-full" @click="loadOverview">{{ t('common.retry') }}</Button>
    </div>
      <OverAllPanel v-else-if="userAnalytics"
        :userAnalytics="userAnalytics"
        :dailyAnalytics="dailyAnalytics"
        :daily-ready="dailyState === 'ready'"
      >
        <template #daily-controls>
          <div class="flex flex-wrap items-center gap-3 md:col-span-2 lg:col-span-3">
            <div class="flex items-center gap-2.5">
              <Label for="overview-daily-range" class="font-normal">
                {{ t('account.overview.overallPanel.dailyRange') }}
              </Label>
              <Select :model-value="String(days)" @update:model-value="v => days = Number(v)">
                <SelectTrigger id="overview-daily-range" class="h-9 w-36 rounded-xl border-0 bg-secondary">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent class="rounded-xl">
                  <SelectItem v-for="period in periods" :key="period" :value="String(period)" class="rounded-lg">
                    {{ t('account.overview.overallPanel.rangeDays', { days: period }) }}
                  </SelectItem>
                </SelectContent>
              </Select>
            </div>
            <p v-if="dailyState === 'loading'" role="status">{{ t('common.loading') }}</p>
            <template v-if="dailyState === 'failed'">
              <p role="alert">{{ t('account.overview.overallPanel.dailyFailed') }}</p>
              <Button variant="secondary" size="sm" class="rounded-full" @click="loadDaily">{{ t('common.retry') }}</Button>
            </template>
          </div>
        </template>
      </OverAllPanel>
  </section>

  <section class="grid gap-3 rounded-[20px] bg-card p-5 shadow-[0_1px_3px_rgba(15,23,42,0.03)] dark:shadow-none sm:p-6">
    <h2 class="text-[15px] font-semibold tracking-tight text-foreground">
      {{ t('account.tabs.settings') }}
    </h2>
    <div class="grid grid-cols-2 gap-2.5 sm:grid-cols-4">
      <NuxtLink
        v-for="item in [
          { to: 'account-settings', label: t('account.tabs.settings'), icon: Settings },
          { to: 'account-security', label: t('account.tabs.security'), icon: Shield },
          { to: 'account-active', label: t('account.tabs.active'), icon: Smartphone },
          { to: 'account-billing', label: t('account.tabs.billing'), icon: CreditCard },
          { to: 'account-pro', label: t('account.tabs.pro'), icon: Sparkles },
          { to: 'account-statements', label: t('account.tabs.statements'), icon: FileText },
          { to: 'account-analytics', label: t('account.analytics.title'), icon: BarChart3 },
          { to: 'account-ai-provider', label: t('aiUserProvider.title'), icon: Bot }
        ]"
        :key="item.to"
        :to="localePath(item.to)"
        class="flex items-center gap-2.5 rounded-2xl bg-secondary/60 px-3.5 py-3 text-[13px] font-medium text-foreground transition-colors hover:bg-secondary"
      >
        <component :is="item.icon" class="size-4 shrink-0 text-primary" />
        <span class="truncate">{{ item.label }}</span>
      </NuxtLink>
    </div>
  </section>
  </div>
</template>
