<script setup lang="ts">
import { computed } from 'vue';
import {
  Card,
  CardContent,
  CardFooter,
  CardHeader
} from '@/components/ui/card';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Button } from '@/components/ui/button';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger
} from '@/components/ui/dropdown-menu';

import {
  MessageCircle,
  Repeat,
  Heart,
  MoreHorizontal,
  Trash2,
  BadgeCheck,
  Bookmark
} from 'lucide-vue-next';

// 假设这是从你的状态管理或认证 context 中获取的当前登录用户ID
const currentUserId = 1120;

const props = defineProps({
  tweet: {
    type: Object,
    required: true
  }
});

// 计算属性，判断这条推文是否属于当前登录用户
const isOwnTweet = computed(
  () => props.tweet.authorId === currentUserId
);

// 将媒体ID字符串转换为URL数组
// 这里我们假设媒体文件存放在 /media/ 目录下，并以 .png 结尾
const mediaUrls = computed(() => {
  if (!props.tweet.media) return [];
  return props.tweet.media
    .split(',')
    .map((id: string) => `/media/${id}.png`);
});

// 格式化时间戳
const formattedDate = computed(() => {
  return new Date(props.tweet.createdAt).toLocaleString(
    'zh-CN',
    {
      hour: '2-digit',
      minute: '2-digit',
      year: 'numeric',
      month: 'long',
      day: 'numeric'
    }
  );
});

// 处理交互事件的函数（此处为示例）
function handleReply() {
  console.log('Reply to tweet:', props.tweet.tweetId);
}

function handleRetweet() {
  console.log('Retweet tweet:', props.tweet.tweetId);
}

function handleLike() {
  console.log('Like tweet:', props.tweet.tweetId);
}

function handleDelete() {
  if (isOwnTweet.value) {
    alert(`确定要删除推文 ${props.tweet.tweetId} 吗？`);
    // 在这里调用你的API来删除推文
    console.log('Deleting tweet:', props.tweet.tweetId);
  }
}
</script>

<template>
  <Card
    class="max-w-2xl mx-auto my-4 rounded-xl shadow-sm hover:shadow-md transition-shadow"
  >
    <CardHeader class="flex flex-row items-start p-4">
      <Avatar class="h-12 w-12 mr-4">
        <AvatarImage
          :src="tweet.avatarUrl"
          :alt="tweet.username"
        />
        <AvatarFallback>{{
          tweet.username.substring(0, 2).toUpperCase()
        }}</AvatarFallback>
      </Avatar>
      <div class="flex-1">
        <div class="flex items-center gap-2">
          <h3 class="font-bold text-base">
            {{ tweet.displayName }}
          </h3>
          <BadgeCheck
            v-if="tweet.isVerified"
            class="h-5 w-5 text-blue-500"
          />
          <span class="text-sm text-muted-foreground"
            >@{{ tweet.username }}</span
          >
        </div>
        <p class="text-xs text-muted-foreground">
          {{ formattedDate }}
        </p>
      </div>
      <DropdownMenu v-if="isOwnTweet">
        <DropdownMenuTrigger as-child>
          <Button
            variant="ghost"
            size="icon"
            class="h-8 w-8"
          >
            <MoreHorizontal class="h-4 w-4" />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent>
          <DropdownMenuItem
            @click="handleDelete"
            class="text-blue-500"
          >
            <Bookmark class="mr-2 h-4 w-4" />
            <span>加入书签</span>
          </DropdownMenuItem>
          <DropdownMenuItem
            @click="handleDelete"
            class="text-red-500"
          >
            <Trash2 class="mr-2 h-4 w-4" />
            <span>删除推文</span>
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </CardHeader>

    <CardContent class="px-4 pb-2">
      <p class="whitespace-pre-wrap text-base">
        {{ tweet.content }}
      </p>

      <!-- 媒体展示区 -->
      <div
        v-if="mediaUrls.length > 0"
        class="mt-3 rounded-lg overflow-hidden border"
      >
        <div
          class="grid gap-px"
          :class="{
            'grid-cols-1': mediaUrls.length === 1,
            'grid-cols-2': mediaUrls.length > 1,
            'grid-rows-2 h-64 sm:h-80': mediaUrls.length > 2
          }"
        >
          <div
            v-for="(url, index) in mediaUrls.slice(0, 4)"
            :key="index"
            class="relative"
          >
            <img
              :src="url"
              class="object-cover w-full h-full"
              alt="推文媒体"
            />
            <div
              v-if="mediaUrls.length > 4 && index === 3"
              class="absolute inset-0 bg-black/50 flex items-center justify-center"
            >
              <span class="text-white text-2xl font-bold"
                >+{{ mediaUrls.length - 4 }}</span
              >
            </div>
          </div>
        </div>
      </div>
    </CardContent>

    <CardFooter class="flex justify-around p-2">
      <Button
        variant="ghost"
        size="sm"
        class="flex items-center gap-2 text-muted-foreground hover:text-green-500"
        @click="handleRetweet"
      >
        <Repeat class="h-5 w-5" />
        <span>{{ tweet.retweetsCount }}</span>
      </Button>
      <Button
        variant="ghost"
        size="sm"
        class="flex items-center gap-2 text-muted-foreground hover:text-blue-500"
        @click="handleReply"
      >
        <MessageCircle class="h-5 w-5" />
        <span>{{ tweet.repliesCount }}</span>
      </Button>
      <Button
        variant="ghost"
        size="sm"
        class="flex items-center gap-2 text-muted-foreground hover:text-red-500"
        @click="handleLike"
      >
        <Heart class="h-5 w-5" />
        <span>{{ tweet.likesCount }}</span>
      </Button>
    </CardFooter>
  </Card>
</template>

<style scoped>
/* 添加一些额外的样式来优化布局 */
.grid-rows-2 {
  grid-template-rows: repeat(2, minmax(0, 1fr));
}
</style>
