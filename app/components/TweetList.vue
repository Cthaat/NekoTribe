<script setup lang="ts">
import TweetCard from '@/components/TweetCard.vue';
import type { V2Post } from '@/types/v2';
import {
  Pagination,
  PaginationContent,
  PaginationEllipsis,
  PaginationItem,
  PaginationNext,
  PaginationPrevious
} from '@/components/ui/pagination';

// 接收父组件传来的数据
const props = defineProps<{
  tweets: V2Post[];
}>();

const emit = defineEmits([
  'delete-tweet',
  'reply-tweet',
  'retweet-tweet',
  'like-tweet',
  'bookmark-tweet'
]);

function handleDeleteTweet(tweetId: number) {
  emit('delete-tweet', tweetId);
}

function handleReplyTweet(tweet: V2Post) {
  emit('reply-tweet', tweet);
}

function handleRetweetTweet(tweet: V2Post) {
  emit('retweet-tweet', tweet);
}

function handleLikeTweet(
  tweet: V2Post,
  action: 'like' | 'unlike'
) {
  emit('like-tweet', tweet, action);
}

function handleBookmarkTweet(
  tweet: V2Post,
  action: 'mark' | 'unmark'
) {
  emit('bookmark-tweet', tweet, action);
}
</script>

<template>
  <div class="bg-background">
    <div
      v-for="tweet in props.tweets"
      :key="tweet.post_id"
    >
      <TweetCard
        @delete-tweet="handleDeleteTweet"
        @reply-tweet="handleReplyTweet"
        @retweet-tweet="handleRetweetTweet"
        @like-tweet="handleLikeTweet"
        @bookmark-tweet="handleBookmarkTweet"
        :key="tweet.post_id"
        :tweet="tweet"
      />
    </div>
  </div>
</template>



