<script setup lang="ts">
import { computed } from 'vue';
import { useRouter } from 'vue-router';

const props = defineProps<{
  content: string;
}>();

const router = useRouter();
const localePath = useLocalePath();

interface ContentSegment {
  type: 'text' | 'mention' | 'hashtag' | 'url';
  content: string;
  link?: string;
}

const parsedContent = computed<ContentSegment[]>(() => {
  const segments: ContentSegment[] = [];
  const content = props.content || '';

  const pattern =
    /(@\[(\d+):([\p{L}\p{N}_-]+)\])|(@[\p{L}\p{N}_-]+)|(#[\p{L}\p{N}_]+)|(https?:\/\/[^\s]+)/gu;

  let lastIndex = 0;
  let match;

  while ((match = pattern.exec(content)) !== null) {
    if (match.index > lastIndex) {
      segments.push({
        type: 'text',
        content: content.substring(lastIndex, match.index)
      });
    }

    if (match[1]) {
      const userId = match[2];
      const username = match[3];
      segments.push({
        type: 'mention',
        content: `@${username}`,
        link: localePath(`/user/${userId}/profile`)
      });
    } else if (match[4]) {
      const username = match[4].substring(1);
      segments.push({
        type: 'mention',
        content: match[4],
        link: localePath(`/user/${username}`)
      });
    } else if (match[5]) {
      segments.push({
        type: 'hashtag',
        content: match[5],
        link: localePath(
          `/tweet/search/${encodeURIComponent(match[5])}`
        )
      });
    } else if (match[6]) {
      segments.push({
        type: 'url',
        content: match[6],
        link: match[6]
      });
    }

    lastIndex = pattern.lastIndex;
  }

  if (lastIndex < content.length) {
    segments.push({
      type: 'text',
      content: content.substring(lastIndex)
    });
  }

  return segments;
});

function handleClick(segment: ContentSegment): void {
  if (!segment.link) return;

  if (segment.type === 'url') {
    window.open(segment.link, '_blank', 'noopener,noreferrer');
  } else {
    router.push(segment.link);
  }
}
</script>

<template>
  <span class="whitespace-pre-wrap break-words text-foreground">
    <template
      v-for="(segment, index) in parsedContent"
      :key="index"
    >
      <span v-if="segment.type === 'text'">{{
        segment.content
      }}</span>

      <span
        v-else-if="segment.type === 'mention'"
        class="cursor-pointer font-medium text-sky-600 underline-offset-2 transition-colors hover:text-sky-500 hover:underline dark:text-sky-400 dark:hover:text-sky-300"
        @click.stop="handleClick(segment)"
      >
        {{ segment.content }}
      </span>

      <span
        v-else-if="segment.type === 'hashtag'"
        class="cursor-pointer font-medium text-sky-600 underline-offset-2 transition-colors hover:text-sky-500 hover:underline dark:text-sky-400 dark:hover:text-sky-300"
        @click.stop="handleClick(segment)"
      >
        {{ segment.content }}
      </span>

      <span
        v-else-if="segment.type === 'url'"
        class="cursor-pointer break-all text-sky-600 underline-offset-2 transition-colors hover:text-sky-500 hover:underline dark:text-sky-400 dark:hover:text-sky-300"
        @click.stop="handleClick(segment)"
      >
        {{ segment.content }}
      </span>
    </template>
  </span>
</template>
