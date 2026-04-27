<script lang="ts" setup>
import { computed, ref, watch } from 'vue';
import type { V2Post } from '@/types/v2';
import {
  v2BookmarkPost,
  v2CreateRetweet,
  v2DeletePost,
  v2LikePost,
  v2ListMyBookmarkedPosts,
  v2ListPosts,
  v2ListTrendingPosts,
  v2ListUserPosts,
  v2UnlikePost,
  v2UnbookmarkPost
} from '@/services/posts';
import { usePostFeed } from '@/composables/usePostFeed';
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

const isRetweetModalOpen = ref(false);
const selectedTweetForRetweet = ref<V2Post | null>(null);
const isSubmittingRetweet = ref(false);

const timelineType = computed(() =>
  String(route.params.type || 'home')
);
const requestedUserId = computed(() =>
  Number(route.params.user || 0)
);

const feed = usePostFeed({
  pageSize: 15,
  loadPage: async (page, pageSize) =>
    timelineType.value === 'trending'
      ? await v2ListTrendingPosts({
          page,
          page_size: pageSize
        })
      : timelineType.value === 'my_tweets'
        ? await v2ListUserPosts(requestedUserId.value, {
            page,
            page_size: pageSize,
            sort: 'newest'
          })
        : timelineType.value === 'mention'
          ? await v2ListPosts({
              page,
              page_size: pageSize,
              sort: 'newest',
              timeline: 'mentions'
            })
          : timelineType.value === 'bookmark'
            ? await v2ListMyBookmarkedPosts({
                page,
                page_size: pageSize,
                sort: 'newest'
              })
            : await v2ListPosts({
                page,
                page_size: pageSize,
                sort: 'newest',
                timeline: 'home'
              })
});

watch(
  [feed.page, () => route.params.type, () => route.params.user],
  () => {
    feed.refresh();
  },
  { immediate: true }
);

async function handleDeleteTweet(tweetId: number) {
  try {
    await v2DeletePost(tweetId);
    toast.success('推文已成功删除。');
    feed.removePost(tweetId);
  } catch (error) {
    const message =
      error instanceof Error ? error.message : '未知错误';
    toast.error('删除推文失败，请稍后再试。', {
      description: message
    });
  }
}

function handleReplyTweet(tweet: V2Post) {
  const detailPage = localePath(`/tweet/${tweet.post_id}`);
  return navigateTo(detailPage, { replace: true });
}

function handleRetweetTweet(tweet: V2Post) {
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
    toast.success('转发成功！');
    await feed.refresh();
  } catch (error) {
    const message =
      error instanceof Error ? error.message : '转发失败';
    toast.error(message);
  } finally {
    isSubmittingRetweet.value = false;
    isRetweetModalOpen.value = false;
  }
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
    feed.patchPost(tweet.post_id, current => ({
      ...current,
      viewer_state: {
        ...current.viewer_state,
        is_liked: result.is_liked
      },
      stats: {
        ...current.stats,
        likes_count: result.likes_count
      }
    }));
  } catch (error) {
    console.error('Failed to like/unlike tweet:', error);
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
    feed.patchPost(tweet.post_id, current => ({
      ...current,
      viewer_state: {
        ...current.viewer_state,
        is_bookmarked: result.is_bookmarked
      }
    }));
  } catch (error) {
    console.error(
      'Failed to bookmark/unbookmark tweet:',
      error
    );
    toast.error('操作失败');
  }
}
</script>

<template>
  <div class="pt-2">
    <div class="bg-background p-10">
      <div v-if="feed.loading" class="space-y-4">
        <TweetCardSkeleton
          v-for="i in 5"
          :key="`skeleton-${i}`"
        />
      </div>

      <div
        v-else-if="feed.error"
        class="text-center text-destructive"
      >
        抱歉，加载推文时遇到问题，请刷新页面。
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

      <RetweetModal
        v-if="selectedTweetForRetweet"
        v-model:open="isRetweetModalOpen"
        :tweet="selectedTweetForRetweet"
        :is-submitting="isSubmittingRetweet"
        @submit-retweet="handleSubmitRetweet"
      />

      <div
        v-else
        class="text-center text-muted-foreground py-10"
      >
        这里还没有推文哦。
      </div>
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
