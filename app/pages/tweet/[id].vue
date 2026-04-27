<script lang="ts" setup>
import { computed, ref } from 'vue';
import type {
  V2Comment,
  V2Post
} from '@/services';
import {
  v2BookmarkPost,
  v2CreateComment,
  v2CreateRetweet,
  v2DeletePost,
  v2GetPost,
  v2LikeComment,
  v2LikePost,
  v2ListComments,
  v2UnlikeComment,
  v2UnlikePost,
  v2UnbookmarkPost
} from '@/services';
import TweetCard from '@/components/TweetCard.vue';
import TweetCardSkeleton from '@/components/TweetCardSkeleton.vue';
import CommentSection from '@/components/CommentSection.vue';
import { toast } from 'vue-sonner';
import { useRoute } from 'vue-router';
import { usePreferenceStore } from '~/stores/user';

const route = useRoute();
const localePath = useLocalePath();
const preferenceStore = usePreferenceStore();

const tweet = ref<V2Post | null>(null);
const comments = ref<V2Comment[]>([]);
const tweetPending = ref(false);
const commentPending = ref(false);
const tweetError = ref<string | null>(null);
const commentError = ref<string | null>(null);

const isRetweetModalOpen = ref(false);
const selectedTweetForRetweet = ref<V2Post | null>(null);
const isSubmittingRetweet = ref(false);

async function loadTweet() {
  tweetPending.value = true;
  tweetError.value = null;
  try {
    tweet.value = await v2GetPost(Number(route.params.id));
  } catch (error) {
    tweetError.value =
      error instanceof Error ? error.message : '加载推文失败';
  } finally {
    tweetPending.value = false;
  }
}

async function loadComments() {
  commentPending.value = true;
  commentError.value = null;
  try {
    const result = await v2ListComments(
      Number(route.params.id),
      {
        page: 1,
        page_size: 100,
        sort: 'oldest'
      }
    );
    comments.value = result.items;
  } catch (error) {
    commentError.value =
      error instanceof Error ? error.message : '加载评论失败';
  } finally {
    commentPending.value = false;
  }
}

await Promise.all([loadTweet(), loadComments()]);

async function handleDeleteTweet(tweetId: number) {
  try {
    await v2DeletePost(tweetId);
    toast.success('推文已成功删除。');
    const rootPath = localePath(
      `/tweet/home/${preferenceStore.preferences.user.user_id}`
    );
    await navigateTo(rootPath);
  } catch (error) {
    const message =
      error instanceof Error ? error.message : '未知错误';
    toast.error('删除推文失败，请稍后再试。', {
      description: message
    });
  }
}

function handleReplyTweet(tweetItem: V2Post) {
}

function handleRetweetTweet(tweetItem: V2Post) {
  selectedTweetForRetweet.value = tweetItem;
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
    await loadTweet();
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
  tweetItem: V2Post,
  action: 'like' | 'unlike'
) {
  try {
    const result =
      action === 'like'
        ? await v2LikePost(tweetItem.post_id)
        : await v2UnlikePost(tweetItem.post_id);
    if (tweet.value && tweet.value.post_id === tweetItem.post_id) {
      tweet.value.viewer_state.is_liked = result.is_liked;
      tweet.value.stats.likes_count = result.likes_count;
    }
  } catch (error) {
    console.error('Failed to like/unlike tweet:', error);
  }
}

async function handleBookmarkTweet(
  tweetItem: V2Post,
  action: 'mark' | 'unmark'
) {
  try {
    const result =
      action === 'mark'
        ? await v2BookmarkPost(tweetItem.post_id)
        : await v2UnbookmarkPost(tweetItem.post_id);
    if (tweet.value && tweet.value.post_id === tweetItem.post_id) {
      tweet.value.viewer_state.is_bookmarked =
        result.is_bookmarked;
    }
  } catch (error) {
    console.error(
      'Failed to bookmark/unbookmark tweet:',
      error
    );
  }
}

async function handleLikeTweetComment(
  commentId: number,
  action: 'likeComment' | 'unlikeComment'
) {
  try {
    const result =
      action === 'likeComment'
        ? await v2LikeComment(commentId)
        : await v2UnlikeComment(commentId);
    const index = comments.value.findIndex(
      item => item.comment_id === commentId
    );
    if (index !== -1) {
      comments.value[index].viewer_state.is_liked =
        result.is_liked;
      comments.value[index].stats.likes_count =
        result.likes_count;
    }
  } catch (error) {
    console.error('Failed to like comment:', error);
    toast.error('点赞评论失败，请稍后重试。');
  }
}

async function handleTweetComment(content: string) {
  if (!tweet.value) return;
  try {
    await v2CreateComment(tweet.value.post_id, {
      content,
      parent_comment_id: null
    });
    await loadComments();
  } catch (error) {
    console.error('Failed to send tweet comment:', error);
    toast.error('发送评论失败，请稍后重试。');
  }
}

async function handleReplyTweetComment(
  parentCommentId: number,
  content: string
) {
  if (!tweet.value) return;
  try {
    await v2CreateComment(tweet.value.post_id, {
      content,
      parent_comment_id: parentCommentId
    });
    await loadComments();
  } catch (error) {
    console.error('Failed to send tweet comment:', error);
    toast.error('发送评论失败，请稍后重试。');
  }
}

const pending = computed(
  () => tweetPending.value || commentPending.value
);
</script>

<template>
  <div class="bg-background pt-4">
    <div v-if="pending">
      <TweetCardSkeleton />
    </div>

    <div
      v-else-if="tweetError || commentError"
      class="p-8 text-center text-destructive"
    >
      <p>加载推文失败。</p>
      <p class="text-sm mt-2">
        {{ tweetError || commentError || '' }}
      </p>
    </div>

    <div v-else-if="tweet">
      <TweetCard
        :tweet="tweet"
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
      <CommentSection
        :comments="comments"
        :post-id="tweet.post_id"
        @like-comment="handleLikeTweetComment"
        @submit-reply="handleReplyTweetComment"
        @send-reply="handleTweetComment"
      />
    </div>

    <div
      v-else
      class="p-8 text-center text-muted-foreground"
    >
      <p>此推文不存在或已被删除。</p>
    </div>
  </div>
</template>


