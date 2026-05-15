<script setup lang="ts">
import { Separator } from '@/components/ui/separator';
import ProfileForm from '@/components/ProfileForm.vue';
import {
  v2GetMe,
  v2GetUserAnalytics,
  v2GetUserDailyAnalytics
} from '@/services';
import { onMounted, ref } from 'vue';
import { Card, CardContent } from '@/components/ui/card';
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
  } catch (error) {
    console.error(t('account.errors.loadAnalytics'), error);
    toast.error(t('account.errors.loadAnalytics'));
  }
});
</script>

<template>
  <Card>
    <CardContent>
      <div class="hidden space-y-6 p-8 pb-16 md:block">
        <div class="space-y-0.5">
          <h2 class="text-2xl font-bold tracking-tight">
            {{ t('account.overview.title') }}
          </h2>
          <p class="text-muted-foreground">
            {{ t('account.overview.description') }}
          </p>
        </div>
        <Separator class="my-6" />
        <OverAllPanel
          :userAnalytics="userAnalytics"
          :dailyAnalytics="dailyAnalytics"
        />
      </div>
    </CardContent>
  </Card>
</template>

