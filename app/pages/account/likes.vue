<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import { Heart, RefreshCw } from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import { Button } from '@/components/ui/button';
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle
} from '@/components/ui/card';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@/components/ui/select';
import AppEmptyState from '@/components/app/AppEmptyState.vue';
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
  } catch (error) {
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
  } catch (error) {
    toast.error(t('post.feedback.bookmarkFailed'));
  }
}
</script>

<template>
  <Card>
    <CardHeader class="gap-4 sm:flex-row sm:items-start sm:justify-between">
      <div>
        <CardTitle>{{ t('account.likes.title') }}</CardTitle>
        <CardDescription>
          {{ t('account.likes.description') }}
        </CardDescription>
      </div>
      <div class="flex flex-col gap-2 sm:flex-row">
        <Select v-model="sort">
          <SelectTrigger class="w-full sm:w-[150px]">
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
          class="gap-2"
          :disabled="feed.loading"
          @click="feed.refresh"
        >
          <RefreshCw class="h-4 w-4" />
          {{ t('common.refresh') }}
        </Button>
      </div>
    </CardHeader>
    <CardContent class="space-y-4">
      <p class="text-sm text-muted-foreground">
        {{ summaryText }}
      </p>

      <div
        v-if="feed.loading"
        class="space-y-4"
      >
        <TweetCardSkeleton v-for="item in 3" :key="item" />
      </div>

      <p
        v-else-if="feed.error"
        class="text-sm text-destructive"
      >
        {{ feed.error }}
      </p>

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
        :icon="Heart"
        :title="t('account.likes.emptyTitle')"
        :description="t('account.likes.emptyDescription')"
      />
    </CardContent>
  </Card>

  <RetweetModal
    v-if="selectedTweetForRetweet"
    v-model:open="isRetweetModalOpen"
    :tweet="selectedTweetForRetweet"
    :is-submitting="isSubmittingRetweet"
    @submit-retweet="handleSubmitRetweet"
  />
</template>
