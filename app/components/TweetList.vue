<script setup lang="ts">
import TweetCard from '@/components/TweetCard.vue';
import type { PostVM } from '@/types/posts';

const props = withDefaults(
  defineProps<{
    tweets: PostVM[];
    showRelationContext?: boolean;
    pinnedPostId?: number;
    canManageProfilePin?: boolean;
    profilePinPending?: boolean;
  }>(),
  {
    showRelationContext: true
  }
);

const emit = defineEmits([
  'delete-tweet',
  'reply-tweet',
  'retweet-tweet',
  'like-tweet',
  'bookmark-tweet',
  'toggle-profile-pin'
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
  <TransitionGroup name="feed" tag="div" class="space-y-3 px-3 py-2 sm:px-0">
    <TweetCard
      v-for="tweet in props.tweets"
      :key="tweet.id"
      @delete-tweet="handleDeleteTweet"
      @reply-tweet="handleReplyTweet"
      @retweet-tweet="handleRetweetTweet"
      @like-tweet="handleLikeTweet"
      @bookmark-tweet="handleBookmarkTweet"
      @toggle-profile-pin="emit('toggle-profile-pin',$event)"
      :tweet="tweet"
      :show-relation-context="showRelationContext"
      :pinned-on-profile="tweet.id === pinnedPostId"
      :can-manage-profile-pin="canManageProfilePin"
      :profile-pin-pending="profilePinPending"
    />
  </TransitionGroup>
</template>



