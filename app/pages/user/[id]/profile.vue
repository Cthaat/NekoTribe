<script setup lang="ts">
import { Separator } from '@/components/ui/separator';
import { onMounted, ref, computed, watch } from 'vue';
import { Card, CardContent } from '@/components/ui/card';
import TweetList from '@/components/TweetList.vue';
import TweetCardSkeleton from '@/components/TweetCardSkeleton.vue';
import {
  Pagination,
  PaginationContent,
  PaginationItem,
  PaginationNext,
  PaginationPrevious
} from '@/components/ui/pagination';
import { toast } from 'vue-sonner';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import type { V2Post } from '@/types/v2';
import {
  v2BookmarkPost,
  v2DeletePost,
  v2FollowUser,
  v2GetUserAnalytics,
  v2GetUserById,
  v2LikePost,
  v2ListUserPosts,
  v2UnlikePost,
  v2UnbookmarkPost,
  v2UnfollowUser
} from '@/services';

const route = useRoute();
const { t } = useI18n();
const localePath = useLocalePath();

interface AccountHeaderUser {
  id: number;
  name: string;
  title: string;
  location: string;
  email: string;
  avatar: string;
  follow: string;
  stats: {
    followersCount: number;
    followingCount: number;
    likesCount: number;
  };
  point: number;
}

interface UserAnalyticsData {
  totalTweets: number;
  tweetsThisWeek: number;
  totalLikesReceived: number;
  avgLikesPerTweet: number;
  totalLikesGiven: number;
  totalCommentsMade: number;
  engagementScore: number;
}

const user = ref<AccountHeaderUser>({
  id: 0,
  name: '',
  title: '',
  location: '',
  email: '',
  avatar: '',
  follow: 'Unfollow',
  stats: {
    followersCount: 0,
    followingCount: 0,
    likesCount: 0
  },
  point: 0
});

const baseAccountTabs: Array<{ name: string; to: string }> = [];
const localizedAccountTabs = computed(() => {
  return baseAccountTabs.map(tab => ({
    name: t(tab.name),
    to: localePath(tab.to)
  }));
});
const activeTab = ref('Overview');

const userAnalytics = ref<UserAnalyticsData>({
  totalTweets: 0,
  tweetsThisWeek: 0,
  totalLikesReceived: 0,
  avgLikesPerTweet: 0,
  totalLikesGiven: 0,
  totalCommentsMade: 0,
  engagementScore: 0
});

const userId = computed(() => Number(route.params.id || 0));

const page = ref(1);
const pageSize = ref(10);
const fullTweets = ref<V2Post[]>([]);
const tweetsLoading = ref(false);
const tweetsError = ref<string | null>(null);
const totalTweetsCount = ref(0);

const totalPages = computed(() =>
  Math.max(1, Math.ceil(totalTweetsCount.value / pageSize.value))
);

async function loadUserProfile() {
  try {
    const publicUser = await v2GetUserById(userId.value);
    user.value.id = publicUser.user_id;
    user.value.name = publicUser.display_name;
    user.value.title = publicUser.username;
    user.value.location = publicUser.location;
    user.value.avatar = publicUser.avatar_url;
    user.value.stats.followersCount =
      publicUser.followers_count;
    user.value.stats.followingCount =
      publicUser.following_count;
    user.value.stats.likesCount = publicUser.likes_count;
    user.value.follow = publicUser.relationship.is_following
      ? 'Follow'
      : 'Unfollow';
  } catch (error) {
    console.error('Error fetching user info:', error);
    toast.error('Failed to fetch user info.');
  }
}

async function loadUserAnalytics() {
  try {
    const analytics = await v2GetUserAnalytics(userId.value);
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
    user.value.point = analytics.engagement_score;
  } catch (error) {
    console.error('Error fetching user analytics:', error);
    toast.error('Failed to fetch user analytics.');
  }
}

async function loadTweets() {
  tweetsLoading.value = true;
  tweetsError.value = null;
  try {
    const result = await v2ListUserPosts(userId.value, {
      page: page.value,
      page_size: pageSize.value,
      sort: 'newest'
    });
    fullTweets.value = result.items;
    totalTweetsCount.value =
      result.meta?.total || result.items.length;
  } catch (error) {
    console.error('Error fetching tweets:', error);
    tweetsError.value =
      error instanceof Error ? error.message : '加载推文失败';
    fullTweets.value = [];
    totalTweetsCount.value = 0;
  } finally {
    tweetsLoading.value = false;
  }
}

watch(page, () => {
  loadTweets();
});

onMounted(async () => {
  await Promise.all([
    loadUserProfile(),
    loadUserAnalytics(),
    loadTweets()
  ]);
});

async function handleDeleteTweet(tweetId: number) {
  try {
    await v2DeletePost(tweetId);
    toast.success('推文已删除');
    fullTweets.value = fullTweets.value.filter(
      tweet => tweet.post_id !== tweetId
    );
    totalTweetsCount.value = Math.max(totalTweetsCount.value - 1, 0);
  } catch (error) {
    console.error('Error deleting tweet:', error);
    toast.error('删除推文失败');
  }
}

function handleReplyTweet(tweet: V2Post) {
  const detailPage = localePath(`/tweet/${tweet.post_id}`);
  return navigateTo(detailPage);
}

function handleRetweetTweet(tweet: V2Post) {
  const detailPage = localePath(`/tweet/${tweet.post_id}`);
  return navigateTo(detailPage);
}

async function handleLikeTweet(
  tweet: V2Post,
  action: 'like' | 'unlike'
) {
  try {
    const result =
      action === 'like'
        ? await v2LikePost(tweet.post_id)
        : await v2UnlikePost(tweet.post_id);
    const index = fullTweets.value.findIndex(
      item => item.post_id === tweet.post_id
    );
    if (index !== -1) {
      fullTweets.value[index].viewer_state.is_liked =
        result.is_liked;
      fullTweets.value[index].stats.likes_count =
        result.likes_count;
    }
  } catch (error) {
    console.error('Error liking tweet:', error);
    toast.error('操作失败');
  }
}

async function handleBookmarkTweet(
  tweet: V2Post,
  action: 'mark' | 'unmark'
) {
  try {
    const result =
      action === 'mark'
        ? await v2BookmarkPost(tweet.post_id)
        : await v2UnbookmarkPost(tweet.post_id);
    const index = fullTweets.value.findIndex(
      item => item.post_id === tweet.post_id
    );
    if (index !== -1) {
      fullTweets.value[index].viewer_state.is_bookmarked =
        result.is_bookmarked;
    }
  } catch (error) {
    console.error('Error bookmarking tweet:', error);
    toast.error('操作失败');
  }
}

function goToPage(newPage: number) {
  if (newPage >= 1 && newPage <= totalPages.value) {
    page.value = newPage;
    if (process.client) {
      window.scrollTo({ top: 0, behavior: 'smooth' });
    }
  }
}

async function followUser(targetUser: AccountHeaderUser, active: string) {
  try {
    const result =
      active === 'follow'
        ? await v2FollowUser(targetUser.id)
        : await v2UnfollowUser(targetUser.id);
    user.value.follow =
      result.relationship === 'following'
        ? 'Follow'
        : 'Unfollow';
    user.value.stats.followersCount = result.followers_count;
    toast.success(
      `Successfully ${active}ed ${targetUser.name}.`
    );
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

          <div
            v-if="tweetsLoading"
            class="space-y-4 p-4"
          >
            <TweetCardSkeleton v-for="i in 3" :key="i" />
          </div>

          <div
            v-else-if="tweetsError"
            class="p-12 text-center text-destructive"
          >
            <p>{{ tweetsError }}</p>
          </div>

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

          <div
            v-else
            class="p-12 text-center text-muted-foreground"
          >
            <p class="text-lg">该用户还没有发布任何推文</p>
          </div>

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


