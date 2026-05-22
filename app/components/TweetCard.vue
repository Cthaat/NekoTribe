<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import { toast } from 'vue-sonner';
import {
  v2GetPost,
  type PostVM
} from '@/services';
import { v2CreateReport } from '@/api/v2/moderation';
import type { V2ModerationReportReason } from '@/types/v2';
import {
  Card,
  CardContent,
  CardFooter,
  CardHeader
} from '@/components/ui/card';
import AppButton from '@/components/app/AppButton.vue';
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
  DropdownMenuSeparator,
  DropdownMenuTrigger
} from '@/components/ui/dropdown-menu';

import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle
} from '@/components/ui/dialog';
import { Label } from '@/components/ui/label';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import {
  MessageCircle,
  Repeat,
  Heart,
  MoreHorizontal,
  Trash2,
  BadgeCheck,
  BookmarkCheck,
  BookmarkPlus,
  MessageSquareQuote,
  PlayCircle,
  Flag,
  Loader2,
  BrainCircuit,
  Hash,
  MapPin
} from 'lucide-vue-next';
import { useTweetStore } from '@/stores/tweetStore'; // 1. 引入 store
import AiSentimentPredictionDialog from '@/components/AiSentimentPredictionDialog.vue';
import TweetContent from '@/components/TweetContent.vue';

const preferenceStore = usePreferenceStore();
const tweetStore = useTweetStore(); // 2. 获取 store 实例
const { t, locale } = useAppLocale();

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

const props = withDefaults(
  defineProps<{
    tweet: PostVM;
    showRelationContext?: boolean;
  }>(),
  {
    showRelationContext: true
  }
);

// 计算属性，判断这条推文是否属于当前登录用户
const isOwnTweet = computed(
  () => props.tweet.author.id === currentUserId
);

const mediaItems = computed(() => {
  return props.tweet.media.map(media => {
    return {
      type: media.type,
      originalUrl: media.originalUrl,
      thumbnailUrl: media.thumbnailUrl,
      altText: media.altText,
      description: media.description
    };
  });
});

const visibleTags = computed(() =>
  props.tweet.tags
    .map(tag => tag.trim().replace(/^#/, ''))
    .filter(Boolean)
);

const visibleLocation = computed(() =>
  props.tweet.location.trim()
);

const hasPostLabels = computed(
  () =>
    visibleTags.value.length > 0 ||
    visibleLocation.value.length > 0
);

// 格式化时间戳
const formattedDate = computed(() => {
  const dateLocale =
    locale.value === 'zh' ? 'zh-CN' : 'en-US';
  return new Date(props.tweet.createdAt).toLocaleString(
    dateLocale,
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
const isDeleteDialogOpen = ref(false);
const isReportDialogOpen = ref(false);
const isAiPredictionOpen = ref(false);
const isSubmittingReport = ref(false);
const reportReason = ref<V2ModerationReportReason>('spam');
const reportDescription = ref('');

const reportReasons: V2ModerationReportReason[] = [
  'spam',
  'harassment',
  'hate',
  'violence',
  'adult',
  'misinformation',
  'copyright',
  'other'
];

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
    toast.success(t('post.feedback.liked'));
  }
  emit(
    'like-tweet',
    props.tweet,
    localLiked.value ? 'like' : 'unlike'
  );
}

function handleDelete() {
  if (isOwnTweet.value) {
    isDeleteDialogOpen.value = true;
  }
}

function handleReport() {
  if (isOwnTweet.value) return;
  reportReason.value = 'spam';
  reportDescription.value = '';
  isReportDialogOpen.value = true;
}

function handleAiPrediction() {
  isAiPredictionOpen.value = true;
}

function confirmDelete() {
  isDeleteDialogOpen.value = false;
  emit('delete-tweet', props.tweet.id);
}

function handleBookmark() {
  localIsBookmarked.value = !localIsBookmarked.value;
  toast.success(
    localIsBookmarked.value
      ? t('post.feedback.bookmarked')
      : t('post.feedback.unbookmarked')
  );
  emit(
    'bookmark-tweet',
    props.tweet,
    localIsBookmarked.value ? 'mark' : 'unmark'
  );
}

async function submitReport() {
  if (isSubmittingReport.value) return;
  isSubmittingReport.value = true;

  try {
    await v2CreateReport({
      target_type: 'post',
      target_id: props.tweet.id,
      reason: reportReason.value,
      description:
        reportDescription.value.trim() || undefined,
      evidence_url: localePath(`/tweet/${props.tweet.id}`)
    });
    toast.success(t('post.feedback.reported'));
    isReportDialogOpen.value = false;
    reportDescription.value = '';
    reportReason.value = 'spam';
  } catch (error) {
    toast.error(
      error instanceof Error
        ? error.message
        : t('post.feedback.reportFailed')
    );
  } finally {
    isSubmittingReport.value = false;
  }
}

const isLightboxOpen = ref(false);
const lightboxStartIndex = ref(0);

// 3. 【核心修改】创建一个方法来打开灯箱
function openLightbox(index: number) {
  lightboxStartIndex.value = index; // 设置从哪张图片开始显示
  isLightboxOpen.value = true; // 打开灯箱
}

function toTweetDetail(
  tweetId: string,
  selectedTweet: PostVM = props.tweet
) {
  const detailPath = localePath(`/tweet/${tweetId}`);
  tweetStore.setSelectedTweet(selectedTweet);
  navigateTo(detailPath);
}

function searchPosts(query: string) {
  const normalized = query.trim();
  if (!normalized) return;
  void navigateTo(
    localePath(
      `/tweet/search/${encodeURIComponent(normalized)}`
    )
  );
}

type RelatedTweetKind = 'reply' | 'quote' | 'repost';

const relatedTweetKind = computed<RelatedTweetKind | null>(() => {
  if (props.tweet.replyToPostId) return 'reply';
  if (props.tweet.quotedPostId) return 'quote';
  if (props.tweet.repostOfPostId) return 'repost';
  return null;
});

const relatedTweetId = computed(() => {
  if (!props.showRelationContext) return null;

  if (relatedTweetKind.value === 'reply') {
    return props.tweet.replyToPostId;
  }
  if (relatedTweetKind.value === 'quote') {
    return props.tweet.quotedPostId;
  }
  if (relatedTweetKind.value === 'repost') {
    return props.tweet.repostOfPostId;
  }
  return null;
});

const relatedTweetIcon = computed(() => {
  if (relatedTweetKind.value === 'reply') return MessageCircle;
  if (relatedTweetKind.value === 'quote') {
    return MessageSquareQuote;
  }
  return Repeat;
});

const relatedTweetLabel = computed(() => {
  if (relatedTweetKind.value === 'reply') {
    return t('post.relation.replyingTo');
  }
  if (relatedTweetKind.value === 'quote') {
    return t('post.relation.quoting');
  }
  return t('post.relation.reposting');
});

const relatedTweet = ref<PostVM | null>(null);
const relatedLoading = ref(false);
const relatedError = ref<string | null>(null);

async function fetchRelatedTweet() {
  const postId = relatedTweetId.value;
  if (!postId) {
    relatedTweet.value = null;
    relatedLoading.value = false;
    relatedError.value = null;
    return;
  }

  relatedLoading.value = true;
  relatedError.value = null;
  try {
    const result = await v2GetPost(postId);
    if (relatedTweetId.value === postId) {
      relatedTweet.value = result;
    }
  } catch (e) {
    if (relatedTweetId.value !== postId) return;
    relatedError.value =
      e instanceof Error
        ? e.message
        : t('post.relation.loadFailed');
    relatedTweet.value = null;
  } finally {
    if (relatedTweetId.value === postId) {
      relatedLoading.value = false;
    }
  }
}

watch(
  () => [
    props.tweet.postType,
    props.tweet.replyToPostId,
    props.tweet.quotedPostId,
    props.tweet.repostOfPostId
  ],
  () => fetchRelatedTweet(),
  { immediate: true }
);

const relatedAuthorHandle = computed(() => {
  return relatedTweet.value?.author.username
    ? `@${relatedTweet.value.author.username}`
    : '';
});

const relatedExcerpt = computed(() => {
  const text: string = relatedTweet.value?.content || '';
  const compact = text.replace(/\n+/g, ' ').trim();
  const max = 120;
  return compact.length > max
    ? compact.slice(0, max) + '...'
    : compact;
});
</script>

<template>
  <Card
    @click.stop="toTweetDetail(String(tweet.id))"
    class="group relative mx-auto my-3 max-w-2xl cursor-pointer overflow-hidden rounded-xl border border-border/60 bg-card py-0 shadow-none transition-all duration-200 ease-out hover:border-border hover:shadow-md focus-within:ring-2 focus-within:ring-ring/40"
  >
    <CardHeader class="flex flex-row items-start gap-3 px-5 pb-2 pt-5 sm:gap-4">
      <Avatar
        class="h-10 w-10 shrink-0 ring-1 ring-border transition-transform group-hover:scale-[1.02] sm:h-11 sm:w-11"
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
        <AvatarFallback class="bg-muted text-xs font-medium uppercase">
          {{ tweet.author.username.substring(0, 2).toUpperCase() }}
        </AvatarFallback>
      </Avatar>
      <div class="min-w-0 flex-1">
        <div class="flex min-w-0 flex-wrap items-center gap-x-1.5 gap-y-0.5">
          <span class="truncate text-sm font-semibold leading-tight">
            {{ tweet.author.name }}
          </span>
          <BadgeCheck
            v-if="tweet.author.verified"
            class="h-4 w-4 shrink-0 text-sky-500"
          />
          <span class="truncate text-xs text-muted-foreground">
            @{{ tweet.author.username }}
          </span>
          <span class="text-xs text-muted-foreground">·</span>
          <span class="text-xs text-muted-foreground">{{ formattedDate }}</span>
        </div>
      </div>
      <DropdownMenu>
        <DropdownMenuTrigger as-child>
          <Button
            variant="ghost"
            size="icon"
            class="h-8 w-8 shrink-0 rounded-full text-muted-foreground opacity-70 transition-opacity hover:bg-accent hover:opacity-100"
            @click.stop="() => {}"
          >
            <MoreHorizontal class="h-4 w-4" />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" class="w-52">
          <DropdownMenuItem
            v-if="!localIsBookmarked"
            @click.stop="handleBookmark"
          >
            <BookmarkPlus class="mr-2 h-4 w-4" />
            <span>{{ t('post.actions.addBookmark') }}</span>
          </DropdownMenuItem>

          <DropdownMenuItem
            v-else
            @click.stop="handleBookmark"
          >
            <BookmarkCheck class="mr-2 h-4 w-4 text-sky-500" />
            <span>{{ t('post.actions.removeBookmark') }}</span>
          </DropdownMenuItem>

          <DropdownMenuSeparator />

          <DropdownMenuItem
            @click.stop="handleAiPrediction"
          >
            <BrainCircuit class="mr-2 h-4 w-4" />
            <span>{{ t('sentiment.actions.predict') }}</span>
          </DropdownMenuItem>

          <DropdownMenuItem
            v-if="isOwnTweet"
            @click.stop="handleDelete"
            class="text-destructive focus:text-destructive"
          >
            <Trash2 class="mr-2 h-4 w-4" />
            <span>{{ t('post.actions.delete') }}</span>
          </DropdownMenuItem>

          <DropdownMenuSeparator v-if="!isOwnTweet" />

          <DropdownMenuItem
            v-if="!isOwnTweet"
            @click.stop="handleReport"
            class="text-destructive focus:text-destructive"
          >
            <Flag class="mr-2 h-4 w-4" />
            <span>{{ t('post.actions.report') }}</span>
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </CardHeader>

    <CardContent class="space-y-3 px-5 pb-3">
      <div
        v-if="relatedTweetId"
        class="space-y-2"
      >
        <div class="flex flex-wrap items-center gap-1.5 text-xs text-muted-foreground">
          <component
            :is="relatedTweetIcon"
            class="h-3.5 w-3.5"
          />
          <template
            v-if="relatedTweet && !relatedLoading"
          >
            <span>{{ relatedTweetLabel }}</span>
            <NuxtLink
              :to="
                localePath(
                  `/user/${relatedTweet.author.id}/profile`
                )
              "
              @click.stop
              class="font-medium text-foreground hover:underline"
            >
              {{
                relatedAuthorHandle ||
                t('post.relation.unknownUserHandle')
              }}
            </NuxtLink>
            <span>·</span>
            <NuxtLink
              :to="
                localePath(
                  `/tweet/${relatedTweet.id}`
                )
              "
              @click.stop
              class="text-primary hover:underline"
            >
              {{ t('post.relation.viewOriginal') }}
            </NuxtLink>
          </template>
          <template v-else-if="relatedLoading">
            <span>{{ t('post.relation.loadingOriginal') }}</span>
          </template>
          <template v-else>
            <span>{{ relatedTweetLabel }}</span>
            <NuxtLink
              :to="
                localePath(
                  `/tweet/${relatedTweetId}`
                )
              "
              @click.stop
              class="text-primary hover:underline"
            >
              {{ t('post.relation.viewOriginal') }}
            </NuxtLink>
          </template>
        </div>

        <div
          v-if="relatedTweet && !relatedLoading"
          class="rounded-lg border border-border/60 bg-muted/30 p-3 transition-colors hover:border-border hover:bg-muted/50"
          @click.stop="
            toTweetDetail(
              String(relatedTweet.id),
              relatedTweet
            )
          "
        >
          <div class="mb-1.5 flex min-w-0 items-center gap-2 text-sm">
            <Avatar class="h-5 w-5 ring-1 ring-border">
              <AvatarImage
                :src="relatedTweet.author.avatarUrl"
                :alt="relatedTweet.author.username"
              />
              <AvatarFallback class="text-[10px] uppercase">
                {{
                  (relatedTweet.author.username || '')
                    .substring(0, 2)
                    .toUpperCase()
                }}
              </AvatarFallback>
            </Avatar>
            <span class="truncate font-medium">
              {{
                relatedTweet.author.name ||
                t('post.relation.unknownUser')
              }}
            </span>
            <span class="truncate text-xs text-muted-foreground">
              {{
                relatedAuthorHandle ||
                t('post.relation.unknownUserHandle')
              }}
            </span>
          </div>
          <p class="text-sm leading-relaxed text-foreground/85">
            {{ relatedExcerpt || t('post.relation.emptyContent') }}
          </p>
        </div>

        <div
          v-else-if="relatedError && !relatedLoading"
          class="rounded-lg border border-dashed border-border/60 bg-muted/20 p-3 text-xs text-muted-foreground"
        >
          {{ t('post.relation.originalUnavailable') }}
          <NuxtLink
            :to="
              localePath(`/tweet/${relatedTweetId}`)
            "
            @click.stop
            class="text-primary hover:underline"
          >
            {{ t('post.relation.tryOpenOriginal') }}
          </NuxtLink>
        </div>
      </div>

      <div class="text-[15px] leading-relaxed text-foreground/95">
        <TweetContent :content="tweet.content" />
      </div>

      <div
        v-if="hasPostLabels"
        class="flex flex-wrap gap-1.5"
      >
        <button
          v-if="visibleLocation"
          type="button"
          class="inline-flex h-6 items-center gap-1 rounded-full border border-border/60 bg-muted/40 px-2 text-xs text-muted-foreground transition-colors hover:border-border hover:bg-accent hover:text-foreground"
          @click.stop="searchPosts(visibleLocation)"
        >
          <MapPin class="h-3 w-3" />
          <span class="max-w-[12rem] truncate">
            {{ visibleLocation }}
          </span>
        </button>
        <button
          v-for="tag in visibleTags"
          :key="`tag-${tweet.id}-${tag}`"
          type="button"
          class="inline-flex h-6 items-center gap-1 rounded-full border border-border/60 bg-muted/40 px-2 text-xs text-muted-foreground transition-colors hover:border-border hover:bg-accent hover:text-foreground"
          @click.stop="searchPosts(`#${tag}`)"
        >
          <Hash class="h-3 w-3" />
          <span>{{ tag }}</span>
        </button>
      </div>

      <!-- 媒体展示区 -->
      <div
        v-if="mediaItems.length > 0"
        class="overflow-hidden rounded-xl border border-border/60"
      >
        <div
          class="grid gap-px bg-border"
          :class="{
            'grid-cols-1': mediaItems.length === 1,
            'grid-cols-2': mediaItems.length >= 2,
            'grid-rows-2 h-64 sm:h-80':
              mediaItems.length > 2
          }"
        >
          <div
            v-for="(item, index) in mediaItems.slice(0, 4)"
            :key="item.originalUrl"
            class="group/media relative cursor-pointer overflow-hidden bg-muted"
            @click.stop="openLightbox(index)"
          >
            <img
              :src="item.thumbnailUrl"
              class="h-full w-full object-cover transition-transform duration-300 ease-out group-hover/media:scale-105"
              :alt="item.altText || t('post.media.thumbnailAlt')"
            />

            <div
              v-if="item.type === 'video'"
              class="absolute inset-0 flex items-center justify-center bg-black/30 transition-colors group-hover/media:bg-black/40"
            >
              <PlayCircle class="h-12 w-12 text-white/90 drop-shadow-lg" />
            </div>

            <div
              v-if="mediaItems.length > 4 && index === 3"
              class="absolute inset-0 flex items-center justify-center bg-black/60 backdrop-blur-sm"
            >
              <span class="text-2xl font-semibold text-white">
                +{{ mediaItems.length - 4 }}
              </span>
            </div>
          </div>
        </div>
      </div>
    </CardContent>

    <CardFooter class="flex items-center justify-between gap-1 border-t border-border/40 bg-muted/20 px-2 py-1">
      <Button
        variant="ghost"
        size="sm"
        class="group/btn flex h-9 flex-1 items-center justify-center gap-2 rounded-md text-muted-foreground transition-colors hover:bg-emerald-500/10 hover:text-emerald-600 dark:hover:text-emerald-400"
        @click.stop="handleRetweet"
      >
        <Repeat class="h-4 w-4 transition-transform group-hover/btn:scale-110" />
        <span class="text-xs font-medium tabular-nums">{{ tweet.counts.retweets }}</span>
      </Button>

      <Button
        variant="ghost"
        size="sm"
        class="group/btn flex h-9 flex-1 items-center justify-center gap-2 rounded-md text-muted-foreground transition-colors hover:bg-sky-500/10 hover:text-sky-600 dark:hover:text-sky-400"
        @click.stop="handleReply"
      >
        <MessageCircle class="h-4 w-4 transition-transform group-hover/btn:scale-110" />
        <span class="text-xs font-medium tabular-nums">{{ tweet.counts.comments }}</span>
      </Button>

      <Button
        variant="ghost"
        size="sm"
        class="group/btn flex h-9 flex-1 items-center justify-center gap-2 rounded-md text-muted-foreground transition-colors hover:bg-rose-500/10 hover:text-rose-600 dark:hover:text-rose-400"
        :class="{ 'text-rose-600 dark:text-rose-400': localLiked }"
        @click.stop="handleLike"
      >
        <Heart
          class="h-4 w-4 transition-all group-hover/btn:scale-110"
          :class="{
            'fill-rose-600 dark:fill-rose-400': localLiked
          }"
        />
        <span class="text-xs font-medium tabular-nums">{{ likeCount }}</span>
      </Button>
    </CardFooter>
  </Card>
  <Lightbox
    v-if="mediaItems.length > 0"
    v-model:open="isLightboxOpen"
    :items="mediaItems"
    :start-index="lightboxStartIndex"
  />
  <AiSentimentPredictionDialog
    v-model:open="isAiPredictionOpen"
    :text="tweet.content"
    :post-id="tweet.id"
  />

  <Dialog v-model:open="isDeleteDialogOpen">
    <DialogContent
      class="overflow-hidden rounded-xl border-border/60 p-0 sm:max-w-md"
    >
      <DialogHeader
        class="border-b border-border/60 bg-background/60 px-5 py-3 backdrop-blur"
      >
        <DialogTitle class="flex items-center gap-2 text-base">
          <span
            class="flex h-7 w-7 items-center justify-center rounded-md bg-rose-500/10 text-rose-600 dark:text-rose-400"
          >
            <Trash2 class="h-4 w-4" />
          </span>
          {{ t('post.delete.title') }}
        </DialogTitle>
        <DialogDescription class="text-xs text-muted-foreground">
          {{ t('post.delete.description') }}
        </DialogDescription>
      </DialogHeader>
      <DialogFooter
        class="border-t border-border/60 bg-background/60 px-5 py-3"
      >
        <AppButton
          variant="outline"
          size="sm"
          class="h-9 rounded-md shadow-xs"
          @click="isDeleteDialogOpen = false"
        >
          {{ t('common.cancel') }}
        </AppButton>
        <AppButton
          variant="destructive"
          size="sm"
          class="h-9 rounded-md shadow-xs"
          @click="confirmDelete"
        >
          <Trash2 class="h-3.5 w-3.5" />
          {{ t('common.delete') }}
        </AppButton>
      </DialogFooter>
    </DialogContent>
  </Dialog>

  <Dialog v-model:open="isReportDialogOpen">
    <DialogContent
      class="overflow-hidden rounded-xl border-border/60 p-0 sm:max-w-md"
    >
      <DialogHeader
        class="border-b border-border/60 bg-background/60 px-5 py-3 backdrop-blur"
      >
        <DialogTitle class="flex items-center gap-2 text-base">
          <span
            class="flex h-7 w-7 items-center justify-center rounded-md bg-amber-500/10 text-amber-600 dark:text-amber-400"
          >
            <Flag class="h-4 w-4" />
          </span>
          {{ t('post.report.title') }}
        </DialogTitle>
        <DialogDescription class="text-xs text-muted-foreground">
          {{ t('post.report.description') }}
        </DialogDescription>
      </DialogHeader>

      <div class="grid gap-4 px-5 py-4">
        <div class="grid gap-2">
          <Label
            for="post-report-reason"
            class="text-xs font-medium"
          >
            {{ t('post.report.reasonLabel') }}
          </Label>
          <Select v-model="reportReason">
            <SelectTrigger
              id="post-report-reason"
              class="h-9 w-full shadow-xs"
            >
              <SelectValue
                :placeholder="t('post.report.reasonPlaceholder')"
              />
            </SelectTrigger>
            <SelectContent>
              <SelectItem
                v-for="reason in reportReasons"
                :key="reason"
                :value="reason"
              >
                {{
                  t(`moderation.filters.reasons.${reason}`)
                }}
              </SelectItem>
            </SelectContent>
          </Select>
        </div>

        <div class="grid gap-2">
          <Label
            for="post-report-description"
            class="text-xs font-medium"
          >
            {{ t('post.report.descriptionLabel') }}
          </Label>
          <Textarea
            id="post-report-description"
            v-model="reportDescription"
            :placeholder="t('post.report.descriptionPlaceholder')"
            class="min-h-24 resize-none shadow-xs"
            maxlength="1000"
          />
          <p class="text-[11px] text-muted-foreground">
            {{
              t('post.report.descriptionHint', {
                count: reportDescription.length
              })
            }}
          </p>
        </div>
      </div>

      <DialogFooter
        class="border-t border-border/60 bg-background/60 px-5 py-3"
      >
        <AppButton
          variant="outline"
          size="sm"
          class="h-9 rounded-md shadow-xs"
          :disabled="isSubmittingReport"
          @click="isReportDialogOpen = false"
        >
          {{ t('common.cancel') }}
        </AppButton>
        <AppButton
          variant="destructive"
          size="sm"
          class="h-9 rounded-md shadow-xs"
          :disabled="isSubmittingReport"
          @click="submitReport"
        >
          <Loader2
            v-if="isSubmittingReport"
            class="h-3.5 w-3.5 animate-spin"
          />
          <Flag v-else class="h-3.5 w-3.5" />
          {{
            isSubmittingReport
              ? t('post.report.submitting')
              : t('post.report.submit')
          }}
        </AppButton>
      </DialogFooter>
    </DialogContent>
  </Dialog>
</template>

<style scoped>
.grid-rows-2 {
  grid-template-rows: repeat(2, minmax(0, 1fr));
}
</style>


