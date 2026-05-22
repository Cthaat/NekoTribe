<script setup lang="ts">
import {
  v2GetMe,
  v2GetUserAnalytics,
  v2GetUserDailyAnalytics
} from '@/services';
import { onMounted, ref } from 'vue';
import { BarChart3 } from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import type { UserDailyAnalyticsVM } from '@/types/users';

const { t } = useAppLocale();

interface UserAnalyticsData {
  totalTweets: number;
  tweetsThisWeek: number;
  totalLikesReceived: number;
  avgLikesPerTweet: number;
  totalLikesGiven: number;
  totalCommentsMade: number;
  engagementScore: number;
}

const userAnalytics = ref<UserAnalyticsData>({
  totalTweets: 0,
  tweetsThisWeek: 0,
  totalLikesReceived: 0,
  avgLikesPerTweet: 0,
  totalLikesGiven: 0,
  totalCommentsMade: 0,
  engagementScore: 0
});
const dailyAnalytics = ref<UserDailyAnalyticsVM[]>([]);

onMounted(async () => {
  try {
    const me = await v2GetMe();
    const [analytics, daily] = await Promise.all([
      v2GetUserAnalytics(me.id),
      v2GetUserDailyAnalytics(me.id, { days: 14 })
    ]);
    userAnalytics.value.totalTweets = analytics.totalPosts;
    userAnalytics.value.tweetsThisWeek =
      analytics.postsThisWeek;
    userAnalytics.value.totalLikesReceived =
      analytics.totalLikesReceived;
    userAnalytics.value.avgLikesPerTweet =
      analytics.avgLikesPerPost;
    userAnalytics.value.totalLikesGiven =
      analytics.totalLikesGiven;
    userAnalytics.value.totalCommentsMade =
      analytics.totalCommentsMade;
    userAnalytics.value.engagementScore =
      analytics.engagementScore;
    dailyAnalytics.value = daily;
  } catch {
    toast.error(t('account.errors.loadAnalytics'));
  }
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
    <OverAllPanel
      :userAnalytics="userAnalytics"
      :dailyAnalytics="dailyAnalytics"
    />
  </section>
</template>
