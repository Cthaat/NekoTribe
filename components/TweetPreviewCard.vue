<script setup lang="ts">
import { computed } from 'vue';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';

// 定义预览卡片所需的最少数据结构
interface PreviewTweet {
  author: {
    displayName: string;
    username: string;
    avatarUrl: string;
  };
  content: string;
}

const props = defineProps<{
  tweet: PreviewTweet;
}>();

// 截断过长的内容以适应紧凑的布局
const truncatedContent = computed(() => {
  if (props.tweet.content.length > 100) {
    return props.tweet.content.substring(0, 100) + '...';
  }
  return props.tweet.content;
});
</script>

<template>
  <div class="mt-2 p-3 border border-gray-700 rounded-lg">
    <div class="flex items-center text-sm mb-1">
      <Avatar class="h-5 w-5 mr-2">
        <AvatarImage
          :src="tweet.author.avatarUrl"
          :alt="tweet.author.displayName"
        />
        <AvatarFallback>{{
          tweet.author.username.substring(0, 1)
        }}</AvatarFallback>
      </Avatar>
      <span class="font-bold text-gray-200">{{
        tweet.author.displayName
      }}</span>
      <span class="ml-1 text-gray-500"
        >@{{ tweet.author.username }}</span
      >
    </div>
    <p class="text-gray-400 text-sm leading-snug">
      {{ truncatedContent }}
    </p>
  </div>
</template>
