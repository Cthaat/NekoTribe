<!-- 文件路径: pages/user/[id]/profile.vue -->
<script setup lang="ts">
import { Button } from '@/components/ui/button';
import { apiFetch } from '@/composables/useApi';
import { useApiFetch } from '@/composables/useApiFetch';
import { toast } from 'vue-sonner';
import { Progress } from '@/components/ui/progress';
import { useI18n } from 'vue-i18n';
import { Separator } from '@/components/ui/separator';
import ProfileForm from '@/components/ProfileForm.vue';
import { usePreferenceStore } from '~/stores/user'; // 导入 store
import { onMounted, ref, computed, watch } from 'vue';
import { Card, CardContent } from '@/components/ui/card';
import { useRoute } from 'vue-router';
import TweetList from '@/components/TweetList.vue';
import TweetCardSkeleton from '@/components/TweetCardSkeleton.vue';
import {
  Pagination,
  PaginationContent,
  PaginationEllipsis,
  PaginationItem,
  PaginationNext,
  PaginationPrevious
} from '@/components/ui/pagination';

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

// 推文列表相关状态
const page = ref(1);
const pageSize = ref(10);
const fullTweets = ref<any[]>([]);
const detailsPending = ref(false);
const detailsError = ref<unknown>(null);

// 获取用户推文列表
interface TweetListApiResponse {
  data?: {
    tweets?: any[];
    totalCount?: number;
  };
}

const {
  data: listApiResponse,
  pending: listPending,
  error: listError,
  refresh: refreshTweetList
} = useApiFetch<TweetListApiResponse>(
  '/api/v1/tweets/list',
  {
    query: {
      type: 'user',
      userId: userId,
      page: page,
      pageSize: pageSize
    },
    watch: [page]
  }
);

// 获取推文详情
watch(
  listApiResponse,
  async newListApiResponse => {
    if (listError.value) {
      fullTweets.value = [];
      return;
    }
    if (!newListApiResponse?.data?.tweets) {
      fullTweets.value = [];
      return;
    }

    try {
      detailsPending.value = true;
      detailsError.value = null;
      fullTweets.value = [];

      const basicTweets = newListApiResponse.data.tweets;

      const detailPromises = basicTweets.map(basicTweet => {
        return apiFetch(
          `/api/v1/tweets/${basicTweet.tweetId}`
        );
      });

      const detailResponses =
        await Promise.all(detailPromises);

      fullTweets.value = detailResponses.map(
        (response: any, index: number) => ({
          ...response.data.tweet,
          isLikedByUser: basicTweets[index].isLikedByUser,
          isBookmarkedByUser:
            basicTweets[index].isBookmarkedByUser
        })
      );
    } catch (err) {
      console.error('Error fetching tweet details:', err);
      detailsError.value = err as Error;
      if (process.client) {
        toast.error('加载推文详情失败');
      }
    } finally {
      detailsPending.value = false;
    }
  },
  { immediate: true }
);

const isLoadingTweets = computed(
  () => listPending.value || detailsPending.value
);

const totalTweetsCount = computed(
  () => listApiResponse.value?.data?.totalCount || 0
);

const totalPages = computed(() =>
  Math.ceil(totalTweetsCount.value / pageSize.value)
);

// 推文操作处理
async function handleDeleteTweet(tweetId: any) {
  console.log('Deleting tweet:', tweetId);
  const response: any = await apiFetch(
    `/api/v1/tweets/${tweetId}`,
    {
      method: 'DELETE'
    }
  );
  if (!response.success) {
    toast.error('删除推文失败');
    return;
  }
  toast.success('推文已删除');
  fullTweets.value = fullTweets.value.filter(
    tweet => tweet.tweetId !== tweetId
  );
}

function handleReplyTweet(tweet: any) {
  const localePath = useLocalePath();
  const detailPage = localePath(`/tweet/${tweet.tweetId}`);
  return navigateTo(detailPage);
}

async function handleRetweetTweet(tweet: any) {
  console.log('Retweeting:', tweet.tweetId);
  // 转发逻辑
}

async function handleLikeTweet(tweet: any, action: string) {
  try {
    const response: any = await apiFetch(
      '/api/v1/interactions/like',
      {
        method: 'POST',
        body: {
          tweetId: tweet.tweetId,
          action: action
        }
      }
    );
    if (response.success) {
      const index = fullTweets.value.findIndex(
        t => t.tweetId === tweet.tweetId
      );
      if (index !== -1) {
        fullTweets.value[index].isLikedByUser =
          action === 'like';
        fullTweets.value[index].likesCount +=
          action === 'like' ? 1 : -1;
      }
    }
  } catch (error) {
    console.error('Error liking tweet:', error);
    toast.error('操作失败');
  }
}

async function handleBookmarkTweet(
  tweet: any,
  action: string
) {
  try {
    const response: any = await apiFetch(
      '/api/v1/interactions/bookmark',
      {
        method: 'POST',
        body: {
          tweetId: tweet.tweetId,
          action: action
        }
      }
    );
    if (response.success) {
      const index = fullTweets.value.findIndex(
        t => t.tweetId === tweet.tweetId
      );
      if (index !== -1) {
        fullTweets.value[index].isBookmarkedByUser =
          action === 'bookmark';
      }
    }
  } catch (error) {
    console.error('Error bookmarking tweet:', error);
    toast.error('操作失败');
  }
}

function goToPage(newPage: number) {
  if (newPage >= 1 && newPage <= totalPages.value) {
    page.value = newPage;
    // 滚动到顶部
    if (process.client) {
      window.scrollTo({ top: 0, behavior: 'smooth' });
    }
  }
}

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

    <!-- 用户统计概览 -->
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

    <!-- 用户推文列表 -->
    <Card>
      <CardContent class="p-0">
        <div class="space-y-4">
          <div class="p-6 pb-4">
            <h2 class="text-2xl font-bold tracking-tight">
              推文
            </h2>
            <p class="text-muted-foreground">
              共 {{ totalTweetsCount }} 条推文
            </p>
          </div>

          <Separator />

          <!-- 加载状态 -->
          <div v-if="isLoadingTweets" class="space-y-4 p-4">
            <TweetCardSkeleton v-for="i in 3" :key="i" />
          </div>

          <!-- 推文列表 -->
          <div v-else-if="fullTweets.length > 0">
            <TweetList
              :tweets="fullTweets"
              @delete-tweet="handleDeleteTweet"
              @reply-tweet="handleReplyTweet"
              @retweet-tweet="handleRetweetTweet"
              @like-tweet="handleLikeTweet"
              @bookmark-tweet="handleBookmarkTweet"
            />
          </div>

          <!-- 空状态 -->
          <div
            v-else
            class="p-12 text-center text-muted-foreground"
          >
            <p class="text-lg">该用户还没有发布任何推文</p>
          </div>

          <!-- 分页 -->
          <div v-if="totalPages > 1" class="p-6 pt-4">
            <Pagination
              v-model:page="page"
              :items-per-page="pageSize"
              :total="totalTweetsCount"
              class="flex justify-center"
            >
              <PaginationContent v-slot="{ items }">
                <PaginationPrevious />
                <template
                  v-for="(item, index) in items"
                  :key="index"
                >
                  <PaginationItem
                    v-if="item.type === 'page'"
                    :value="item.value"
                    :is-active="item.value === page"
                  >
                    {{ item.value }}
                  </PaginationItem>
                </template>
                <PaginationNext />
              </PaginationContent>
            </Pagination>
          </div>
        </div>
      </CardContent>
    </Card>
  </div>
</template>
