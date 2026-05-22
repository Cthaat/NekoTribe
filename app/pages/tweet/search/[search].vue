<script lang="ts" setup>
import { onMounted, ref, watch } from 'vue';
import type { PostVM } from '@/types/posts';
import { AlertTriangle } from 'lucide-vue-next';
import {
  v2BookmarkPost,
  v2CreateRetweet,
  v2DeletePost,
  v2LikePost,
  v2ListPosts,
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
const { t } = useAppLocale();

const isRetweetModalOpen = ref(false);
const selectedTweetForRetweet = ref<PostVM | null>(null);
const isSubmittingRetweet = ref(false);
const hasMounted = ref(false);

function currentSearchQuery(): string {
  const value = route.params.search;
  if (Array.isArray(value)) return String(value[0] ?? '');
  return typeof value === 'string' ? value : '';
}

const feed = usePostFeed({
  debugName: 'tweet-search',
  pageSize: 15,
  loadPage: async (page, pageSize) =>
    await v2ListPosts({
      page,
      pageSize,
      sort: 'newest',
      q: currentSearchQuery()
    })
});

onMounted(() => {
  hasMounted.value = true;
  void feed.refresh();
});

watch(
  () => feed.page,
  () => {
    if (hasMounted.value) void feed.refresh();
  }
);

watch(
  () => route.params.search,
  () => {
    if (!hasMounted.value) return;
    if (feed.page !== 1) {
      feed.page = 1;
      return;
    }
    void feed.refresh();
  }
);

async function handleDeleteTweet(tweetId: number) {
  try {
    await v2DeletePost(tweetId);
    toast.success(t('post.feedback.deleted'));
    feed.removePost(tweetId);
  } catch (error) {
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
  isSubmittingRetweet.value = true;
  try {
    await v2CreateRetweet(originalTweetId, {
      content,
      visibility: 'public'
    });
    toast.success(t('post.feedback.retweeted'));
    await feed.refresh();
  } catch (error) {
    const message =
      error instanceof Error
        ? error.message
        : t('post.feedback.retweetFailed');
    toast.error(message);
  } finally {
    isSubmittingRetweet.value = false;
    isRetweetModalOpen.value = false;
  }
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
    feed.patchPost(tweet.id, current => ({
      ...current,
      viewer: {
        ...current.viewer,
        hasBookmarked: result.isBookmarked
      }
    }));
  } catch {
    toast.error(t('common.operationFailed'));
  }
}
</script>

<template>
  <div class="pt-2">
    <div class="bg-background p-4 sm:p-10">
      <div v-if="!hasMounted || feed.loading" class="space-y-4">
        <TweetCardSkeleton
          v-for="i in 5"
          :key="`skeleton-${i}`"
        />
      </div>

      <div
        v-else-if="feed.error"
        class="flex flex-col items-center justify-center gap-3 rounded-xl border border-dashed border-rose-500/30 bg-rose-50/30 py-12 text-center dark:bg-rose-950/20"
      >
        <span
          class="flex h-12 w-12 items-center justify-center rounded-full bg-rose-500/10 ring-1 ring-rose-500/20"
        >
          <AlertTriangle class="h-5 w-5 text-rose-500" />
        </span>
        <div class="grid gap-1">
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
      class="mb-8 flex justify-center"
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
