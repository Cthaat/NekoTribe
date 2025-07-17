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

console.log(
  'TweetList component initialized with tweets:',
  props.tweets
);
</script>

<template>
  <div class="bg-background p-10">
    <TweetCard
      v-for="tweet in props.tweets"
      :key="tweet.id"
      :tweet="tweet"
    />
  </div>
</template>
