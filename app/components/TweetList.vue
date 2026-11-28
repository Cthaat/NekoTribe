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
    keyboardNavigation?: boolean;
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
  action: 'mark' | 'unmark', settle: (saved?: boolean) => void
) {
  emit('bookmark-tweet', tweet, action, settle);
}
</script>

<template>
  <TransitionGroup name="w3-list" tag="div" class="relative mx-3 space-y-3 py-2 sm:mx-0">
    <div v-for="tweet in props.tweets" :key="tweet.id">
      <TweetCard
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
        :keyboard-navigation="keyboardNavigation"
      />
    </div>
  </TransitionGroup>
</template>



