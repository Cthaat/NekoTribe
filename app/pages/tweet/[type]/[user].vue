<script lang="ts" setup>
import { computed, onMounted, ref, watch } from 'vue';
import type { PostVM } from '@/types/posts';
import {
  AtSign,
  Bookmark,
  Compass,
  Sparkles
} from 'lucide-vue-next';
import {
  v2BookmarkPost,
  v2CreateRetweet,
  v2DeletePost,
  v2LikePost,
  v2ListTimelinePosts,
  normalizePostTimelineType,
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

const localePath = useLocalePath();
const route = useRoute();
const { t } = useAppLocale();

const isRetweetModalOpen = ref(false);
const selectedTweetForRetweet = ref<PostVM | null>(null);
const isSubmittingRetweet = ref(false);
const hasMounted = ref(false);

const timelineType = computed(() =>
  normalizePostTimelineType(String(route.params.type || 'home'))
);
const emptyStateMeta = computed(() => {
  if (timelineType.value === 'mention') {
    return {
      icon: AtSign,
      title: t('post.feed.emptyMentionTitle', '暂时没有提及你的内容'),
      description:
        t(
          'post.feed.emptyMentionDescription',
          '当有人在推文中提到你时，这里会自动显示。你可以先去首页看看最新动态。'
        ),
      accent: 'from-sky-500/20 via-cyan-500/10 to-transparent',
      actionLabel: t('post.feed.emptyGoHome', '回到首页'),
      actionTo: localePath(`/tweet/home/${requestedUserId.value}`)
    };
  }

  if (timelineType.value === 'bookmark') {
    return {
      icon: Bookmark,
      title: t('post.feed.emptyBookmarkTitle', '书签还是空的'),
      description:
        t(
          'post.feed.emptyBookmarkDescription',
          '把喜欢的内容加入书签后，它们会集中出现在这里，方便你随时回看。'
        ),
      accent: 'from-amber-500/20 via-orange-500/10 to-transparent',
      actionLabel: t('post.feed.emptyExplore', '去逛逛首页'),
      actionTo: localePath(`/tweet/home/${requestedUserId.value}`)
    };
  }

  return {
    icon: Sparkles,
    title: t('post.feed.emptyTitle'),
    description: t('post.feed.emptyDescription'),
    accent: 'from-zinc-500/20 via-transparent to-transparent',
    actionLabel: t('post.feed.emptyExplore', '去逛逛首页'),
    actionTo: localePath(`/tweet/home/${requestedUserId.value}`)
  };
});
const requestedUserId = computed(() =>
  Number(route.params.user || 0)
);

const feed = usePostFeed({
  debugName: 'tweet-timeline',
  pageSize: 15,
  loadPage: async (page, pageSize) =>
    await v2ListTimelinePosts({
      type: timelineType.value,
      userId: requestedUserId.value,
      page,
      pageSize,
      sort: 'newest'
    })
});

onMounted(() => {
  hasMounted.value = true;
  void feed.refresh();
});

watch(
  [
    () => feed.page,
    () => route.params.type,
    () => route.params.user
  ],
  () => {
    if (hasMounted.value) {
      void feed.refresh();
    }
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
  const detailPage = localePath(`/tweet/${tweet.id}`);
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
  } catch (error) {
    console.error('Failed to like/unlike tweet:', error);
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
  } catch (error) {
    console.error(
      'Failed to bookmark/unbookmark tweet:',
      error
    );
    toast.error(t('common.operationFailed'));
  }
}
</script>

<template>
  <div class="pt-2">
    <div class="bg-background p-10">
      <div v-if="!hasMounted || feed.loading" class="space-y-4">
        <TweetCardSkeleton
          v-for="i in 5"
          :key="`skeleton-${i}`"
        />
      </div>

      <div
        v-else-if="feed.error"
        class="text-center text-destructive"
      >
        {{ t('post.feed.loadProblem') }}
        <pre class="text-xs mt-2">{{ feed.error }}</pre>
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
        :title="emptyStateMeta.title"
        :description="emptyStateMeta.description"
        :icon="emptyStateMeta.icon"
        class="border-border/60 bg-gradient-to-b from-background to-muted/20 shadow-sm"
      >
        <div class="mt-4 flex flex-col items-center gap-3">
          <div class="rounded-full border border-dashed border-border/70 bg-background/80 px-4 py-2 text-xs text-muted-foreground">
            {{
              timelineType === 'mention'
                ? t('post.feed.emptyMentionHint', '提及会在有人 @你 时自动出现')
                : t('post.feed.emptyBookmarkHint', '书签会保存你手动收藏的内容')
            }}
          </div>
          <NuxtLink
            :to="emptyStateMeta.actionTo"
            class="inline-flex items-center gap-2 rounded-full bg-primary px-4 py-2 text-sm font-medium text-primary-foreground shadow-sm transition-transform hover:-translate-y-0.5"
          >
            <Compass class="h-4 w-4" />
            {{ emptyStateMeta.actionLabel }}
          </NuxtLink>
        </div>
      </AppEmptyState>

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
