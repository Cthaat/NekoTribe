<script setup lang="ts">
import { Separator } from '@/components/ui/separator';
import ProfileForm from '@/components/ProfileForm.vue';
import { v2GetUserAnalytics } from '@/services';
import { usePreferenceStore } from '~/stores/user'; // 导入 store
import { onMounted, ref } from 'vue';
import { Card, CardContent } from '@/components/ui/card';
import { toast } from 'vue-sonner';
import { useI18n } from 'vue-i18n';

const { t } = useI18n();

const preferenceStore = usePreferenceStore();

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

onMounted(async () => {
  try {
    const analytics = await v2GetUserAnalytics(
      preferenceStore.preferences.user.user_id
    );
    userAnalytics.value.totalTweets = analytics.total_posts;
    userAnalytics.value.tweetsThisWeek =
      analytics.posts_this_week;
    userAnalytics.value.totalLikesReceived =
      analytics.total_likes_received;
    userAnalytics.value.avgLikesPerTweet =
      analytics.avg_likes_per_post;
    userAnalytics.value.totalLikesGiven =
      analytics.total_likes_given;
    userAnalytics.value.totalCommentsMade =
      analytics.total_comments_made;
    userAnalytics.value.engagementScore =
      analytics.engagement_score;
  } catch (error) {
    console.error('Error fetching user analytics:', error);
    toast.error('Failed to fetch user analytics.');
  }
});
</script>

<template>
  <Card>
    <CardContent>
      <div class="hidden space-y-6 p-8 pb-16 md:block">
        <div class="space-y-0.5">
          <h2 class="text-2xl font-bold tracking-tight">
            {{ $t('account.overview.title') }}
          </h2>
          <p class="text-muted-foreground">
            {{ $t('account.overview.description') }}
          </p>
        </div>
        <Separator class="my-6" />
        <OverAllPanel :userAnalytics="userAnalytics" />
      </div>
    </CardContent>
  </Card>
</template>

