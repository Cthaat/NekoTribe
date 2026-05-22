<script setup lang="ts">
import { onMounted, ref, computed, watch } from 'vue';
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
import { useRoute } from 'vue-router';
import { BarChart3, FileText, Inbox, AlertTriangle } from 'lucide-vue-next';
import type { PostVM } from '@/types/posts';
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
const { t } = useAppLocale();
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
  onlineStatus: 'online' | 'offline' | 'hidden';
  lastSeenAt: string | null;
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
  follow: 'unfollow',
  stats: {
    followersCount: 0,
    followingCount: 0,
    likesCount: 0
  },
  point: 0,
  onlineStatus: 'hidden',
  lastSeenAt: null
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
const fullTweets = ref<PostVM[]>([]);
const tweetsLoading = ref(false);
const tweetsError = ref<string | null>(null);
const totalTweetsCount = ref(0);

const totalPages = computed(() =>
  Math.max(1, Math.ceil(totalTweetsCount.value / pageSize.value))
);

async function loadUserProfile() {
  try {
    const publicUser = await v2GetUserById(userId.value);
    user.value.id = publicUser.id;
    user.value.name = publicUser.name;
    user.value.title = publicUser.username;
    user.value.location = publicUser.location;
    user.value.avatar = publicUser.avatarUrl;
    user.value.onlineStatus = publicUser.onlineStatus;
    user.value.lastSeenAt = publicUser.lastSeenAt;
    user.value.stats.followersCount =
      publicUser.followersCount;
    user.value.stats.followingCount =
      publicUser.followingCount;
    user.value.stats.likesCount = publicUser.likesCount;
    user.value.follow = publicUser.relationship.isFollowing
      ? 'follow'
      : 'unfollow';
  } catch {
    toast.error(t('account.errors.loadUser'));
  }
}

async function loadUserAnalytics() {
  try {
    const analytics = await v2GetUserAnalytics(userId.value);
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
    user.value.point = analytics.engagementScore;
  } catch {
    toast.error(t('account.errors.loadAnalytics'));
  }
}

async function loadTweets() {
  tweetsLoading.value = true;
  tweetsError.value = null;
  try {
    const result = await v2ListUserPosts(userId.value, {
      page: page.value,
      pageSize: pageSize.value,
      sort: 'newest'
    });
    fullTweets.value = result.items;
    totalTweetsCount.value = result.total;
  } catch (error) {
    tweetsError.value =
      error instanceof Error
        ? error.message
        : t('post.feed.loadFailed');
    fullTweets.value = [];
    totalTweetsCount.value = 0;
  } finally {
    tweetsLoading.value = false;
  }
}

watch(page, () => {
  void loadTweets();
});

async function refreshProfilePage(): Promise<void> {
  await Promise.all([
    loadUserProfile(),
    loadUserAnalytics(),
    loadTweets()
  ]);
}

onMounted(() => {
  void refreshProfilePage();
});

async function handleDeleteTweet(tweetId: number) {
  try {
    await v2DeletePost(tweetId);
    toast.success(t('post.feedback.deleted'));
    fullTweets.value = fullTweets.value.filter(
      tweet => tweet.id !== tweetId
    );
    totalTweetsCount.value = Math.max(totalTweetsCount.value - 1, 0);
  } catch {
    toast.error(t('post.feedback.deleteFailed'));
  }
}

function handleReplyTweet(tweet: PostVM) {
  const detailPage = localePath(`/tweet/${tweet.id}`);
  return navigateTo(detailPage);
}

function handleRetweetTweet(tweet: PostVM) {
  const detailPage = localePath(`/tweet/${tweet.id}`);
  return navigateTo(detailPage);
}

async function handleLikeTweet(
  tweet: PostVM,
  action: 'like' | 'unlike'
) {
  try {
    const result =
      action === 'like'
        ? await v2LikePost(tweet.id)
        : await v2UnlikePost(tweet.id);
    const index = fullTweets.value.findIndex(
      item => item.id === tweet.id
    );
    if (index !== -1) {
      const currentTweet = fullTweets.value[index];
      if (!currentTweet) return;
      fullTweets.value[index] = {
        ...currentTweet,
        viewer: {
          ...currentTweet.viewer,
          hasLiked: result.isLiked
        },
        counts: {
          ...currentTweet.counts,
          likes: result.likesCount
        }
      };
    }
  } catch {
    toast.error(t('common.operationFailed'));
  }
}

async function handleBookmarkTweet(
  tweet: PostVM,
  action: 'mark' | 'unmark'
) {
  try {
    const result =
      action === 'mark'
        ? await v2BookmarkPost(tweet.id)
        : await v2UnbookmarkPost(tweet.id);
    const index = fullTweets.value.findIndex(
      item => item.id === tweet.id
    );
    if (index !== -1) {
      const currentTweet = fullTweets.value[index];
      if (!currentTweet) return;
      fullTweets.value[index] = {
        ...currentTweet,
        viewer: {
          ...currentTweet.viewer,
          hasBookmarked: result.isBookmarked
        }
      };
    }
  } catch {
    toast.error(t('common.operationFailed'));
  }
}

function goToPage(newPage: number) {
  if (newPage >= 1 && newPage <= totalPages.value) {
    page.value = newPage;
    if (import.meta.client) {
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
        ? 'follow'
        : 'unfollow';
    user.value.stats.followersCount = result.followersCount;
    toast.success(
      t(
        active === 'follow'
          ? 'account.follow.success'
          : 'account.follow.unfollowSuccess',
        { name: targetUser.name }
      )
    );
  } catch {
    toast.error(t('account.follow.failed'));
  }
}
</script>

<template>
  <div class="grid gap-6 p-4 sm:p-6 lg:p-8">
    <AccountHeaderCard
      :user="user"
      :account-tabs="localizedAccountTabs"
      v-model="activeTab"
      @follow="followUser"
      @refresh="refreshProfilePage"
    />

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
      <OverAllPanel :userAnalytics="userAnalytics" />
    </section>

    <section
      class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <header class="flex items-start gap-3">
        <span
          class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-primary/10 text-primary"
        >
          <FileText class="h-4 w-4" />
        </span>
        <div class="min-w-0 grid gap-0.5">
          <h2 class="text-lg font-semibold tracking-tight">
            {{ t('post.feed.title') }}
          </h2>
          <p class="text-xs text-muted-foreground">
            {{
              t('post.feed.total', {
                count: totalTweetsCount
              })
            }}
          </p>
        </div>
      </header>

      <div
        v-if="tweetsLoading"
        class="grid gap-3"
      >
        <TweetCardSkeleton v-for="i in 3" :key="i" />
      </div>

      <div
        v-else-if="tweetsError"
        class="flex flex-col items-center justify-center gap-2 rounded-lg border border-dashed border-rose-500/30 bg-rose-50/30 py-10 text-center dark:bg-rose-950/20"
      >
        <span
          class="flex h-12 w-12 items-center justify-center rounded-full bg-rose-500/10 ring-1 ring-rose-500/20"
        >
          <AlertTriangle class="h-5 w-5 text-rose-500" />
        </span>
        <p class="text-sm text-rose-600 dark:text-rose-400">{{ tweetsError }}</p>
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
        class="flex flex-col items-center justify-center gap-2 rounded-lg border border-dashed border-border/60 bg-muted/10 py-10 text-center"
      >
        <span
          class="flex h-12 w-12 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
        >
          <Inbox class="h-5 w-5 text-muted-foreground" />
        </span>
        <p class="text-sm text-muted-foreground">
          {{ t('post.feed.emptyUserPosts') }}
        </p>
      </div>

      <div v-if="totalPages > 1" class="pt-2">
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
    </section>
  </div>
</template>
