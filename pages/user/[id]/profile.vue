<!-- 文件路径: pages/user/[id]/profile.vue -->
<script setup lang="ts">
import { Button } from '@/components/ui/button';
import { apiFetch } from '@/composables/useApi';
import { useApiFetch } from '@/composables/useApiFetch';
import { toast } from 'vue-sonner';
import { useI18n } from 'vue-i18n';
import { Separator } from '@/components/ui/separator';
import { usePreferenceStore } from '~/stores/user';
import { onMounted, ref, watch, computed } from 'vue';
import { Card, CardContent } from '@/components/ui/card';
import { useRoute } from 'vue-router';
import TweetList from '@/components/TweetList.vue';
import TweetCardSkeleton from '@/components/TweetCardSkeleton.vue';
import {
  Pagination,
  PaginationContent,
  PaginationItem,
  PaginationNext,
  PaginationPrevious
} from '@/components/ui/pagination';

const route = useRoute();

const preferenceStore = usePreferenceStore();

const { t } = useI18n();

const localePath = useLocalePath();

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

const baseAccountTabs: Array<{ name: string; to: string }> =
  [];

const localizedAccountTabs = computed(() => {
  return baseAccountTabs.map(tab => ({
    name: t(tab.name),
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

// --- Tweets section ---
const page = ref(1);
const pageSize = ref(10);
const fullTweets = ref<any[]>([]);
const detailsPending = ref(false);
const detailsError = ref<unknown>(null);

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
  refresh: refreshTweets
} = useApiFetch<TweetListApiResponse>('/api/v1/tweets/list', {
  query: {
    type: 'user',
    userId: userId,
    page: page,
    pageSize: pageSize
  },
  watch: [page]
});

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
        toast.error(t('userProfile.tweets.loadError'));
      }
    } finally {
      detailsPending.value = false;
    }
  },
  { immediate: true }
);

const isTweetsLoading = computed(
  () => listPending.value || detailsPending.value
);
const hasTweetsError = computed(
  () => !!listError.value || !!detailsError.value
);
const totalCount = computed(
  () => listApiResponse.value?.data?.totalCount || 0
);

// --- Tweet interactions ---
async function handleDeleteTweet(tweetId: any) {
  const response: any = await apiFetch(
    `/api/v1/tweets/${tweetId}`,
    {
      method: 'DELETE'
    }
  );
  if (!response.success) {
    toast.error(t('userProfile.tweets.deleteError'), {
      description: response.error || ''
    });
    return;
  }
  toast.success(t('userProfile.tweets.deleteSuccess'));
  fullTweets.value = fullTweets.value.filter(
    tweet => tweet.tweetId !== tweetId
  );
}

function handleReplyTweet(tweet: any) {
  const detailPage = localePath(`/tweet/${tweet.tweetId}`);
  return navigateTo(detailPage, { replace: true });
}

const isRetweetModalOpen = ref(false);
const selectedTweetForRetweet = ref(null);
const isSubmittingRetweet = ref(false);

function handleRetweetTweet(tweet: any) {
  selectedTweetForRetweet.value = tweet;
  isRetweetModalOpen.value = true;
}

async function handleSubmitRetweet({
  content,
  originalTweetId
}: {
  content: any;
  originalTweetId: any;
}) {
  isSubmittingRetweet.value = true;
  try {
    const response: any = await apiFetch(
      '/api/v1/tweets/send-tweets',
      {
        method: 'POST',
        body: {
          content: content,
          replyToTweetId: '',
          retweetOfTweetId: originalTweetId,
          quoteTweetId: '',
          visibility: 'public',
          hashtags: '',
          mentions: '',
          scheduledAt: '',
          location: ''
        }
      }
    );

    toast.success(t('userProfile.tweets.retweetSuccess'));

    if (!response.success) {
      throw new Error(response.message || t('userProfile.tweets.retweetError'));
    }
  } catch (err: any) {
    console.error('Failed to retweet:', err);
    toast.error(err.message || t('userProfile.tweets.retweetError'));
  } finally {
    isSubmittingRetweet.value = false;
    isRetweetModalOpen.value = false;
  }
}

async function handleLikeTweet(
  tweet: any,
  action: 'like' | 'unlike'
) {
  const response: any = await apiFetch(
    '/api/v1/interactions/like',
    {
      method: 'POST',
      body: {
        tweetId: tweet.tweetId,
        likeType: action
      }
    }
  );
  if (!response.success) {
    console.error(
      'Failed to like/unlike tweet:',
      response.error
    );
  }
}

async function handleBookmarkTweet(
  tweet: any,
  action: 'mark' | 'unmark'
) {
  const response: any = await apiFetch(
    '/api/v1/interactions/bookmark',
    {
      method: 'POST',
      body: {
        tweetId: tweet.tweetId,
        bookmarkType: action
      }
    }
  );
  if (!response.success) {
    console.error(
      'Failed to bookmark/unbookmark tweet:',
      response.error
    );
  }
}

// --- User data fetching ---
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

    <!-- User Tweets Section -->
    <Card>
      <CardContent>
        <div class="space-y-6 p-4 sm:p-8">
          <div class="space-y-0.5">
            <h2 class="text-2xl font-bold tracking-tight">
              {{ $t('userProfile.tweets.title') }}
            </h2>
            <p class="text-muted-foreground">
              {{ $t('userProfile.tweets.description') }}
            </p>
          </div>
          <Separator class="my-6" />

          <!-- Loading state -->
          <div v-if="isTweetsLoading" class="space-y-4">
            <TweetCardSkeleton
              v-for="i in 3"
              :key="`skeleton-${i}`"
            />
          </div>

          <!-- Error state -->
          <div
            v-else-if="hasTweetsError"
            class="text-center text-destructive py-8"
          >
            {{ $t('userProfile.tweets.loadError') }}
          </div>

          <!-- Tweets list -->
          <TweetList
            v-else-if="fullTweets.length > 0"
            :tweets="fullTweets"
            @delete-tweet="handleDeleteTweet"
            @reply-tweet="handleReplyTweet"
            @retweet-tweet="handleRetweetTweet"
            @like-tweet="handleLikeTweet"
            @bookmark-tweet="handleBookmarkTweet"
          />

          <!-- Empty state -->
          <div
            v-else
            class="text-center text-muted-foreground py-10"
          >
            {{ $t('userProfile.tweets.empty') }}
          </div>

          <!-- Pagination -->
          <Pagination
            v-if="!listPending && !listError && totalCount > 0"
            v-model:page="page"
            :items-per-page="pageSize"
            :total="totalCount"
            class="mt-8 flex justify-center"
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
      </CardContent>
    </Card>

    <!-- Retweet Modal -->
    <RetweetModal
      v-if="selectedTweetForRetweet"
      v-model:open="isRetweetModalOpen"
      :tweet="selectedTweetForRetweet"
      :is-submitting="isSubmittingRetweet"
      @submit-retweet="handleSubmitRetweet"
    />
  </div>
</template>
