<script setup lang="ts">
import { computed } from 'vue';
import { toast } from 'vue-sonner';
import {
  Card,
  CardContent,
  CardFooter,
  CardHeader
} from '@/components/ui/card';
import Lightbox from '@/components/Lightbox.vue';
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
  Bookmark,
  BookmarkCheck,
  BookmarkPlus,
  PlayCircle,
  HeartPlus
} from 'lucide-vue-next';
import { useTweetStore } from '@/stores/tweetStore'; // 1. 引入 store

const preferenceStore = usePreferenceStore();
const tweetStore = useTweetStore(); // 2. 获取 store 实例

const localePath = useLocalePath();

const emit = defineEmits([
  'delete-tweet',
  'reply-tweet',
  'retweet-tweet',
  'like-tweet',
  'bookmark-tweet'
]);

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

const localLiked = ref(
  props.tweet.isLikedByUser === 1 || false
);

const likeCount = ref(props.tweet.likesCount);

watch(
  () => props.tweet.isLikedByUser,
  newValue => {
    localLiked.value = newValue === 1 || false;
  }
);

const localIsBookmarked = ref(
  props.tweet.isBookmarkedByUser === 1 || false
);

// 【修改二：添加 watch 来同步 prop 和本地 ref】
// 当父组件的数据更新后，prop 会变化。我们需要监听这个变化，
watch(
  () => props.tweet.isBookmarkedByUser,
  newValue => {
    localIsBookmarked.value = newValue === 1 || false;
  }
);

// 处理交互事件的函数（此处为示例）
function handleReply() {
  console.log('Common to tweet:', props.tweet.tweetId);
  emit('reply-tweet', props.tweet);
}

function handleRetweet() {
  console.log('Retweet tweet:', props.tweet.tweetId);
  emit('retweet-tweet', props.tweet);
}

function handleLike() {
  console.log('Like tweet:', props.tweet.tweetId);
  localLiked.value = !localLiked.value; // 切换喜欢状态
  likeCount.value += localLiked.value ? 1 : -1; // 更新喜欢计数
  if (localLiked.value) {
    toast.success('已点赞此推文');
  }
  emit(
    'like-tweet',
    props.tweet,
    localLiked.value ? 'like' : 'unlike'
  );
}

function handleDelete() {
  if (isOwnTweet.value) {
    alert(`确定要删除推文 ${props.tweet.tweetId} 吗？`);
    // 在这里调用你的API来删除推文
    console.log('Deleting tweet:', props.tweet.tweetId);
    emit('delete-tweet', props.tweet.tweetId);
  }
}

function handleBookmark() {
  console.log('Bookmark tweet:', props.tweet.tweetId);
  localIsBookmarked.value = !localIsBookmarked.value;
  emit(
    'bookmark-tweet',
    props.tweet,
    localIsBookmarked.value ? 'unbookmark' : 'bookmark'
  );
}

console.log(
  'TweetCard component initialized with tweet:',
  props.tweet,
  'Is own tweet:',
  isOwnTweet.value
);

const isLightboxOpen = ref(false);
const lightboxStartIndex = ref(0);

// 3. 【核心修改】创建一个方法来打开灯箱
function openLightbox(index: number) {
  lightboxStartIndex.value = index; // 设置从哪张图片开始显示
  isLightboxOpen.value = true; // 打开灯箱
}

function toTweetDetail(tweetId: string) {
  console.log('Navigating to tweet detail:', tweetId);
  // 在这里实现导航到推文详情的逻辑
  // 例如使用 Vue Router 的 push 方法
  const detailPath = localePath(`/tweet/${tweetId}`);
  tweetStore.setSelectedTweet(props.tweet);
  navigateTo(detailPath);
}
</script>

<template>
  <Card
    @click.stop="toTweetDetail(tweet.tweetId)"
    class="max-w-2xl mx-auto my-4 rounded-xl shadow-sm cursor-pointer transition-colors duration-200 ease-in-out hover:shadow-md hover:bg-gray-50 dark:hover:bg-neutral-900"
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
      <DropdownMenu>
        <DropdownMenuTrigger as-child>
          <Button
            variant="ghost"
            size="icon"
            class="h-8 w-8"
            @click.stop="() => {}"
          >
            <MoreHorizontal class="h-4 w-4" />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent>
          <DropdownMenuItem
            v-if="!localIsBookmarked"
            @click.stop="handleBookmark"
            class="text-blue-500"
          >
            <BookmarkPlus class="mr-2 h-4 w-4" />
            <span>加入书签</span>
          </DropdownMenuItem>

          <DropdownMenuItem
            v-else
            @click.stop="handleBookmark"
            class="text-blue-500"
          >
            <BookmarkCheck class="mr-2 h-4 w-4" />
            <span>删除书签</span>
          </DropdownMenuItem>

          <DropdownMenuItem
            v-if="isOwnTweet"
            @click.stop="handleDelete"
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
            @click.stop="openLightbox(index)"
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
        @click.stop="handleRetweet"
      >
        <Repeat class="h-5 w-5" />
        <span>{{ tweet.retweetsCount }}</span>
      </Button>

      <Button
        variant="ghost"
        size="sm"
        class="flex items-center gap-2 text-muted-foreground hover:text-blue-500"
        @click.stop="handleReply"
      >
        <MessageCircle class="h-5 w-5" />
        <span>{{ tweet.repliesCount }}</span>
      </Button>

      <Button
        variant="ghost"
        size="sm"
        class="flex items-center gap-2 text-muted-foreground hover:text-red-500"
        @click.stop="handleLike"
      >
        <Heart v-if="localLiked" class="h-5 w-5" />
        <HeartPlus v-else class="h-5 w-5" />
        <span>{{ likeCount }}</span>
      </Button>
    </CardFooter>
  </Card>
  <Lightbox
    v-if="mediaItems.length > 0"
    v-model:open="isLightboxOpen"
    :items="mediaItems"
    :start-index="lightboxStartIndex"
  />
</template>

<style scoped>
/* 添加一些额外的样式来优化布局 */
.grid-rows-2 {
  grid-template-rows: repeat(2, minmax(0, 1fr));
}
</style>
