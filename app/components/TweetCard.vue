<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import { toast } from 'vue-sonner';
import {
  v2GetPost,
  type PostVM
} from '@/services';
import { v2CreateReport } from '@/api/v2/moderation';
import { v2SendRecommendationFeedback, type RecommendationAction } from '@/api/v2/posts';
import type { V2ModerationReportReason } from '@/types/v2';
import UserAvatar from '@/components/UserAvatar.vue';
import AnimatedNumber from '@/components/motion/AnimatedNumber.vue';
import LikeButton from '@/components/motion/LikeButton.vue';
import { formatFullTime, formatRelativeTime } from '@/utils/relativeTime';
import AppButton from '@/components/app/AppButton.vue';
import Lightbox from '@/components/Lightbox.vue';
import PrivateMediaDownload from '@/components/PrivateMediaDownload.vue';
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
  MoreHorizontal,
  Trash2,
  BadgeCheck,
  Bookmark,
  BookmarkCheck,
  BookmarkPlus,
  MessageSquareQuote,
  PlayCircle,
  Flag,
  EyeOff,
  ListFilter,
  Loader2,
  BrainCircuit,
  Hash,
  MapPin,
  Pin,
  PinOff,
  Pencil,
  Share
} from 'lucide-vue-next';
import { useTweetStore } from '@/stores/tweetStore'; // 1. 引入 store
import TweetContent from '@/components/TweetContent.vue';
import PostPollPanel from '@/components/PostPollPanel.vue';
import PostMarkdown from '@/components/PostMarkdown.vue';

const preferenceStore = usePreferenceStore();
const tweetStore = useTweetStore(); // 2. 获取 store 实例
const { t, locale } = useAppLocale();

const localePath = useLocalePath();

const emit = defineEmits([
  'delete-tweet',
  'reply-tweet',
  'retweet-tweet',
  'like-tweet',
  'bookmark-tweet',
  'toggle-profile-pin'
]);

const props = withDefaults(
  defineProps<{
    tweet: PostVM;
    showRelationContext?: boolean;
    pinnedOnProfile?: boolean;
    canManageProfilePin?: boolean;
    profilePinPending?: boolean;
    focused?: boolean;
  }>(),
  {
    showRelationContext: true,
    focused: false
  }
);

// 计算属性，判断这条推文是否属于当前登录用户
const isOwnTweet = computed(
  () => preferenceStore.isLoggedIn && props.tweet.author.id === preferenceStore.preferences.user.id
);

const mediaItems = computed(() => {
  return props.tweet.media.filter(media => media.privateFileName === undefined).map(media => {
    return {
      type: media.type,
      originalUrl: media.originalUrl,
      thumbnailUrl: media.thumbnailUrl,
      altText: media.altText,
      description: media.description
    };
  });
});
const privateAttachments = computed(() => props.tweet.media.filter(media => media.privateFileName !== undefined));

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
const formattedDate = computed(() => formatFullTime(props.tweet.createdAt, locale.value));
const relativeDate = computed(() => formatRelativeTime(props.tweet.createdAt, locale.value));

const isLongPlainText = computed(() => {
  if (props.tweet.markdown) return false;
  const content = props.tweet.content || '';
  return content.length > 320 || content.split('\n').length > 8;
});
const isTextExpanded = ref(false);

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

watch(
  () => props.tweet.counts.likes,
  newValue => {
    likeCount.value = newValue;
  }
);

const localIsBookmarked = ref(
  props.tweet.viewer.hasBookmarked
);
const isDeleteDialogOpen = ref(false);
const isReportDialogOpen = ref(false);
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

function confirmDelete() {
  isDeleteDialogOpen.value = false;
  emit('delete-tweet', props.tweet.id);
}

async function handleShare(): Promise<void> {
  const path = localePath(`/tweet/${props.tweet.id}`);
  const url = import.meta.client ? new URL(path, window.location.origin).href : path;
  try {
    await navigator.clipboard.writeText(url);
    toast.success(t('post.actionsExtra.linkCopied'));
  } catch {
    toast.info(url);
  }
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

const feedbackBusy = ref(false);
async function sendRecommendationFeedback(action: RecommendationAction) {
  if (feedbackBusy.value) return;
  feedbackBusy.value = true;
  try {
    if (await v2SendRecommendationFeedback(props.tweet.id, action)) {
      toast.success(t('post.feedback.recommendationSaved'));
    } else {
      toast.error(t('post.feedback.recommendationFailed'));
    }
  } catch {
    toast.error(t('post.feedback.recommendationFailed'));
  } finally {
    feedbackBusy.value = false;
  }
}

export interface LightboxOriginRect {
  top: number;
  left: number;
  width: number;
  height: number;
}

const isLightboxOpen = ref(false);
const lightboxStartIndex = ref(0);
const lightboxOriginRect = ref<LightboxOriginRect | null>(null);

// Capture origin thumbnail rect for FLIP open/close transition
function openLightbox(index: number, event?: Event) {
  const target = event?.currentTarget as HTMLElement | null;
  if (target && typeof target.getBoundingClientRect === 'function') {
    const rect = target.getBoundingClientRect();
    if (rect.width > 0 && rect.height > 0) {
      lightboxOriginRect.value = {
        top: rect.top,
        left: rect.left,
        width: rect.width,
        height: rect.height
      };
    } else {
      lightboxOriginRect.value = null;
    }
  } else {
    lightboxOriginRect.value = null;
  }
  lightboxStartIndex.value = index;
  isLightboxOpen.value = true;
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
  if (normalized.startsWith('#')) {
    const tag = normalized.slice(1).trim();
    if (!tag) return;
    void navigateTo(localePath(`/tags/${encodeURIComponent(tag)}`));
    return;
  }
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
  <article
    @click.stop="!focused && toTweetDetail(String(tweet.id))"
    class="bento-card group relative transition-colors duration-200"
    :class="
      focused
        ? 'p-5 cursor-default'
        : 'px-4 pt-4 pb-3 hover:shadow-[0_4px_16px_rgba(15,23,42,0.06)] dark:hover:bg-[#191C22] cursor-pointer'
    "
  >
    <p
      v-if="pinnedOnProfile"
      class="mb-1.5 flex items-center gap-1.5 text-xs font-semibold text-muted-foreground"
      :class="focused ? '' : 'pl-11 sm:pl-14'"
    >
      <Pin class="size-3.5" />{{ t('post.profilePin.label') }}
    </p>

    <div
      class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-3"
      :class="focused ? 'items-center' : 'items-start'"
    >
      <!-- Avatar -->
      <div
        class="pressable shrink-0"
        :class="focused ? 'col-start-1 row-start-1' : 'col-start-1 row-start-1 row-span-2 pt-0.5'"
        @click.stop="navigateTo(localePath(`/user/${tweet.author.id}/profile`))"
      >
        <UserAvatar
          :src="tweet.author.avatarUrl"
          :name="tweet.author.name"
          :username="tweet.author.username"
          :seed="tweet.author.id"
          :size="focused ? 'lg' : 'md'"
        />
      </div>

      <!-- Header Row -->
      <div
        class="col-start-2 row-start-1 flex min-w-0 justify-between gap-2"
        :class="focused ? 'items-center' : 'items-start'"
      >
        <div
          v-if="focused"
          class="flex min-w-0 flex-col"
        >
          <div class="flex items-center gap-1">
            <span
              class="cursor-pointer truncate text-[16px] font-semibold leading-tight text-foreground hover:underline"
              @click.stop="navigateTo(localePath(`/user/${tweet.author.id}/profile`))"
            >
              {{ tweet.author.name || tweet.author.username }}
            </span>
            <BadgeCheck
              v-if="tweet.author.verified"
              class="size-4 shrink-0 text-primary"
            />
          </div>
          <span
            class="cursor-pointer truncate text-[13px] text-[var(--ink-tertiary)] hover:underline"
            @click.stop="navigateTo(localePath(`/user/${tweet.author.id}/profile`))"
          >
            @{{ tweet.author.username }}
          </span>
        </div>

        <div
          v-else
          class="flex min-w-0 flex-wrap items-center gap-x-1.5 gap-y-0.5 pt-0.5"
        >
          <span
            class="truncate text-[15px] font-semibold leading-tight text-foreground hover:underline"
            @click.stop="navigateTo(localePath(`/user/${tweet.author.id}/profile`))"
          >
            {{ tweet.author.name || tweet.author.username }}
          </span>
          <BadgeCheck
            v-if="tweet.author.verified"
            class="size-4 shrink-0 text-primary"
          />
          <span class="truncate text-[13px] text-[var(--ink-tertiary)]">
            @{{ tweet.author.username }}
          </span>
          <span class="text-xs text-[var(--ink-tertiary)]">·</span>
          <time
            :datetime="tweet.createdAt"
            :title="formattedDate"
            class="text-[13px] text-[var(--ink-tertiary)] hover:underline"
          >
            {{ relativeDate }}
          </time>
        </div>

          <DropdownMenu>
            <DropdownMenuTrigger as-child>
              <Button
                variant="ghost"
                size="icon"
                class="-mr-2 -mt-1 size-8 shrink-0 rounded-full text-muted-foreground opacity-70 transition-opacity hover:bg-primary/10 hover:text-primary hover:opacity-100"
                :aria-label="t('common.more')"
                @click.stop
              >
                <MoreHorizontal class="size-4" />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" class="w-52 rounded-2xl p-1.5">
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
                <BookmarkCheck class="mr-2 h-4 w-4 text-primary" />
                <span>{{ t('post.actions.removeBookmark') }}</span>
              </DropdownMenuItem>

              <DropdownMenuSeparator />

              <DropdownMenuItem @select="navigateTo(localePath('/ai/knowledge'))">
                <BrainCircuit class="mr-2 h-4 w-4" />
                <span>{{ t('aiKnowledge.title') }}</span>
              </DropdownMenuItem>

              <DropdownMenuItem v-if="isOwnTweet && canManageProfilePin" :disabled="profilePinPending"
                @select="emit('toggle-profile-pin',tweet)">
                <component :is="pinnedOnProfile ? PinOff : Pin" class="mr-2 size-4" />
                <span>{{ t(pinnedOnProfile ? 'post.profilePin.clear' : 'post.profilePin.set') }}</span>
              </DropdownMenuItem>

              <DropdownMenuItem
                v-if="isOwnTweet"
                @select="navigateTo(localePath({ path: '/account/posts', query: { edit: String(tweet.id) } }))"
              >
                <Pencil class="mr-2 h-4 w-4" />
                <span>{{ t('post.actions.edit') }}</span>
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

              <DropdownMenuItem v-if="!isOwnTweet && preferenceStore.preferences.user.id > 0" :disabled="feedbackBusy"
                @select="sendRecommendationFeedback('not_interested')">
                <EyeOff class="mr-2 h-4 w-4" />
                <span>{{ t('post.feedback.notInterested') }}</span>
              </DropdownMenuItem>
              <DropdownMenuItem v-if="!isOwnTweet && preferenceStore.preferences.user.id > 0" :disabled="feedbackBusy"
                @select="sendRecommendationFeedback('show_less')">
                <ListFilter class="mr-2 h-4 w-4" />
                <span>{{ t('post.feedback.showLess') }}</span>
              </DropdownMenuItem>

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
        </div>

      <!-- Content + Actions (indented under header in feed; full-width when focused) -->
      <div :class="focused ? 'col-span-2 row-start-2 mt-3 min-w-0' : 'col-start-2 row-start-2 min-w-0'">

        <!-- Relation context (Reply / Quote / Repost) -->
        <div
          v-if="relatedTweetId"
          class="mt-1.5 space-y-2"
        >
          <div class="flex flex-wrap items-center gap-1.5 text-xs text-muted-foreground">
            <component :is="relatedTweetIcon" class="size-3.5" />
            <template v-if="relatedTweet && !relatedLoading">
              <span>{{ relatedTweetLabel }}</span>
              <NuxtLink
                :to="localePath(`/user/${relatedTweet.author.id}/profile`)"
                @click.stop
                class="font-medium text-foreground hover:underline"
              >
                {{ relatedAuthorHandle || t('post.relation.unknownUserHandle') }}
              </NuxtLink>
              <span>·</span>
              <NuxtLink
                :to="localePath(`/tweet/${relatedTweet.id}`)"
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
                :to="localePath(`/tweet/${relatedTweetId}`)"
                @click.stop
                class="text-primary hover:underline"
              >
                {{ t('post.relation.viewOriginal') }}
              </NuxtLink>
            </template>
          </div>

          <div
            v-if="relatedTweet && !relatedLoading"
            class="bento-tile mt-2 p-3 transition-colors hover:bg-accent/70"
            @click.stop="toTweetDetail(String(relatedTweet.id), relatedTweet)"
          >
            <div class="mb-1 flex min-w-0 items-center gap-2 text-sm">
              <UserAvatar
                :src="relatedTweet.author.avatarUrl"
                :name="relatedTweet.author.name || relatedTweet.author.username"
                :username="relatedTweet.author.username"
                :seed="relatedTweet.author.id"
                size="xs"
              />
              <span class="truncate font-semibold">
                {{ relatedTweet.author.name || t('post.relation.unknownUser') }}
              </span>
              <span class="truncate text-xs text-[var(--ink-tertiary)]">
                {{ relatedAuthorHandle || t('post.relation.unknownUserHandle') }}
              </span>
            </div>
            <p class="text-sm leading-[1.6] text-foreground/85">
              {{ relatedExcerpt || t('post.relation.emptyContent') }}
            </p>
          </div>

          <div
            v-else-if="relatedError && !relatedLoading"
            class="bento-tile mt-2 p-3 text-xs text-muted-foreground"
          >
            {{ t('post.relation.originalUnavailable') }}
            <NuxtLink
              :to="localePath(`/tweet/${relatedTweetId}`)"
              @click.stop
              class="text-primary hover:underline"
            >
              {{ t('post.relation.tryOpenOriginal') }}
            </NuxtLink>
          </div>
        </div>

        <!-- Body -->
        <div
          class="text-foreground"
          :class="focused ? 'text-[17px] leading-[1.65]' : 'mt-1.5 text-[15.5px] leading-[1.62]'"
        >
          <PostMarkdown v-if="tweet.markdown" :source="tweet.markdown" />
          <div v-else :class="!focused && isLongPlainText && !isTextExpanded ? 'line-clamp-8' : ''">
            <TweetContent :content="tweet.content" />
          </div>
          <button
            v-if="!focused && isLongPlainText"
            type="button"
            class="mt-1 text-xs font-semibold text-primary hover:underline"
            @click.stop="isTextExpanded = !isTextExpanded"
          >
            {{ t(isTextExpanded ? 'post.actionsExtra.showLess' : 'post.actionsExtra.showMore') }}
          </button>
        </div>

        <LinkPreviewCard :text="tweet.content" :markdown="tweet.markdown" />
        <PostPollPanel v-if="tweet.poll" :key="tweet.poll.poll_id" :poll="tweet.poll" :post-id="tweet.id"
          :can-vote="preferenceStore.isLoggedIn" />

        <div
          v-if="hasPostLabels"
          class="mt-2.5 flex flex-wrap gap-1.5"
        >
          <button
            v-if="visibleLocation"
            type="button"
            class="inline-flex h-6 items-center gap-1 rounded-[6px] bg-secondary px-2 text-xs text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
            @click.stop="searchPosts(visibleLocation)"
          >
            <MapPin class="h-3 w-3" />
            <span class="max-w-[12rem] truncate">{{ visibleLocation }}</span>
          </button>
          <button
            v-for="tag in visibleTags"
            :key="`tag-${tweet.id}-${tag}`"
            type="button"
            class="inline-flex h-6 items-center gap-1 rounded-[6px] bg-[var(--primary-soft)] px-2 text-xs font-medium text-primary transition-colors hover:opacity-85"
            @click.stop="searchPosts(`#${tag}`)"
          >
            <Hash class="h-3 w-3" />
            <span>{{ tag }}</span>
          </button>
        </div>

        <!-- 媒体展示区 -->
        <div v-if="privateAttachments.length" class="mt-2.5 flex flex-wrap gap-2">
          <PrivateMediaDownload
            v-for="item in privateAttachments"
            :key="item.id"
            :media-id="item.id"
            :file-name="item.privateFileName ?? ''"
          />
        </div>
        <div
          v-if="mediaItems.length > 0"
          class="mt-3 overflow-hidden rounded-[18px]"
        >
          <div
            class="grid gap-[3px] bg-background"
            :class="{
              'grid-cols-1': mediaItems.length === 1,
              'grid-cols-2': mediaItems.length >= 2,
              'h-72 sm:h-80': mediaItems.length === 2 || mediaItems.length === 3,
              'grid-rows-2 h-72 sm:h-80': mediaItems.length >= 4
            }"
          >
            <div
              v-for="(item, index) in mediaItems.slice(0, 4)"
              :key="item.originalUrl"
              class="group/media relative cursor-pointer overflow-hidden bg-muted"
              :class="{
                'max-h-[420px]': mediaItems.length === 1,
                'row-span-2': mediaItems.length === 3 && index === 0
              }"
              @click.stop="openLightbox(index, $event)"
            >
              <img
                :src="item.thumbnailUrl"
                class="h-full w-full object-cover transition-transform duration-300 ease-out group-hover/media:scale-[1.03]"
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

        <!-- Focused Detail Mode: Timestamp + Stats Bar + Spaced Action Bar -->
        <template v-if="focused">
          <div class="mt-3 text-sm text-[var(--ink-tertiary)]">
            <time :datetime="tweet.createdAt">{{ formattedDate }}</time>
          </div>

          <div
            class="mt-3 flex flex-wrap items-center gap-5 border-y border-[var(--divider)] py-3 text-sm"
          >
            <span class="inline-flex items-center gap-1">
              <strong class="font-semibold tabular-nums text-foreground">
                <AnimatedNumber :value="tweet.counts.comments" />
              </strong>
              <span class="text-muted-foreground">{{ t('post.detail.commentsLabel') }}</span>
            </span>
            <span class="inline-flex items-center gap-1">
              <strong class="font-semibold tabular-nums text-foreground">
                <AnimatedNumber :value="tweet.counts.retweets" />
              </strong>
              <span class="text-muted-foreground">{{ t('post.detail.repostsLabel') }}</span>
            </span>
            <slot name="likers-stat">
              <span class="inline-flex items-center gap-1">
                <strong class="font-semibold tabular-nums text-foreground">
                  <AnimatedNumber :value="likeCount" />
                </strong>
                <span class="text-muted-foreground">{{ t('post.detail.likesLabel') }}</span>
              </span>
            </slot>
          </div>

          <div class="mt-1 flex items-center justify-around pt-1">
            <button
              type="button"
              class="group/btn pressable inline-flex size-10 items-center justify-center rounded-full text-muted-foreground transition-colors hover:bg-primary/10 hover:text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
              :aria-label="t('comment.reply')"
              @click.stop="handleReply"
            >
              <MessageCircle class="size-5" :stroke-width="1.75" />
            </button>

            <button
              type="button"
              class="group/btn pressable inline-flex size-10 items-center justify-center rounded-full text-muted-foreground transition-colors hover:bg-[var(--repost)]/10 hover:text-[var(--repost)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
              :aria-label="t('post.retweet.submit')"
              @click.stop="handleRetweet"
            >
              <Repeat
                class="size-5"
                :stroke-width="1.75"
              />
            </button>

            <LikeButton
              :liked="localLiked"
              :count="likeCount"
              hide-count
              icon-class="size-5"
              @toggle="handleLike"
            />

            <button
              type="button"
              class="group/btn pressable inline-flex size-10 items-center justify-center rounded-full transition-colors hover:bg-primary/10 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
              :class="localIsBookmarked ? 'text-primary' : 'text-muted-foreground hover:text-primary'"
              :aria-label="t(localIsBookmarked ? 'post.actions.removeBookmark' : 'post.actions.addBookmark')"
              @click.stop="handleBookmark"
            >
              <component
                :is="localIsBookmarked ? BookmarkCheck : Bookmark"
                class="size-5 transition-transform duration-150"
                :class="{ 'scale-110 fill-primary/15': localIsBookmarked }"
                :stroke-width="1.75"
              />
            </button>

            <button
              type="button"
              class="group/btn pressable inline-flex size-10 items-center justify-center rounded-full text-muted-foreground transition-colors hover:bg-primary/10 hover:text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
              :aria-label="t('post.actionsExtra.share')"
              @click.stop="handleShare"
            >
              <Share class="size-5" :stroke-width="1.75" />
            </button>
          </div>
        </template>

        <!-- Bento Quiet Feed Action Bar -->
        <div
          v-else
          class="mt-2.5 -ml-2 flex items-center gap-5 text-[13px]"
        >
          <button
            type="button"
            class="group/btn pressable inline-flex items-center gap-1 rounded-full py-1 pr-2 text-muted-foreground transition-colors hover:text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
            :aria-label="t('comment.reply')"
            @click.stop="handleReply"
          >
            <span class="inline-flex size-8 items-center justify-center rounded-full transition-colors group-hover/btn:bg-primary/10">
              <MessageCircle class="size-[18px]" :stroke-width="1.75" />
            </span>
            <AnimatedNumber :value="tweet.counts.comments" hide-zero />
          </button>

          <button
            type="button"
            class="group/btn pressable inline-flex items-center gap-1 rounded-full py-1 pr-2 text-muted-foreground transition-colors hover:text-[var(--repost)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
            :aria-label="t('post.retweet.submit')"
            @click.stop="handleRetweet"
          >
            <span class="inline-flex size-8 items-center justify-center rounded-full transition-colors group-hover/btn:bg-[var(--repost)]/10">
              <Repeat
                class="size-[18px]"
                :stroke-width="1.75"
              />
            </span>
            <AnimatedNumber :value="tweet.counts.retweets" hide-zero />
          </button>

          <LikeButton
            :liked="localLiked"
            :count="likeCount"
            @toggle="handleLike"
          />

          <div class="ml-auto flex items-center gap-1">
            <button
              type="button"
              class="group/btn pressable inline-flex size-8 items-center justify-center rounded-full transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
              :class="localIsBookmarked ? 'text-primary' : 'text-muted-foreground hover:text-primary'"
              :aria-label="t(localIsBookmarked ? 'post.actions.removeBookmark' : 'post.actions.addBookmark')"
              @click.stop="handleBookmark"
            >
              <span class="inline-flex size-8 items-center justify-center rounded-full transition-colors group-hover/btn:bg-primary/10">
                <component
                  :is="localIsBookmarked ? BookmarkCheck : Bookmark"
                  class="size-[18px] transition-transform duration-150"
                  :class="{ 'fill-primary/15': localIsBookmarked }"
                  :stroke-width="1.75"
                />
              </span>
            </button>

            <button
              type="button"
              class="group/btn pressable inline-flex size-8 items-center justify-center rounded-full text-muted-foreground transition-colors hover:text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
              :aria-label="t('post.actionsExtra.share')"
              @click.stop="handleShare"
            >
              <span class="inline-flex size-8 items-center justify-center rounded-full transition-colors group-hover/btn:bg-primary/10">
                <Share class="size-[17px]" :stroke-width="1.75" />
              </span>
            </button>
          </div>
        </div>
      </div>
    </div>
  </article>
  <Lightbox
    v-if="mediaItems.length > 0"
    v-model:open="isLightboxOpen"
    :items="mediaItems"
    :start-index="lightboxStartIndex"
    :origin-rect="lightboxOriginRect"
  />

  <Dialog v-model:open="isDeleteDialogOpen">
    <DialogContent
      class="overflow-hidden p-0 sm:max-w-md"
    >
      <DialogHeader
        class="border-b border-[var(--divider)] px-5 py-3.5"
      >
        <DialogTitle class="flex items-center gap-2 text-base">
          <span
            class="flex h-7 w-7 items-center justify-center rounded-full bg-rose-500/10 text-rose-600 dark:text-rose-400"
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
        class="border-t border-[var(--divider)] px-5 py-3.5"
      >
        <AppButton
          variant="secondary"
          size="sm"
          class="h-9 rounded-full"
          @click="isDeleteDialogOpen = false"
        >
          {{ t('common.cancel') }}
        </AppButton>
        <AppButton
          variant="destructive"
          size="sm"
          class="h-9 rounded-full"
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
      class="overflow-hidden p-0 sm:max-w-md"
    >
      <DialogHeader
        class="border-b border-[var(--divider)] px-5 py-3.5"
      >
        <DialogTitle class="flex items-center gap-2 text-base">
          <span
            class="flex h-7 w-7 items-center justify-center rounded-full bg-amber-500/10 text-amber-600 dark:text-amber-400"
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
              class="h-10 w-full rounded-[14px] border-0 bg-secondary dark:bg-secondary shadow-none"
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
            class="min-h-24 resize-none rounded-[14px] border-0 bg-secondary dark:bg-secondary shadow-none"
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
        class="border-t border-[var(--divider)] px-5 py-3.5"
      >
        <AppButton
          variant="secondary"
          size="sm"
          class="h-9 rounded-full"
          :disabled="isSubmittingReport"
          @click="isReportDialogOpen = false"
        >
          {{ t('common.cancel') }}
        </AppButton>
        <AppButton
          variant="destructive"
          size="sm"
          class="h-9 rounded-full"
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


