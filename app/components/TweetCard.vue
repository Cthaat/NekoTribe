<script setup lang="ts">
import { computed } from 'vue';
import { toast } from 'vue-sonner';
import {
  v2GetPost,
  type PostVM
} from '@/services';
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
  BookmarkCheck,
  BookmarkPlus,
  PlayCircle
} from 'lucide-vue-next';
import { useTweetStore } from '@/stores/tweetStore'; // 1. 引入 store
import TweetContent from '@/components/TweetContent.vue';

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
  preferenceStore.preferences.user.id;

const props = defineProps<{
  tweet: PostVM;
}>();

// 计算属性，判断这条推文是否属于当前登录用户
const isOwnTweet = computed(
  () => props.tweet.author.id === currentUserId
);

const mediaItems = computed(() => {
  return props.tweet.media.map(media => {
    return {
      type: media.type,
      originalUrl: media.originalUrl,
      thumbnailUrl: media.thumbnailUrl
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
  props.tweet.viewer.hasLiked
);

const likeCount = ref(props.tweet.counts.likes);

watch(
  () => props.tweet.viewer.hasLiked,
  newValue => {
    localLiked.value = newValue;
  }
);

const localIsBookmarked = ref(
  props.tweet.viewer.hasBookmarked
);

// 【修改二：添加 watch 来同步 prop 和本地 ref】
// 当父组件的数据更新后，prop 会变化。我们需要监听这个变化，
watch(
  () => props.tweet.viewer.hasBookmarked,
  newValue => {
    localIsBookmarked.value = newValue;
  }
);

// 处理交互事件的函数（此处为示例）
function handleReply() {
  emit('reply-tweet', props.tweet);
}

function handleRetweet() {
  emit('retweet-tweet', props.tweet);
}

function handleLike() {
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
    alert(`确定要删除推文 ${props.tweet.id} 吗？`);
    // 在这里调用你的API来删除推文
    emit('delete-tweet', props.tweet.id);
  }
}

function handleBookmark() {
  localIsBookmarked.value = !localIsBookmarked.value;
  toast.success(
    localIsBookmarked.value
      ? '已添加到书签'
      : '已从书签中移除'
  );
  emit(
    'bookmark-tweet',
    props.tweet,
    localIsBookmarked.value ? 'mark' : 'unmark'
  );
}

const isLightboxOpen = ref(false);
const lightboxStartIndex = ref(0);

// 3. 【核心修改】创建一个方法来打开灯箱
function openLightbox(index: number) {
  lightboxStartIndex.value = index; // 设置从哪张图片开始显示
  isLightboxOpen.value = true; // 打开灯箱
}

function toTweetDetail(tweetId: string) {
  // 在这里实现导航到推文详情的逻辑
  // 例如使用 Vue Router 的 push 方法
  const detailPath = localePath(`/tweet/${tweetId}`);
  tweetStore.setSelectedTweet(props.tweet);
  navigateTo(detailPath);
}

// ------- 转推：原文信息懒加载（作者与摘要） -------
const originalTweet = ref<PostVM | null>(null);
const originalLoading = ref(false);
const originalError = ref<string | null>(null);

async function fetchOriginalTweet() {
  if (
    props.tweet.postType === 'repost' &&
    props.tweet.repostOfPostId
  ) {
    originalLoading.value = true;
    originalError.value = null;
    try {
      originalTweet.value = await v2GetPost(
        props.tweet.repostOfPostId
      );
    } catch (e) {
      originalError.value =
        e instanceof Error ? e.message : '加载原文失败';
      originalTweet.value = null;
    } finally {
      originalLoading.value = false;
    }
  } else {
    originalTweet.value = null;
    originalLoading.value = false;
    originalError.value = null;
  }
}

watch(
  () => [
    props.tweet.postType,
    props.tweet.repostOfPostId
  ],
  () => fetchOriginalTweet(),
  { immediate: true }
);

const originalAuthorHandle = computed(() => {
  return originalTweet.value?.author.username
    ? `@${originalTweet.value.author.username}`
    : '';
});

const originalExcerpt = computed(() => {
  const text: string = originalTweet.value?.content || '';
  const compact = text.replace(/\n+/g, ' ').trim();
  const max = 120;
  return compact.length > max
    ? compact.slice(0, max) + '…'
    : compact;
});
</script>

<template>
  <Card
    @click.stop="toTweetDetail(String(tweet.id))"
    class="border-none max-w-2xl mx-auto my-4 rounded-xl shadow-sm cursor-pointer transition-colors duration-200 ease-in-out hover:shadow-md hover:bg-gray-50 dark:hover:bg-neutral-900"
  >
    <CardHeader class="flex flex-row items-start p-4">
      <Avatar
        class="h-12 w-12 mr-4"
        @click.stop="
          () =>
            navigateTo(
              localePath(`/user/${tweet.author.id}/profile`)
            )
        "
      >
        <AvatarImage
          :src="tweet.author.avatarUrl"
          :alt="tweet.author.username"
        />
        <AvatarFallback>{{
          tweet.author.username.substring(0, 2).toUpperCase()
        }}</AvatarFallback>
      </Avatar>
      <div class="flex-1">
        <div class="flex items-center gap-2">
          <h3 class="font-bold text-base">
            {{ tweet.author.name }}
          </h3>
          <BadgeCheck
            v-if="tweet.author.verified"
            class="h-5 w-5 text-blue-500"
          />
          <span class="text-sm text-muted-foreground"
            >@{{ tweet.author.username }}</span
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
      <!-- 若为转发推文，展示“转推自 @xxx”与原文摘要预览 -->
      <div
        v-if="tweet.postType === 'repost'"
        class="mb-2 -mt-1 space-y-2"
      >
        <div class="flex items-center gap-2 text-xs">
          <Repeat class="h-4 w-4 text-green-600" />
          <template
            v-if="originalTweet && !originalLoading"
          >
            <span class="text-muted-foreground"
              >转推自</span
            >
            <NuxtLink
              :to="
                localePath(
                  `/user/${originalTweet.author.id}/profile`
                )
              "
              @click.stop
              class="text-blue-600 hover:underline"
            >
              {{ originalAuthorHandle || '@未知用户' }}
            </NuxtLink>
            <span class="text-muted-foreground">·</span>
            <NuxtLink
              :to="
                localePath(
                  `/tweet/${originalTweet.id}`
                )
              "
              @click.stop
              class="text-blue-600 hover:underline"
              >查看原文</NuxtLink
            >
          </template>
          <template v-else-if="originalLoading">
            <span class="text-muted-foreground"
              >正在加载原文…</span
            >
          </template>
          <template v-else>
            <NuxtLink
              :to="
                localePath(
                  `/tweet/${tweet.repostOfPostId}`
                )
              "
              @click.stop
              class="text-blue-600 hover:underline"
              >查看原文</NuxtLink
            >
          </template>
        </div>

        <!-- 原文摘要预览卡片（点击跳转原文），失败时给出降级显示 -->
        <div
          v-if="originalTweet && !originalLoading"
          class="rounded-lg border p-3 bg-muted/30 hover:bg-muted/50 transition-colors cursor-pointer"
          @click.stop="toTweetDetail(String(originalTweet.id))"
        >
          <div class="flex items-center gap-2 mb-1 text-sm">
            <Avatar class="h-6 w-6">
              <AvatarImage
                :src="originalTweet.author.avatarUrl"
                :alt="originalTweet.author.username"
              />
              <AvatarFallback>
                {{
                  (originalTweet.author.username || '')
                    .substring(0, 2)
                    .toUpperCase()
                }}
              </AvatarFallback>
            </Avatar>
            <span class="font-medium">
              {{ originalTweet.author.name || '未知' }}
            </span>
            <span class="text-muted-foreground">
              {{ originalAuthorHandle || '@未知用户' }}
            </span>
          </div>
          <p class="text-sm text-foreground/90">
            {{ originalExcerpt || '（无内容）' }}
          </p>
        </div>

        <div
          v-else-if="originalError && !originalLoading"
          class="text-xs text-muted-foreground"
        >
          原文不可用或已删除，
          <NuxtLink
            :to="
              localePath(`/tweet/${tweet.repostOfPostId}`)
            "
            @click.stop
            class="text-blue-600 hover:underline"
            >尝试打开原文</NuxtLink
          >
        </div>
      </div>

      <div class="text-base">
        <TweetContent :content="tweet.content" />
      </div>

      <!-- 媒体展示区 -->
      <div
        v-if="mediaItems.length > 0"
        class="mt-3 rounded-lg overflow-hidden border-none"
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
        <span>{{ tweet.counts.retweets }}</span>
      </Button>

      <Button
        variant="ghost"
        size="sm"
        class="flex items-center gap-2 text-muted-foreground hover:text-blue-500"
        @click.stop="handleReply"
      >
        <MessageCircle class="h-5 w-5" />
        <span>{{ tweet.counts.comments }}</span>
      </Button>

      <Button
        variant="ghost"
        size="sm"
        class="flex items-center gap-2 text-muted-foreground hover:text-red-500"
        @click.stop="handleLike"
      >
        <Heart
          class="h-4 w-4"
          :class="{
            'fill-red-500 text-red-500': localLiked
          }"
        />
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


