<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import {
  AlertTriangle,
  Heart,
  Loader2,
  RefreshCw
} from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import { Button } from '@/components/ui/button';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@/components/ui/select';
import TweetCardSkeleton from '@/components/TweetCardSkeleton.vue';
import TweetList from '@/components/TweetList.vue';
import RetweetModal from '@/components/RetweetModal.vue';
import { usePostFeed } from '@/composables/usePostFeed';
import type { PostVM } from '@/types/posts';
import type { V2PostSort } from '@/types/v2';
import {
  v2BookmarkPost,
  v2CreateRetweet,
  v2DeletePost,
  v2LikePost,
  v2ListMyLikedPosts,
  v2UnlikePost,
  v2UnbookmarkPost
} from '@/services/posts';

const { t } = useAppLocale();
const localePath = useLocalePath();

const sort = ref<V2PostSort>('newest');
const isRetweetModalOpen = ref(false);
const selectedTweetForRetweet = ref<PostVM | null>(null);
const isSubmittingRetweet = ref(false);
const hasMounted = ref(false);

const feed = usePostFeed({
  debugName: 'account-likes',
  pageSize: 12,
  loadPage: async (page, pageSize) =>
    await v2ListMyLikedPosts({
      page,
      pageSize,
      sort: sort.value
    })
});

const summaryText = computed(() =>
  t('account.likes.summary', { count: feed.total })
);

onMounted(() => {
  hasMounted.value = true;
  void feed.refresh();
});

watch(sort, () => {
  if (!hasMounted.value) return;
  feed.page = 1;
  void feed.refresh();
});

async function handleDeleteTweet(tweetId: number): Promise<void> {
  try {
    await v2DeletePost(tweetId);
    feed.removePost(tweetId);
    toast.success(t('post.feedback.deleted'));
  } catch (error) {
    toast.error(t('post.feedback.deleteFailed'), {
      description: error instanceof Error ? error.message : undefined
    });
  }
}

function handleReplyTweet(tweet: PostVM): void {
  void navigateTo(localePath(`/tweet/${tweet.id}?reply=1`));
}

function handleRetweetTweet(tweet: PostVM): void {
  selectedTweetForRetweet.value = tweet;
  isRetweetModalOpen.value = true;
}

async function handleSubmitRetweet({
  content,
  originalTweetId
}: {
  content: string;
  originalTweetId: number;
}): Promise<void> {
  isSubmittingRetweet.value = true;
  try {
    await v2CreateRetweet(originalTweetId, {
      content,
      visibility: 'public'
    });
    toast.success(t('post.feedback.retweeted'));
    await feed.refresh();
  } catch (error) {
    toast.error(
      error instanceof Error
        ? error.message
        : t('post.feedback.retweetFailed')
    );
  } finally {
    isSubmittingRetweet.value = false;
    isRetweetModalOpen.value = false;
  }
}

async function handleLikeTweet(
  tweet: PostVM,
  action: 'like' | 'unlike'
): Promise<void> {
  try {
    const result =
      action === 'like'
        ? await v2LikePost(tweet.id)
        : await v2UnlikePost(tweet.id);
    if (!result.isLiked) {
      feed.removePost(tweet.id);
      return;
    }
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
    toast.error(t('post.feedback.likeFailed'));
  }
}

async function handleBookmarkTweet(
  tweet: PostVM,
  action: 'mark' | 'unmark'
): Promise<void> {
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
    toast.error(t('post.feedback.bookmarkFailed'));
  }
}
</script>

<template>
  <div class="grid gap-4">
    <section
      class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <header
        class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"
      >
        <div class="flex items-start gap-3">
          <span
            class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-rose-500/10 text-rose-600 dark:text-rose-400"
          >
            <Heart class="h-4 w-4" />
          </span>
          <div class="min-w-0 grid gap-0.5">
            <h2 class="text-lg font-semibold tracking-tight">
              {{ t('account.likes.title') }}
            </h2>
            <p class="text-xs text-muted-foreground">
              {{ t('account.likes.description') }}
            </p>
          </div>
        </div>
        <div class="flex flex-col gap-2 sm:flex-row">
          <Select v-model="sort">
            <SelectTrigger class="h-9 w-full rounded-md shadow-xs sm:w-[150px]">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="newest">
                {{ t('account.posts.sort.newest') }}
              </SelectItem>
              <SelectItem value="oldest">
                {{ t('account.posts.sort.oldest') }}
              </SelectItem>
              <SelectItem value="popular">
                {{ t('account.posts.sort.popular') }}
              </SelectItem>
            </SelectContent>
          </Select>
          <Button
            variant="outline"
            class="h-9 rounded-md shadow-xs"
            :disabled="feed.loading"
            @click="feed.refresh"
          >
            <Loader2 v-if="feed.loading" class="h-3.5 w-3.5 animate-spin" />
            <RefreshCw v-else class="h-3.5 w-3.5" />
            {{ t('common.refresh') }}
          </Button>
        </div>
      </header>

      <div
        class="flex items-center justify-between gap-3 rounded-lg border border-border/60 bg-muted/20 p-3"
      >
        <p class="text-[11px] uppercase tracking-wider text-muted-foreground">
          {{ t('account.likes.title') }}
        </p>
        <p class="text-sm font-semibold tabular-nums">
          {{ summaryText }}
        </p>
      </div>
    </section>

    <div
      v-if="feed.loading && feed.posts.length === 0"
      class="grid gap-3"
    >
      <TweetCardSkeleton v-for="item in 3" :key="item" />
    </div>

    <div
      v-else-if="feed.error"
      class="flex flex-col items-center justify-center gap-2 rounded-xl border border-dashed border-border/60 bg-muted/10 py-12 text-center"
    >
      <span
        class="flex h-12 w-12 items-center justify-center rounded-full bg-rose-500/10 ring-1 ring-rose-200/60 dark:ring-rose-900/40"
      >
        <AlertTriangle class="h-5 w-5 text-rose-600 dark:text-rose-400" />
      </span>
      <p class="text-sm text-muted-foreground">{{ feed.error }}</p>
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

    <div
      v-else
      class="flex flex-col items-center justify-center gap-2 rounded-xl border border-dashed border-border/60 bg-muted/10 py-12 text-center"
    >
      <span
        class="flex h-12 w-12 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
      >
        <Heart class="h-5 w-5 text-muted-foreground" />
      </span>
      <p class="text-sm font-medium">
        {{ t('account.likes.emptyTitle') }}
      </p>
      <p class="max-w-sm text-xs text-muted-foreground">
        {{ t('account.likes.emptyDescription') }}
      </p>
    </div>
  </div>

  <RetweetModal
    v-if="selectedTweetForRetweet"
    v-model:open="isRetweetModalOpen"
    :tweet="selectedTweetForRetweet"
    :is-submitting="isSubmittingRetweet"
    @submit-retweet="handleSubmitRetweet"
  />
</template>
