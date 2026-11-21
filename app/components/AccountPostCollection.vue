<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import {
  AlertTriangle,
  Bookmark,
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
import { authQueueFor } from '@/services/auth-request-queue';
import { usePreferenceStore } from '@/stores/user';
import type { PostVM } from '@/types/posts';
import type { V2PostSort } from '@/types/v2';
import {
  v2BookmarkPost,
  v2CreateRetweet,
  UnconfirmedRetweetError,
  v2DeletePost,
  v2LikePost,
  v2ListMyBookmarkedPosts,
  v2ListMyLikedPosts,
  v2UnlikePost,
  v2UnbookmarkPost
} from '@/services/posts';

const props = defineProps<{ kind: 'likes' | 'bookmarks' }>();
const { t } = useAppLocale();
const localePath = useLocalePath();
const app = useNuxtApp();
const auth = authQueueFor(app);
const account = usePreferenceStore();
const identityChanging = ref(auth.isIdentityChanging);
const active = computed(() => account.isLoggedIn && !identityChanging.value);
const label = computed(() => `account.${props.kind}`);
const icon = computed(() => props.kind === 'likes' ? Heart : Bookmark);

const sort = ref<V2PostSort>('newest');
const isRetweetModalOpen = ref(false);
const selectedTweetForRetweet = ref<PostVM | null>(null);
const isSubmittingRetweet = ref(false);
const hasMounted = ref(false);
let unsubscribe: (() => void) | undefined;
const current = (revision: number) => hasMounted.value && active.value && revision === auth.revision;

const feed = usePostFeed({
  debugName: `account-${props.kind}`,
  pageSize: 12,
  loadPage: (page, pageSize) => app.runWithContext(() => props.kind === 'likes'
    ? v2ListMyLikedPosts({ page, pageSize, sort: sort.value })
    : v2ListMyBookmarkedPosts({ page, pageSize }))
});

const summaryText = computed(() =>
  t(`${label.value}.summary`, { count: feed.total })
);

function refreshFirstPage(): void {
  feed.page = 1;
  if (active.value) void feed.refresh();
}

function changePage(page: number): void {
  if (!active.value || feed.loading || page < 1 || page > feed.totalPages) return;
  feed.page = page;
  void feed.refresh();
}

onMounted(() => {
  hasMounted.value = true;
  unsubscribe = auth.subscribe(() => {
    identityChanging.value = auth.isIdentityChanging;
    feed.invalidate();
    selectedTweetForRetweet.value = null;
    isRetweetModalOpen.value = isSubmittingRetweet.value = false;
    refreshFirstPage();
  });
  refreshFirstPage();
});

watch(sort, refreshFirstPage);
watch(() => account.isLoggedIn, loggedIn => {
  if (!loggedIn) feed.invalidate();
  if (hasMounted.value && !auth.isIdentityChanging) refreshFirstPage();
});
onBeforeUnmount(() => {
  hasMounted.value = false;
  unsubscribe?.();
  feed.invalidate();
});

async function handleDeleteTweet(tweetId: number): Promise<void> {
  const revision = auth.revision;
  if (!current(revision)) return;
  try {
    await v2DeletePost(tweetId);
    if (!current(revision)) return;
    refreshFirstPage();
    toast.success(t('post.feedback.deleted'));
  } catch (error) {
    if (!current(revision)) return;
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
  const revision = auth.revision;
  if (!current(revision) || isSubmittingRetweet.value) return;
  isSubmittingRetweet.value = true;
  try {
    await v2CreateRetweet(originalTweetId, {
      content,
      visibility: 'public'
    });
    if (!current(revision)) return;
    toast.success(t('post.feedback.retweeted'));
    await feed.refresh();
  } catch (error) {
    if (!current(revision)) return;
    toast.error(
      error instanceof UnconfirmedRetweetError
        ? t('post.feedback.retweetUnconfirmed')
        : error instanceof Error
        ? error.message
        : t('post.feedback.retweetFailed')
    );
  } finally {
    if (current(revision)) {
      isSubmittingRetweet.value = false;
      isRetweetModalOpen.value = false;
    }
  }
}

async function handleLikeTweet(
  tweet: PostVM,
  action: 'like' | 'unlike'
): Promise<void> {
  const revision = auth.revision;
  if (!current(revision)) return;
  try {
    const result =
      action === 'like'
        ? await v2LikePost(tweet.id)
        : await v2UnlikePost(tweet.id);
    if (!current(revision)) return;
    if (props.kind === 'likes' && !result.isLiked) {
      refreshFirstPage();
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
    if (current(revision)) toast.error(t('post.feedback.likeFailed'));
  }
}

async function handleBookmarkTweet(
  tweet: PostVM,
  action: 'mark' | 'unmark'
): Promise<void> {
  const revision = auth.revision;
  if (!current(revision)) return;
  try {
    const result =
      action === 'mark'
        ? await v2BookmarkPost(tweet.id)
        : await v2UnbookmarkPost(tweet.id);
    if (!current(revision)) return;
    if (props.kind === 'bookmarks' && !result.isBookmarked) {
      refreshFirstPage();
      return;
    }
    feed.patchPost(tweet.id, current => ({
      ...current,
      viewer: {
        ...current.viewer,
        hasBookmarked: result.isBookmarked
      }
    }));
  } catch {
    if (current(revision)) toast.error(t('post.feedback.bookmarkFailed'));
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
            <component :is="icon" class="h-4 w-4" />
          </span>
          <div class="min-w-0 grid gap-0.5">
            <h2 class="text-lg font-semibold tracking-tight">
              {{ t(`${label}.title`) }}
            </h2>
            <p class="text-xs text-muted-foreground">
              {{ t(`${label}.description`) }}
            </p>
          </div>
        </div>
        <div class="flex flex-col gap-2 sm:flex-row">
          <Select v-if="kind === 'likes'" v-model="sort">
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
            :disabled="feed.loading || !active"
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
          {{ t(`${label}.title`) }}
        </p>
        <p class="text-sm font-semibold tabular-nums">
          {{ summaryText }}
        </p>
      </div>
    </section>

    <div
      v-if="feed.loading"
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
        <component :is="icon" class="h-5 w-5 text-muted-foreground" />
      </span>
      <p class="text-sm font-medium">
        {{ t(`${label}.emptyTitle`) }}
      </p>
      <p class="max-w-sm text-xs text-muted-foreground">
        {{ t(`${label}.emptyDescription`) }}
      </p>
    </div>
    <div v-if="feed.totalPages > 1" class="flex items-center justify-between gap-3">
      <Button variant="outline" :disabled="feed.loading || feed.page <= 1" @click="changePage(feed.page - 1)">
        {{ t('common.prev') }}
      </Button>
      <span class="text-sm tabular-nums" aria-live="polite">{{ feed.page }} / {{ feed.totalPages }}</span>
      <Button variant="outline" :disabled="feed.loading || feed.page >= feed.totalPages" @click="changePage(feed.page + 1)">
        {{ t('common.next') }}
      </Button>
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
