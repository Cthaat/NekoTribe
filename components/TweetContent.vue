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

// 解析推文内容，识别 @mentions, #hashtags 和 URLs
const parsedContent = computed<ContentSegment[]>(() => {
  const segments: ContentSegment[] = [];
  const content = props.content || '';

  // 正则表达式匹配:
  // - @[userId:username] (带userId的提及)
  // - @username (普通提及)
  // - #hashtag
  // - URLs
  const pattern =
    /(@\[(\d+):(\w+)\])|(@\w+)|(#\w+)|(https?:\/\/[^\s]+)/g;

  let lastIndex = 0;
  let match;

  while ((match = pattern.exec(content)) !== null) {
    // 添加前面的普通文本
    if (match.index > lastIndex) {
      segments.push({
        type: 'text',
        content: content.substring(lastIndex, match.index)
      });
    }

    // 添加匹配的特殊内容
    if (match[1]) {
      // @[userId:username] 格式的提及
      const userId = match[2];
      const username = match[3];
      segments.push({
        type: 'mention',
        content: `@${username}`,
        link: localePath(`/user/${userId}/profile`)
      });
    } else if (match[4]) {
      // @username 普通提及（没有userId，只能跳转到username）
      const username = match[4].substring(1); // 移除 @
      segments.push({
        type: 'mention',
        content: match[4],
        link: localePath(`/user/${username}`)
      });
    } else if (match[5]) {
      // #hashtag
      segments.push({
        type: 'hashtag',
        content: match[5],
        link: `/search?q=${encodeURIComponent(match[5])}`
      });
    } else if (match[6]) {
      // URL
      segments.push({
        type: 'url',
        content: match[6],
        link: match[6]
      });
    }

    lastIndex = pattern.lastIndex;
  }

  // 添加剩余的普通文本
  if (lastIndex < content.length) {
    segments.push({
      type: 'text',
      content: content.substring(lastIndex)
    });
  }

  return segments;
});

// 处理点击事件
function handleClick(segment: ContentSegment) {
  if (!segment.link) return;

  if (segment.type === 'url') {
    // 外部链接在新窗口打开
    window.open(segment.link, '_blank');
  } else {
    // 内部链接使用路由跳转
    router.push(segment.link);
  }
}
</script>

<template>
  <span class="whitespace-pre-wrap break-words">
    <template
      v-for="(segment, index) in parsedContent"
      :key="index"
    >
      <!-- 普通文本 -->
      <span v-if="segment.type === 'text'">{{
        segment.content
      }}</span>

      <!-- @mention -->
      <span
        v-else-if="segment.type === 'mention'"
        class="text-blue-500 hover:text-blue-400 hover:underline cursor-pointer font-medium"
        @click="handleClick(segment)"
      >
        {{ segment.content }}
      </span>

      <!-- #hashtag -->
      <span
        v-else-if="segment.type === 'hashtag'"
        class="text-blue-500 hover:text-blue-400 hover:underline cursor-pointer font-medium"
        @click="handleClick(segment)"
      >
        {{ segment.content }}
      </span>

      <!-- URL -->
      <span
        v-else-if="segment.type === 'url'"
        class="text-blue-500 hover:text-blue-400 hover:underline cursor-pointer"
        @click="handleClick(segment)"
      >
        {{ segment.content }}
      </span>
    </template>
  </span>
</template>
