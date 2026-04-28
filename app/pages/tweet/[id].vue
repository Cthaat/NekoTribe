<script lang="ts" setup>
import { computed, ref } from 'vue';
import type {
  CommentVM,
  PostVM
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

const tweet = ref<PostVM | null>(null);
const comments = ref<CommentVM[]>([]);
const tweetPending = ref(false);
const commentPending = ref(false);
const tweetError = ref<string | null>(null);
const commentError = ref<string | null>(null);

const isRetweetModalOpen = ref(false);
const selectedTweetForRetweet = ref<PostVM | null>(null);
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
        pageSize: 100,
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
      `/tweet/home/${preferenceStore.preferences.user.id}`
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

function handleReplyTweet(tweetItem: PostVM): void {
}

function handleRetweetTweet(tweetItem: PostVM): void {
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
  tweetItem: PostVM,
  action: 'like' | 'unlike'
) {
  try {
    const result =
      action === 'like'
        ? await v2LikePost(tweetItem.id)
        : await v2UnlikePost(tweetItem.id);
    if (tweet.value && tweet.value.id === tweetItem.id) {
      tweet.value = {
        ...tweet.value,
        viewer: {
          ...tweet.value.viewer,
          hasLiked: result.isLiked
        },
        counts: {
          ...tweet.value.counts,
          likes: result.likesCount
        }
      };
    }
  } catch (error) {
    console.error('Failed to like/unlike tweet:', error);
  }
}

async function handleBookmarkTweet(
  tweetItem: PostVM,
  action: 'mark' | 'unmark'
) {
  try {
    const result =
      action === 'mark'
        ? await v2BookmarkPost(tweetItem.id)
        : await v2UnbookmarkPost(tweetItem.id);
    if (tweet.value && tweet.value.id === tweetItem.id) {
      tweet.value = {
        ...tweet.value,
        viewer: {
          ...tweet.value.viewer,
          hasBookmarked: result.isBookmarked
        }
      };
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
      item => item.id === commentId
    );
    if (index !== -1) {
      const currentComment = comments.value[index];
      if (!currentComment) return;
      comments.value[index] = {
        ...currentComment,
        viewer: {
          ...currentComment.viewer,
          hasLiked: result.isLiked
        },
        counts: {
          ...currentComment.counts,
          likes: result.likesCount
        }
      };
    }
  } catch (error) {
    console.error('Failed to like comment:', error);
    toast.error('点赞评论失败，请稍后重试。');
  }
}

async function handleTweetComment(content: string) {
  if (!tweet.value) return;
  try {
    await v2CreateComment(tweet.value.id, {
      content,
      parentCommentId: null
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
    await v2CreateComment(tweet.value.id, {
      content,
      parentCommentId
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
        :post-id="tweet.id"
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
