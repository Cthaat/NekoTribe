<script setup>
import TweetCard from '@/components/TweetCard.vue';
import {
  Pagination,
  PaginationContent,
  PaginationEllipsis,
  PaginationItem,
  PaginationNext,
  PaginationPrevious
} from '@/components/ui/pagination';

// 接收父组件传来的数据
const props = defineProps({
  tweets: {
    type: Array,
    required: true
  }
});

const emit = defineEmits([
  'delete-tweet',
  'reply-tweet',
  'retweet-tweet',
  'like-tweet'
]);

function handleDeleteTweet(tweetId) {
  emit('delete-tweet', tweetId);
}

function handleReplyTweet(tweet) {
  emit('reply-tweet', tweet);
}

function handleRetweetTweet(tweet) {
  emit('retweet-tweet', tweet);
}

function handleLikeTweet(tweet) {
  emit('like-tweet', tweet);
}

console.log(
  'TweetList component initialized with tweets:',
  props.tweets
);
</script>

<template>
  <div class="bg-background">
    <TweetCard
      @delete-tweet="handleDeleteTweet"
      @reply-tweet="handleReplyTweet"
      @retweet-tweet="handleRetweetTweet"
      @like-tweet="handleLikeTweet"
      v-for="tweet in props.tweets"
      :key="tweet.id"
      :tweet="tweet"
    />
  </div>
</template>
