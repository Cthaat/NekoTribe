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

const preferenceStore = usePreferenceStore();

// 假设这是从你的状态管理或认证 context 中获取的当前登录用户ID
const currentUserId =
  preferenceStore.preferences.user.userId;

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

const mediaItems = computed(() => {
  const files = props.tweet.mediaFiles?.split(',') || [];
  const thumbnails =
    props.tweet.mediaThumbnails?.split(',') || [];

  // 如果没有文件，返回空数组
  if (files.length === 0) {
    return [];
  }

  return files.map((fileUrl: string, index: number) => {
    // 根据文件扩展名判断媒体类型
    const isVideo = fileUrl.toLowerCase().endsWith('.mp4');

    return {
      type: isVideo ? 'video' : 'image',
      originalUrl: fileUrl,
      // 如果有对应的缩略图，就使用它；否则，对于图片，可以直接用原始 URL 作为缩略图
      thumbnailUrl:
        thumbnails[index] || (isVideo ? '' : fileUrl)
    };
  });
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

console.log(
  'TweetCard component initialized with tweet:',
  props.tweet,
  'Is own tweet:',
  isOwnTweet.value
);
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
        v-if="mediaItems.length > 0"
        class="mt-3 rounded-lg overflow-hidden border"
      >
        <div
          class="grid gap-px"
          :class="{
            'grid-cols-1': mediaItems.length === 1,
            'grid-cols-2': mediaItems.length >= 2,
            // 只有当图片多于 2 张时，才启用更复杂的 2x2 布局
            'grid-rows-2 h-64 sm:h-80':
              mediaItems.length > 2
          }"
        >
          <!-- 只显示前 4 个媒体项 -->
          <div
            v-for="(item, index) in mediaItems.slice(0, 4)"
            :key="item.originalUrl"
            class="relative group cursor-pointer bg-secondary"
          >
            <!-- 显示缩略图 -->
            <img
              :src="item.thumbnailUrl"
              class="object-cover w-full h-full transition-transform group-hover:scale-105"
              alt="推文媒体缩略图"
            />

            <!-- 如果是视频，在中间叠加一个播放图标 -->
            <div
              v-if="item.type === 'video'"
              class="absolute inset-0 flex items-center justify-center bg-black/30"
            >
              <PlayCircle class="h-12 w-12 text-white/80" />
            </div>

            <!-- 如果媒体项超过 4 个，在第四个上显示“+N”遮罩 -->
            <div
              v-if="mediaItems.length > 4 && index === 3"
              class="absolute inset-0 bg-black/60 flex items-center justify-center"
            >
              <span class="text-white text-2xl font-bold"
                >+{{ mediaItems.length - 4 }}</span
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
