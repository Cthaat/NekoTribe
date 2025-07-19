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

// --- 处理事件 ---

function handleDeleteTweet(tweetId) {
  console.log('Delete tweet:', tweetId);
}

function handleReplyTweet(tweet) {
  console.log('Reply to tweet:', tweet.tweetId);
}

function handleRetweetTweet(tweet) {
  console.log('Retweet:', tweet.tweetId);
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
    <TweetCard
      v-else-if="tweet"
      :tweet="tweet"
      @delete-tweet="handleDeleteTweet"
      @reply-tweet="handleReplyTweet"
      @retweet-tweet="handleRetweetTweet"
      @like-tweet="handleLikeTweet"
      @bookmark-tweet="handleBookmarkTweet"
    />

    <!-- 8. (可选) 添加一个推文不存在的最终状态 -->
    <div
      v-else
      class="p-8 text-center text-muted-foreground"
    >
      <p>此推文不存在或已被删除。</p>
    </div>
  </div>
</template>
