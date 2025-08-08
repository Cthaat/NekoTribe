<!-- 文件路径: pages/account.vue -->
<script setup lang="ts">
import { Button } from '@/components/ui/button';
import { apiFetch } from '@/composables/useApi';
import { toast } from 'vue-sonner';
import { Progress } from '@/components/ui/progress';
import { useI18n } from 'vue-i18n';
import { Separator } from '@/components/ui/separator';
import ProfileForm from '@/components/ProfileForm.vue';
import { usePreferenceStore } from '~/stores/user'; // 导入 store
import { onMounted, ref } from 'vue';
import { Card, CardContent } from '@/components/ui/card';
import { useRoute } from 'vue-router';
import { id } from 'zod/v4/locales';

const route = useRoute();

const preferenceStore = usePreferenceStore();

// 1. 获取 i18n 的工具函数
const { t } = useI18n();

const localePath = useLocalePath();

// 假设这是从 API 获取的用户数据
const user = ref({
  id: 0,
  name: '',
  title: '',
  location: '',
  email: '',
  avatar: '',
  follow: '',
  stats: {
    followersCount: 0,
    followingCount: 0,
    likesCount: 0
  },
  point: 50
});

// TODO: 修改组件，让这部分可选，而不是使用空数组
const baseAccountTabs: Array<{ name: string; to: string }> =
  [];

// 3. ✨ 创建一个 computed 属性来生成最终给模板使用的数据
const localizedAccountTabs = computed(() => {
  return baseAccountTabs.map(tab => ({
    // ✨ 使用 t() 函数来翻译名称
    name: t(tab.name),
    // ✨ 使用 localePath() 函数来本地化链接
    to: localePath(tab.to)
  }));
});

const activeTab = ref('Overview');

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

const userId = route.params.id;

onMounted(async () => {
  try {
    const response = (await apiFetch(
      `/api/v1/analytics/users/${userId}/stats`,
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

  // TODO: 更新后端，获取更多数据
  try {
    const response = (await apiFetch(
      `/api/v1/users/${userId}`,
      {
        method: 'GET'
      }
    )) as { data?: { userData?: { userInfo?: any } } };

    user.value.id =
      response.data?.userData?.userInfo?.userId || 0;
    user.value.name =
      response.data?.userData?.userInfo?.displayName || '';
    user.value.location =
      response.data?.userData?.userInfo?.location || '';
    user.value.avatar =
      response.data?.userData?.userInfo?.avatarUrl || '';

    console.log('Fetched user info:', user);
  } catch (error) {
    console.error('Error fetching user info:', error);
    toast.error('Failed to fetch user info.');
  }

  try {
    const response = (await apiFetch(
      `/api/v1/users/${userId}/stats`,
      {
        method: 'GET'
      }
    )) as { data?: { userData?: { userInfo?: any } } };

    user.value.stats.followersCount =
      response.data?.userData?.userInfo?.followersCount ||
      0;
    user.value.stats.followingCount =
      response.data?.userData?.userInfo?.followingCount ||
      0;
    user.value.stats.likesCount =
      response.data?.userData?.userInfo?.likesCount || 0;

    console.log('Fetched user info analytics:', user);
  } catch (error) {
    console.error('Error fetching user info:', error);
    toast.error('Failed to fetch user info.');
  }

  try {
    const response = (await apiFetch(
      `/api/v1/analytics/users/${userId}/stats`,
      {
        method: 'GET'
      }
    )) as { data?: { user?: any } };

    user.value.point =
      response.data?.user.engagementScore || 0;
  } catch (error) {
    console.error('Error fetching user analytics:', error);
    toast.error('Failed to fetch user analytics.');
  }

  try {
    const response = (await apiFetch(
      `/api/v1/users/${userId}/isfollow`,
      {
        method: 'GET'
      }
    )) as { data?: { isFollowing?: boolean } };

    user.value.follow = response.data?.isFollowing
      ? 'Follow'
      : 'Unfollow';

    console.log('User follow status:', user.value.follow);
  } catch (error) {
    console.error(
      'Error fetching user follow status:',
      error
    );
    toast.error('Failed to fetch user follow status.');
  }
});

async function followUser(user: any, active: string) {
  console.log(`Attempting to ${active} user:`, user.name);
  try {
    const response: any = (await apiFetch(
      `/api/v1/follow/action`,
      {
        method: 'POST',
        body: {
          userId: user.id,
          action: active
        }
      }
    )) as { data?: { user?: any } };
    if (response.success) {
      toast.success(
        `Successfully ${active}ed ${user.name}.`
      );
    } else {
      toast.error('Failed to update follow status.');
    }
  } catch (error) {
    console.error('Error following user:', error);
    toast.error('Failed to follow user.');
  }
}
</script>

<template>
  <div class="p-4 sm:p-6 lg:p-8 space-y-8">
    <AccountHeaderCard
      :user="user"
      :account-tabs="localizedAccountTabs"
      v-model="activeTab"
      @follow="followUser"
    />
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
  </div>
</template>
