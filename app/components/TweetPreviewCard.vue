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

const truncatedContent = computed(() => {
  if (props.tweet.content.length > 140) {
    return props.tweet.content.substring(0, 140).trimEnd() + '…';
  }
  return props.tweet.content;
});

const fallbackInitial = computed(() => {
  const source = props.tweet.author.name || props.tweet.author.username || '?';
  return source.slice(0, 1).toUpperCase();
});
</script>

<template>
  <div
    class="mt-2 rounded-lg border border-border/60 bg-muted/30 p-3 transition-colors hover:border-border hover:bg-muted/50"
  >
    <div class="flex items-center gap-2 text-sm">
      <Avatar class="h-6 w-6 shrink-0 ring-1 ring-border">
        <AvatarImage
          :src="tweet.author.avatarUrl"
          :alt="tweet.author.name"
        />
        <AvatarFallback class="text-[10px] font-medium">
          {{ fallbackInitial }}
        </AvatarFallback>
      </Avatar>
      <div class="flex min-w-0 items-center gap-1">
        <span class="truncate text-sm font-semibold leading-none">
          {{ tweet.author.name }}
        </span>
        <span class="truncate text-xs text-muted-foreground">
          @{{ tweet.author.username }}
        </span>
      </div>
    </div>
    <p
      class="mt-1.5 line-clamp-3 whitespace-pre-line text-sm leading-relaxed text-muted-foreground"
    >
      {{ truncatedContent }}
    </p>
  </div>
</template>
