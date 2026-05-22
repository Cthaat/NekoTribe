<script setup lang="ts">
import { ref, computed, watch } from 'vue';
import {
  Heart,
  MessageCircle,
  MoreHorizontal,
  Pin,
  Trash2,
  Flag,
  Share2,
  Play
} from 'lucide-vue-next';
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
  DropdownMenuSeparator,
  DropdownMenuTrigger
} from '@/components/ui/dropdown-menu';
import { toast } from 'vue-sonner';
import type { GroupPost } from '@/types/groups';

export type { GroupPost } from '@/types/groups';
const { t, locale } = useAppLocale();
const localePath = useLocalePath();

const props = defineProps<{
  post: GroupPost;
  canManage?: boolean;
  isAuthor?: boolean;
}>();

const emit = defineEmits<{
  (e: 'like', id: number): void;
  (e: 'comment', id: number): void;
  (e: 'pin', id: number): void;
  (e: 'unpin', id: number): void;
  (e: 'delete', id: number): void;
  (e: 'report', id: number): void;
  (e: 'share', id: number): void;
}>();

const isLiked = ref(props.post.isLiked || false);
const likeCount = ref(props.post.likeCount);
const groupContext = computed(() => props.post.group);

watch(
  () => props.post.isLiked,
  value => {
    isLiked.value = !!value;
  }
);

watch(
  () => props.post.likeCount,
  value => {
    likeCount.value = value;
  }
);

const formatTime = (dateStr: string) => {
  const date = new Date(dateStr);
  const now = new Date();
  const diff = now.getTime() - date.getTime();
  const hours = Math.floor(diff / (1000 * 60 * 60));

  if (hours < 1) {
    const minutes = Math.floor(diff / (1000 * 60));
    return t('time.minutesAgo', { count: minutes });
  } else if (hours < 24) {
    return t('time.hoursAgo', { count: hours });
  } else {
    const days = Math.floor(hours / 24);
    if (days < 7) {
      return t('time.daysAgo', { count: days });
    }
    return date.toLocaleDateString(
      locale.value === 'zh' ? 'zh-CN' : 'en-US',
      {
        month: 'short',
        day: 'numeric'
      }
    );
  }
};

const roleBadge = computed(() => {
  const role = props.post.author.role;
  if (role === 'owner') {
    return {
      text: t('groups.detail.owner'),
      class:
        'border-amber-200/60 bg-amber-100/60 text-amber-700 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-300'
    };
  }
  if (role === 'admin' || role === 'moderator') {
    return {
      text: t('groups.member.roles.admin'),
      class:
        'border-sky-200/60 bg-sky-100/60 text-sky-700 dark:border-sky-900/40 dark:bg-sky-950/40 dark:text-sky-300'
    };
  }
  return null;
});

const authorInitial = computed(() => {
  const source = props.post.author.nickname || props.post.author.username || '?';
  return source.slice(0, 1).toUpperCase();
});

const groupInitial = computed(() => {
  const source = props.post.group?.name || '?';
  return source.slice(0, 1).toUpperCase();
});

const handleLike = () => {
  isLiked.value = !isLiked.value;
  likeCount.value += isLiked.value ? 1 : -1;
  emit('like', props.post.id);
};

const handleComment = () => emit('comment', props.post.id);

const handlePin = () => {
  if (props.post.isPinned) {
    emit('unpin', props.post.id);
    toast.success(t('groups.post.feedback.unpinned'));
  } else {
    emit('pin', props.post.id);
    toast.success(t('groups.post.feedback.pinned'));
  }
};

const handleDelete = () => {
  emit('delete', props.post.id);
  toast.success(t('groups.post.feedback.deleted'));
};

const handleReport = () => emit('report', props.post.id);
const handleShare = () => emit('share', props.post.id);

const openAuthorProfile = () => {
  if (!Number.isFinite(props.post.author.id) || props.post.author.id <= 0) {
    return;
  }
  void navigateTo(localePath(`/user/${props.post.author.id}/profile`));
};
</script>

<template>
  <Card
    :class="[
      'group/post overflow-hidden rounded-xl border border-border/60 bg-card py-0 shadow-none transition-all duration-200 hover:border-border hover:shadow-md',
      post.isPinned && 'border-primary/40 bg-primary/[0.02]'
    ]"
  >
    <CardHeader class="space-y-3 px-4 pt-4 pb-2">
      <div
        v-if="groupContext"
        class="flex items-center gap-2 rounded-lg border border-border/60 bg-muted/30 px-2.5 py-1.5"
      >
        <Avatar class="h-5 w-5 ring-1 ring-border">
          <AvatarImage
            :src="groupContext.avatar"
            :alt="groupContext.name"
          />
          <AvatarFallback class="text-[10px]">
            {{ groupInitial }}
          </AvatarFallback>
        </Avatar>
        <span class="min-w-0 truncate text-xs font-medium">
          {{ groupContext.name }}
        </span>
        <span
          v-if="groupContext.canManage"
          class="ml-auto inline-flex h-5 items-center gap-1 rounded-full border border-border/60 bg-background px-1.5 text-[10px] font-medium text-muted-foreground"
        >
          {{ t('groups.posts.manageable') }}
        </span>
      </div>

      <div class="flex items-start justify-between gap-2">
        <button
          type="button"
          class="flex min-w-0 flex-1 items-center gap-3 rounded-md text-left"
          @click="openAuthorProfile"
        >
          <Avatar class="h-10 w-10 shrink-0 ring-1 ring-border">
            <AvatarImage
              :src="post.author.avatar"
              :alt="post.author.nickname"
            />
            <AvatarFallback class="text-xs">
              {{ authorInitial }}
            </AvatarFallback>
          </Avatar>
          <div class="min-w-0">
            <div class="flex min-w-0 items-center gap-1.5">
              <span class="truncate text-sm font-semibold">
                {{ post.author.nickname }}
              </span>
              <span
                v-if="roleBadge"
                :class="[
                  'inline-flex shrink-0 items-center rounded-full border px-1.5 py-0 text-[10px] font-medium',
                  roleBadge.class
                ]"
              >
                {{ roleBadge.text }}
              </span>
              <span
                v-if="post.isPinned"
                class="inline-flex shrink-0 items-center gap-1 rounded-full border border-border/60 bg-muted/40 px-1.5 py-0 text-[10px] font-medium text-muted-foreground"
              >
                <Pin class="h-2.5 w-2.5" />
                {{ t('groups.post.pinned') }}
              </span>
            </div>
            <div class="text-xs text-muted-foreground">
              @{{ post.author.username }} · {{ formatTime(post.createdAt) }}
            </div>
          </div>
        </button>

        <DropdownMenu>
          <DropdownMenuTrigger as-child>
            <Button
              variant="ghost"
              size="icon"
              class="h-8 w-8 shrink-0 rounded-full text-muted-foreground opacity-70 transition-opacity hover:bg-accent hover:opacity-100"
            >
              <MoreHorizontal class="h-4 w-4" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" class="w-48">
            <DropdownMenuItem @click="handleShare">
              <Share2 class="h-4 w-4" />
              {{ t('groups.post.actions.share') }}
            </DropdownMenuItem>
            <DropdownMenuSeparator v-if="canManage || isAuthor" />
            <DropdownMenuItem
              v-if="canManage"
              @click="handlePin"
            >
              <Pin class="h-4 w-4" />
              {{
                post.isPinned
                  ? t('groups.post.actions.unpin')
                  : t('groups.post.actions.pin')
              }}
            </DropdownMenuItem>
            <DropdownMenuItem
              v-if="canManage || isAuthor"
              class="text-destructive focus:text-destructive"
              @click="handleDelete"
            >
              <Trash2 class="h-4 w-4" />
              {{ t('groups.post.actions.delete') }}
            </DropdownMenuItem>
            <DropdownMenuSeparator v-if="!isAuthor" />
            <DropdownMenuItem
              v-if="!isAuthor"
              @click="handleReport"
            >
              <Flag class="h-4 w-4" />
              {{ t('groups.post.actions.report') }}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
    </CardHeader>

    <CardContent class="px-4 pb-3 pt-0">
      <p class="whitespace-pre-wrap text-sm leading-relaxed text-foreground">
        {{ post.content }}
      </p>

      <div
        v-if="post.media && post.media.length > 0"
        class="mt-3 grid gap-px overflow-hidden rounded-xl border border-border/60 bg-border"
        :class="{
          'grid-cols-1': post.media.length === 1,
          'grid-cols-2': post.media.length >= 2
        }"
      >
        <div
          v-for="(media, index) in post.media.slice(0, 4)"
          :key="index"
          class="group/media relative aspect-video overflow-hidden bg-muted"
        >
          <img
            :src="media.thumbnail || media.url"
            :alt="t('groups.post.mediaAlt', { index: index + 1 })"
            class="h-full w-full object-cover transition-transform duration-300 ease-out group-hover/media:scale-105"
          />
          <div
            v-if="media.type === 'video'"
            class="absolute inset-0 flex items-center justify-center bg-black/30 backdrop-blur-sm"
          >
            <div
              class="flex h-10 w-10 items-center justify-center rounded-full bg-white/90 text-foreground shadow-md"
            >
              <Play class="ml-0.5 h-4 w-4 fill-current" />
            </div>
          </div>
        </div>
      </div>
    </CardContent>

    <CardFooter
      class="flex items-center justify-between gap-1 border-t border-border/40 bg-muted/20 px-2 py-1"
    >
      <Button
        variant="ghost"
        size="sm"
        class="flex h-9 flex-1 items-center justify-center gap-2 rounded-md text-muted-foreground transition-colors hover:bg-rose-500/10 hover:text-rose-600 dark:hover:text-rose-400"
        :class="{ 'text-rose-600 dark:text-rose-400': isLiked }"
        @click="handleLike"
      >
        <Heart
          class="h-4 w-4"
          :class="{ 'fill-rose-600 dark:fill-rose-400': isLiked }"
        />
        <span class="tabular-nums text-xs font-medium">
          {{ likeCount }}
        </span>
      </Button>
      <Button
        variant="ghost"
        size="sm"
        class="flex h-9 flex-1 items-center justify-center gap-2 rounded-md text-muted-foreground transition-colors hover:bg-sky-500/10 hover:text-sky-600 dark:hover:text-sky-400"
        @click="handleComment"
      >
        <MessageCircle class="h-4 w-4" />
        <span class="tabular-nums text-xs font-medium">
          {{ post.commentCount }}
        </span>
      </Button>
      <Button
        variant="ghost"
        size="sm"
        class="flex h-9 flex-1 items-center justify-center gap-2 rounded-md text-muted-foreground transition-colors hover:bg-emerald-500/10 hover:text-emerald-600 dark:hover:text-emerald-400"
        @click="handleShare"
      >
        <Share2 class="h-4 w-4" />
      </Button>
    </CardFooter>
  </Card>
</template>
