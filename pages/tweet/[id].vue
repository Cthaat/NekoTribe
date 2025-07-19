<script setup>
import TweetCard from '@/components/TweetCard.vue';
import TweetCardSkeleton from '@/components/TweetCardSkeleton.vue';
import {
  Pagination,
  PaginationContent,
  PaginationEllipsis,
  PaginationItem,
  PaginationNext,
  PaginationPrevious
} from '@/components/ui/pagination';
import { apiFetch } from '@/composables/useApi';
import { useRoute } from 'vue-router';
import { toast } from 'vue-sonner';

const route = useRoute();

// 获取路径参数
const { data, pending, error } = useApiFetch(
  `/api/v1/tweets/${route.params.id}`
);

const tweet = computed(() => {
  // data.value 是 API 返回的完整响应
  // 根据您给的 JSON，推文在 data.value.data.tweet
  return data.value &&
    data.value.data &&
    data.value.data.tweet
    ? data.value.data.tweet
    : null;
});

// --- 转发相关的状态 ---

const isRetweetModalOpen = ref(false);
const selectedTweetForRetweet = ref(null);
const isSubmittingRetweet = ref(false);

// --- 处理事件 ---

function handleDeleteTweet(tweetId) {
  console.log('Delete tweet:', tweetId);
}

function handleReplyTweet(tweet) {
  console.log('Reply to tweet:', tweet.tweetId);
}

function handleRetweetTweet(tweet) {
  console.log('Retweet:', tweet.tweetId);
  selectedTweetForRetweet.value = tweet;
  isRetweetModalOpen.value = true;
}

// 这个函数由 RetweetModal 的 @submit-retweet 事件触发
async function handleSubmitRetweet({
  content,
  originalTweetId
}) {
  isSubmittingRetweet.value = true;
  try {
    const response = await apiFetch(
      '/api/v1/tweets/send-tweets',
      {
        method: 'POST',
        body: {
          content: content, // 用户的评论
          replyToTweetId: '', // 告知后端这是对哪条推文的转发
          retweetOfTweetId: originalTweetId, // 告知后端这是对哪条推文的转发
          quoteTweetId: '', // 如果是引用转发，这里可以传入原推文ID
          visibility: 'public', // 可选：设置可见性
          hashtags: '', // 可选：设置标签
          mentions: '', // 可选：设置提及用户
          scheduledAt: '', // 可选：设置定时发送时间
          location: '' // 可选：设置位置
        }
      }
    );

    console.log(
      'Submitting retweet with content:',
      content,
      'Original tweet ID:',
      originalTweetId
    );

    toast.success('转发成功！');

    if (!response.success) {
      throw new Error(response.message || '转发失败');
    }

    toast.success('转发成功！');
    isRetweetModalOpen.value = false; // 关闭模态框
    // 可选：刷新数据或乐观更新UI
  } catch (err) {
    console.error('Failed to retweet:', err);
    toast.error(err.message || '转发失败，请稍后重试。');
  } finally {
    isSubmittingRetweet.value = false;
    isRetweetModalOpen.value = false; // 确保模态框关闭
  }
}

function handleLikeTweet(tweet, action) {
  console.log(
    'Liking tweet:',
    tweet.tweetId,
    'Action:',
    action
  );
}

function handleBookmarkTweet(tweet, action) {
  console.log(
    'Bookmarking tweet:',
    tweet.tweetId,
    'Action:',
    action
  );
}
</script>

<template>
  <div class="bg-background pt-4">
    <!-- 5. 根据 pending 状态来条件渲染 -->
    <div v-if="pending">
      <TweetCardSkeleton />
    </div>

    <!-- 6. 添加一个错误状态的显示 -->
    <div
      v-else-if="error"
      class="p-8 text-center text-destructive"
    >
      <p>加载推文失败。</p>
      <p class="text-sm mt-2">{{ error.message }}</p>
    </div>

    <!-- 7. 当数据加载成功后，显示 TweetCard -->
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
    </div>

    <!-- 8. (可选) 添加一个推文不存在的最终状态 -->
    <div
      v-else
      class="p-8 text-center text-muted-foreground"
    >
      <p>此推文不存在或已被删除。</p>
    </div>
  </div>
</template>
