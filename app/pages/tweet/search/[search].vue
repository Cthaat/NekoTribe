<script lang="ts" setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import type { PostVM } from '@/types/posts';
import type { V2TagAnalytics, V2TagItem } from '@/types/v2';
import { v2GetTagAnalytics, v2SearchTags } from '@/api/v2/posts';
import { authQueueFor } from '@/services/auth-request-queue';
import { usePreferenceStore } from '@/stores/user';
import { AlertTriangle, ArrowLeft, Hash } from 'lucide-vue-next';
import {
  v2BookmarkPost,
  v2CreateRetweet,
  UnconfirmedRetweetError,
  v2DeletePost,
  v2LikePost,
  v2ListPosts,
  v2ListTagPosts,
  v2UnlikePost,
  v2UnbookmarkPost
} from '@/services/posts';
import { usePostFeed } from '@/composables/usePostFeed';
import AppEmptyState from '@/components/app/AppEmptyState.vue';
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

const route = useRoute();
const localePath = useLocalePath();
const { t, locale } = useAppLocale();
const app = useNuxtApp();
const auth = authQueueFor(app);
const preferences = usePreferenceStore();

const isRetweetModalOpen = ref(false);
const selectedTweetForRetweet = ref<PostVM | null>(null);
const isSubmittingRetweet = ref(false);
const hasMounted = ref(false);
const authChange = ref(0);
const tagStats = ref<V2TagAnalytics | null>(null);
const matchingTags = ref<V2TagItem[]>([]);
const tagStatsRetry = ref(0);
const tagStatsFailed = ref(false);
let stopAuth: (() => void) | undefined;
let viewRevision = 0;

function invalidatePostActions(): void {
  viewRevision++;
  isRetweetModalOpen.value = false;
  selectedTweetForRetweet.value = null;
  isSubmittingRetweet.value = false;
}

function currentSearchQuery(): string {
  const value = route.params.search;
  if (Array.isArray(value)) return String(value[0] ?? '');
  return typeof value === 'string' ? value : '';
}

const tagName = computed(() => {
  const keyword = currentSearchQuery();
  return keyword.startsWith('#') ? keyword.slice(1).trim() : '';
});

watch([hasMounted, currentSearchQuery, () => preferences.isLoggedIn, authChange],
  async ([mounted, query, loggedIn], _, onCleanup) => {
    matchingTags.value = [];
    const q = query.trim();
    if (!mounted || !loggedIn || !q || tagName.value || auth.isIdentityChanging) return;
    const request = new AbortController();
    onCleanup(() => request.abort());
    try {
      const items = await app.runWithContext(() => v2SearchTags(q, request.signal));
      if (!request.signal.aborted) matchingTags.value = items;
    } catch {
      // Posts remain available if tag search fails.
    }
  }, { flush: 'sync' }
);

const tagMetrics = computed(() => {
  const stats = tagStats.value;
  if (!stats) return [];
  const format = new Intl.NumberFormat(locale.value, { maximumFractionDigits: 2 });
  return Object.entries({
    posts: stats.total_posts,
    authors: stats.total_authors,
    views: stats.total_views,
    likes: stats.total_likes,
    engagement: stats.engagement_score
  }).map(([key, value]) => ({ key, value: format.format(value) }));
});

watch([hasMounted, tagName, () => preferences.isLoggedIn, authChange, tagStatsRetry],
  async ([mounted, name, loggedIn], _, onCleanup) => {
    tagStats.value = null;
    tagStatsFailed.value = false;
    if (!mounted || !name || !loggedIn || auth.isIdentityChanging) return;
    let current = true;
    onCleanup(() => { current = false; });
    try {
      const stats = await app.runWithContext(() => v2GetTagAnalytics(name));
      if (current) tagStats.value = stats;
    } catch (error) {
      if (!current) return;
      const response = error as { statusCode?: number; response?: { status?: number } };
      tagStatsFailed.value = (response?.statusCode ?? response?.response?.status) !== 404;
    }
  }, { flush: 'sync' }
);

const feed = usePostFeed({
  debugName: 'tweet-search',
  pageSize: 15,
  loadPage: async (page, pageSize) =>
    await app.runWithContext(() => {
      const name = tagName.value;
      if (name && preferences.isLoggedIn) return v2ListTagPosts(name, page, pageSize);
      return v2ListPosts({ page, pageSize, sort: 'newest', q: currentSearchQuery() });
    })
});

onMounted(() => {
  stopAuth = auth.subscribe(() => { authChange.value++; });
  hasMounted.value = true;
  void feed.refresh();
});
onBeforeUnmount(() => {
  stopAuth?.();
  invalidatePostActions();
  feed.invalidate();
});

watch(
  () => feed.page,
  () => {
    invalidatePostActions();
    if (hasMounted.value && currentSearchQuery() && !auth.isIdentityChanging) void feed.refresh();
  },
  { flush: 'sync' }
);

watch(
  [() => route.params.search, authChange, () => preferences.isLoggedIn],
  () => {
    if (!hasMounted.value) return;
    invalidatePostActions();
    feed.invalidate();
    if (feed.page !== 1) {
      feed.page = 1;
      return;
    }
    if (currentSearchQuery() && !auth.isIdentityChanging) void feed.refresh();
  },
  { flush: 'sync' }
);

async function handleDeleteTweet(tweetId: number) {
  const revision = viewRevision;
  try {
    await v2DeletePost(tweetId);
    if (revision !== viewRevision) return;
    toast.success(t('post.feedback.deleted'));
    feed.removePost(tweetId);
  } catch (error) {
    if (revision !== viewRevision) return;
    const message =
      error instanceof Error ? error.message : t('common.unknownError');
    toast.error(t('post.feedback.deleteFailed'), {
      description: message
    });
  }
}

function handleReplyTweet(tweet: PostVM) {
  const detailPage = localePath(`/tweet/${tweet.id}?reply=1`);
  return navigateTo(detailPage, { replace: true });
}

function handleRetweetTweet(tweet: PostVM) {
  selectedTweetForRetweet.value = tweet;
  isRetweetModalOpen.value = true;
}

async function handleSubmitRetweet({
  content,
  originalTweetId
}: {
  content: string;
  originalTweetId: number;
}) {
  const revision = viewRevision;
  isSubmittingRetweet.value = true;
  try {
    await v2CreateRetweet(originalTweetId, {
      content,
      visibility: 'public'
    });
    if (revision !== viewRevision) return;
    toast.success(t('post.feedback.retweeted'));
    await feed.refresh();
  } catch (error) {
    if (revision !== viewRevision) return;
    const message =
      error instanceof UnconfirmedRetweetError
        ? t('post.feedback.retweetUnconfirmed')
        : error instanceof Error
        ? error.message
        : t('post.feedback.retweetFailed');
    toast.error(message);
  } finally {
    if (revision === viewRevision) {
      isSubmittingRetweet.value = false;
      isRetweetModalOpen.value = false;
    }
  }
}

async function handleLikeTweet(
  tweet: PostVM,
  action: 'like' | 'unlike'
) {
  const revision = viewRevision;
  try {
    const result =
      action === 'like'
        ? await v2LikePost(tweet.id)
        : await v2UnlikePost(tweet.id);
    if (revision !== viewRevision) return;
    feed.patchPost(tweet.id, current => ({
      ...current,
      viewer: {
        ...current.viewer,
        hasLiked: result.isLiked
      },
      counts: {
        ...current.counts,
        likes: result.likesCount
      }
    }));
  } catch {
    if (revision === viewRevision) toast.error(t('common.operationFailed'));
  }
}

async function handleBookmarkTweet(
  tweet: PostVM,
  action: 'mark' | 'unmark'
) {
  const revision = viewRevision;
  try {
    const result =
      action === 'mark'
        ? await v2BookmarkPost(tweet.id)
        : await v2UnbookmarkPost(tweet.id);
    if (revision !== viewRevision) return;
    feed.patchPost(tweet.id, current => ({
      ...current,
      viewer: {
        ...current.viewer,
        hasBookmarked: result.isBookmarked
      }
    }));
  } catch {
    if (revision === viewRevision) toast.error(t('common.operationFailed'));
  }
}
</script>

<template>
  <div class="mx-auto min-h-screen w-full max-w-[640px] bg-transparent px-3 pb-10 sm:px-4">
    <header class="sticky top-0 z-10 -mx-3 mb-3 bg-background/85 px-4 py-3 backdrop-blur-md sm:-mx-4">
      <div class="flex items-center gap-3">
        <NuxtLink
          :to="localePath('/feed')"
          class="pressable inline-flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-card text-foreground shadow-[0_1px_3px_rgba(15,23,42,0.03)] transition-colors hover:bg-secondary dark:shadow-none"
          :aria-label="t('common.back')"
        >
          <ArrowLeft class="h-4.5 w-4.5" />
        </NuxtLink>
        <div class="min-w-0 flex-1">
          <h1 class="truncate text-lg font-semibold tracking-tight text-foreground">
            {{ tagName ? `#${tagName}` : currentSearchQuery() }}
          </h1>
          <p v-if="!feed.loading && feed.total > 0" class="text-xs text-[var(--ink-tertiary)] tabular-nums">
            {{ feed.total }}
          </p>
        </div>
      </div>

      <section v-if="matchingTags.length" class="mt-3" aria-labelledby="matching-tags-title">
        <h2 id="matching-tags-title" class="mb-2 text-xs font-medium tracking-wide text-muted-foreground">
          {{ t('post.feed.matchingTags') }}
        </h2>
        <ul class="flex flex-wrap gap-2">
          <li v-for="tag in matchingTags" :key="tag.tag_id">
            <NuxtLink
              class="inline-flex max-w-60 items-center gap-1 truncate rounded-full bg-card px-3 py-1 text-xs font-medium text-foreground shadow-[0_1px_2px_rgba(15,23,42,0.03)] transition-colors hover:bg-[var(--primary-soft)] hover:text-primary dark:shadow-none"
              :to="localePath('/tweet/search/' + encodeURIComponent('#' + tag.name))"
            >
              <Hash class="h-3 w-3 shrink-0 text-primary" />
              <span class="truncate">{{ tag.name }}</span>
            </NuxtLink>
          </li>
        </ul>
      </section>
    </header>

    <div class="space-y-3">
      <section v-if="tagStats" class="rounded-[20px] bg-card p-4 shadow-[0_1px_3px_rgba(15,23,42,0.03)] dark:shadow-none" aria-labelledby="tag-analytics-title">
        <h2 id="tag-analytics-title" class="mb-3 text-xs font-medium tracking-wide text-muted-foreground">
          {{ t('post.tagAnalytics.title') }}
        </h2>
        <dl class="grid grid-cols-2 gap-3 text-sm sm:flex sm:flex-wrap sm:gap-x-6">
          <div v-for="metric in tagMetrics" :key="metric.key">
            <dt class="text-xs text-muted-foreground">{{ t(`post.tagAnalytics.${metric.key}`) }}</dt>
            <dd class="text-base font-semibold tabular-nums text-foreground">{{ metric.value }}</dd>
          </div>
        </dl>
      </section>
      <button v-else-if="tagStatsFailed" type="button" class="text-sm text-muted-foreground underline" @click="tagStatsRetry++">
        {{ t('post.tagAnalytics.retry') }}
      </button>

      <div v-if="!hasMounted || feed.loading" class="space-y-3">
        <TweetCardSkeleton
          v-for="i in 5"
          :key="`skeleton-${i}`"
        />
      </div>

      <div
        v-else-if="feed.error"
        class="flex flex-col items-center justify-center gap-3 rounded-[20px] bg-card py-12 text-center shadow-[0_1px_3px_rgba(15,23,42,0.03)] dark:shadow-none"
      >
        <span
          class="flex h-12 w-12 items-center justify-center rounded-full bg-rose-500/10 text-rose-500"
        >
          <AlertTriangle class="h-5 w-5" />
        </span>
        <div class="grid gap-1 px-4">
          <p class="text-sm font-medium">
            {{ t('post.feed.loadProblem') }}
          </p>
          <p
            class="max-w-md whitespace-pre-wrap break-words text-xs text-muted-foreground"
          >{{ feed.error }}</p>
        </div>
      </div>

      <TweetList
        v-else-if="feed.posts.length > 0"
        :tweets="feed.posts"
        @delete-tweet="handleDeleteTweet"
        @reply-tweet="handleReplyTweet"
        @retweet-tweet="handleRetweetTweet"
        @like-tweet="handleLikeTweet"
        @bookmark-tweet="handleBookmarkTweet"
      />

      <AppEmptyState
        v-else
        :title="t('post.feed.searchEmptyTitle')"
        :description="t('post.feed.searchEmptyDescription')"
      />

      <RetweetModal
        v-if="selectedTweetForRetweet"
        v-model:open="isRetweetModalOpen"
        :tweet="selectedTweetForRetweet"
        :is-submitting="isSubmittingRetweet"
        @submit-retweet="handleSubmitRetweet"
      />
    </div>

    <Pagination
      v-if="!feed.loading && !feed.error && feed.total > 0"
      v-model:page="feed.page"
      :items-per-page="feed.pageSize"
      :total="feed.total"
      class="py-6 flex justify-center"
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
            :is-active="item.value === feed.page"
          >
            {{ item.value }}
          </PaginationItem>
        </template>
        <PaginationNext />
      </PaginationContent>
    </Pagination>
  </div>
</template>
