<script setup lang="ts">
import TweetCard from '@/components/TweetCard.vue';
import type { PostVM } from '@/types/posts';

// 接收父组件传来的数据
const props = defineProps<{
  tweets: PostVM[];
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

function handleReplyTweet(tweet: PostVM) {
  emit('reply-tweet', tweet);
}

function handleRetweetTweet(tweet: PostVM) {
  emit('retweet-tweet', tweet);
}

function handleLikeTweet(
  tweet: PostVM,
  action: 'like' | 'unlike'
) {
  emit('like-tweet', tweet, action);
}

function handleBookmarkTweet(
  tweet: PostVM,
  action: 'mark' | 'unmark'
) {
  emit('bookmark-tweet', tweet, action);
}
</script>

<template>
  <div class="bg-background">
    <div
      v-for="tweet in props.tweets"
      :key="tweet.id"
    >
      <TweetCard
        @delete-tweet="handleDeleteTweet"
        @reply-tweet="handleReplyTweet"
        @retweet-tweet="handleRetweetTweet"
        @like-tweet="handleLikeTweet"
        @bookmark-tweet="handleBookmarkTweet"
        :key="tweet.id"
        :tweet="tweet"
      />
    </div>
  </div>
</template>



