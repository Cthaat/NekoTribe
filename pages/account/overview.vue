<script setup lang="ts">
import { Separator } from '@/components/ui/separator';
import ProfileForm from '@/components/ProfileForm.vue';
import { apiFetch } from '@/composables/useApi';
import { usePreferenceStore } from '~/stores/user'; // 导入 store
import { onMounted, ref } from 'vue';
import { Card, CardContent } from '@/components/ui/card';
import { toast } from 'vue-sonner';

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
    const response = (await apiFetch(
      `/api/v1/analytics/users/${preferenceStore.preferences.user.userId}/stats`,
      {
        method: 'GET'
      }
    )) as { data?: { user?: any } };

    userAnalytics.value.totalTweets =
      response.data?.user.totalTweets || 0;
    userAnalytics.value.tweetsThisWeek =
      response.data?.user.tweetsThisWeek || 0;
    userAnalytics.value.totalLikesReceived =
      response.data?.user.totalLikesReceived || 0;
    userAnalytics.value.avgLikesPerTweet =
      response.data?.user.avgLikesPerTweet || 0;
    userAnalytics.value.totalLikesGiven =
      response.data?.user.totalLikesGiven || 0;
    userAnalytics.value.totalCommentsMade =
      response.data?.user.totalCommentsMade || 0;
    userAnalytics.value.engagementScore =
      response.data?.user.engagementScore || 0;

    console.log(
      'Fetched user analytics:',
      userAnalytics.value
    );
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
            Overview
          </h2>
          <p class="text-muted-foreground">
            This is an overview of your account settings and
            information.
          </p>
        </div>
        <Separator class="my-6" />
        <OverAllPanel :userAnalytics="userAnalytics" />
      </div>
    </CardContent>
  </Card>
</template>
