<script setup lang="ts">
import { computed } from 'vue';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import type { PreviewPostVM } from '@/types/posts';

const props = defineProps<{
  tweet: PreviewPostVM;
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
  <div class="mt-2 rounded-lg border bg-background/60 p-3">
    <div class="flex items-center text-sm mb-1">
      <Avatar class="h-5 w-5 mr-2">
        <AvatarImage
          :src="tweet.author.avatarUrl"
          :alt="tweet.author.name"
        />
        <AvatarFallback>{{
          tweet.author.username.substring(0, 1)
        }}</AvatarFallback>
      </Avatar>
      <span class="font-bold">{{
        tweet.author.name
      }}</span>
      <span class="ml-1 text-muted-foreground"
        >@{{ tweet.author.username }}</span
      >
    </div>
    <p class="text-muted-foreground text-sm leading-snug">
      {{ truncatedContent }}
    </p>
  </div>
</template>
