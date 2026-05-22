<script setup lang="ts">
import { computed } from 'vue';
import {
  MoreHorizontal,
  Reply,
  Edit3,
  Trash2,
  Pin,
  Smile,
  Copy,
  Crown,
  Shield,
  FileText
} from 'lucide-vue-next';
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
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger
} from '@/components/ui/tooltip';

const { t } = useAppLocale();

// 消息类型定义
export interface ChatMessageType {
  id: number;
  channelId?: number;
  content: string;
  type: 'text' | 'image' | 'file' | 'system';
  author: {
    id: number;
    username: string;
    nickname: string;
    avatar: string;
    role?: 'owner' | 'admin' | 'moderator' | 'member';
    isOnline?: boolean;
  };
  createdAt: string;
  editedAt?: string;
  isPinned?: boolean;
  replyTo?: {
    id: number;
    content: string;
    author: {
      nickname: string;
    };
  };
  reactions?: Array<{
    emoji: string;
    count: number;
    reacted: boolean;
  }>;
  canDelete?: boolean;
  canPin?: boolean;
  attachments?: Array<{
    id: number;
    name: string;
    url: string;
    type: 'image' | 'file';
    size?: number;
  }>;
}

const props = defineProps<{
  message: ChatMessageType;
  isOwn?: boolean;
  showAvatar?: boolean;
  isFirstInGroup?: boolean;
}>();

const emit = defineEmits<{
  (e: 'reply', message: ChatMessageType): void;
  (e: 'edit', message: ChatMessageType): void;
  (e: 'delete', id: number): void;
  (e: 'pin', id: number): void;
  (e: 'react', id: number, emoji: string): void;
  (e: 'copy', content: string): void;
  (e: 'view-profile', userId: number): void;
}>();

const roleIcon = computed(() => {
  switch (props.message.author.role) {
    case 'owner':
      return Crown;
    case 'admin':
    case 'moderator':
      return Shield;
    default:
      return null;
  }
});

const roleBadge = computed(() => {
  switch (props.message.author.role) {
    case 'owner':
      return {
        label: t('groups.detail.owner'),
        class:
          'border-amber-200/60 bg-amber-100/60 text-amber-700 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-300'
      };
    case 'admin':
      return {
        label: t('groups.member.roles.admin'),
        class:
          'border-sky-200/60 bg-sky-100/60 text-sky-700 dark:border-sky-900/40 dark:bg-sky-950/40 dark:text-sky-300'
      };
    case 'moderator':
      return {
        label: t('groups.member.roles.moderator'),
        class:
          'border-emerald-200/60 bg-emerald-100/60 text-emerald-700 dark:border-emerald-900/40 dark:bg-emerald-950/40 dark:text-emerald-300'
      };
    default:
      return null;
  }
});

const authorInitial = computed(
  () =>
    (props.message.author.nickname || props.message.author.username || '?')
      .slice(0, 2)
      .toUpperCase()
);

// 格式化时间
const formatTime = (dateStr: string) => {
  const date = new Date(dateStr);
  const now = new Date();
  const diffMs = now.getTime() - date.getTime();
  const diffDays = Math.floor(diffMs / (1000 * 60 * 60 * 24));

  const hours = date.getHours().toString().padStart(2, '0');
  const minutes = date.getMinutes().toString().padStart(2, '0');

  if (diffDays === 0) {
    return t('time.todayAt', { time: `${hours}:${minutes}` });
  } else if (diffDays === 1) {
    return t('time.yesterdayAt', { time: `${hours}:${minutes}` });
  } else {
    return `${date.getMonth() + 1}/${date.getDate()} ${hours}:${minutes}`;
  }
};

const formatShortTime = (dateStr: string) => {
  const date = new Date(dateStr);
  return `${date.getHours().toString().padStart(2, '0')}:${date.getMinutes().toString().padStart(2, '0')}`;
};

const formatFileSize = (size?: number) => {
  if (!size) return '';
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`;
  return `${(size / (1024 * 1024)).toFixed(1)} MB`;
};

// 常用表情
const quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🎉'];

const handleReaction = (emoji: string) => {
  emit('react', props.message.id, emoji);
};

const handleCopy = () => {
  emit('copy', props.message.content);
};

const handleViewProfile = () => {
  emit('view-profile', props.message.author.id);
};
</script>

<template>
  <!-- 系统消息 -->
  <div
    v-if="message.type === 'system'"
    class="flex items-center justify-center px-4 py-2"
  >
    <div class="flex items-center gap-2 text-xs text-muted-foreground">
      <span class="h-px flex-1 max-w-[3rem] bg-border" />
      <span class="rounded-full border border-border/60 bg-muted/40 px-2.5 py-0.5">
        {{ message.content }}
      </span>
      <span class="h-px flex-1 max-w-[3rem] bg-border" />
    </div>
  </div>

  <!-- 普通消息 -->
  <div
    v-else
    class="group/msg relative px-4 transition-colors hover:bg-muted/30"
    :class="[
      isFirstInGroup ? 'mt-3 pt-1.5 pb-0.5' : 'py-0.5'
    ]"
  >
    <div class="flex gap-3">
      <!-- 头像区域 -->
      <div class="w-9 shrink-0">
        <button
          v-if="showAvatar && isFirstInGroup"
          type="button"
          class="rounded-full focus:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
          @click="handleViewProfile"
        >
          <Avatar class="h-9 w-9 ring-1 ring-border">
            <AvatarImage
              :src="message.author.avatar"
              :alt="message.author.nickname"
            />
            <AvatarFallback class="text-xs">
              {{ authorInitial }}
            </AvatarFallback>
          </Avatar>
        </button>
        <div
          v-else
          class="flex h-5 items-center justify-center opacity-0 transition-opacity group-hover/msg:opacity-100"
        >
          <span class="text-[10px] tabular-nums text-muted-foreground">
            {{ formatShortTime(message.createdAt) }}
          </span>
        </div>
      </div>

      <!-- 消息内容区域 -->
      <div class="min-w-0 flex-1">
        <!-- 用户名和时间 -->
        <div
          v-if="isFirstInGroup"
          class="mb-0.5 flex flex-wrap items-baseline gap-x-2 gap-y-1"
        >
          <button
            type="button"
            class="text-sm font-semibold hover:underline"
            @click="handleViewProfile"
          >
            {{ message.author.nickname }}
          </button>
          <span
            v-if="roleBadge"
            :class="[
              'inline-flex shrink-0 items-center gap-1 rounded-full border px-1.5 py-0 text-[10px] font-medium',
              roleBadge.class
            ]"
          >
            <component
              v-if="roleIcon"
              :is="roleIcon"
              class="h-2.5 w-2.5"
            />
            {{ roleBadge.label }}
          </span>
          <span
            v-if="message.isPinned"
            class="inline-flex shrink-0 items-center gap-1 rounded-full border border-border/60 bg-muted/40 px-1.5 py-0 text-[10px] font-medium text-muted-foreground"
          >
            <Pin class="h-2.5 w-2.5" />
            {{ t('chat.message.pinned') }}
          </span>
          <span class="text-[11px] tabular-nums text-muted-foreground">
            {{ formatTime(message.createdAt) }}
          </span>
        </div>

        <!-- 回复引用 -->
        <div
          v-if="message.replyTo"
          class="mb-1 flex items-center gap-1.5 rounded-md border-l-2 border-primary/40 bg-muted/40 px-2 py-1 text-xs"
        >
          <Reply class="h-3 w-3 shrink-0 text-muted-foreground" />
          <span class="shrink-0 font-medium text-foreground">
            {{ message.replyTo.author.nickname }}
          </span>
          <span class="min-w-0 truncate text-muted-foreground">
            {{ message.replyTo.content }}
          </span>
        </div>

        <!-- 消息内容 -->
        <div
          v-if="message.content"
          class="whitespace-pre-wrap break-words text-sm leading-relaxed text-foreground"
        >
          {{ message.content }}
          <span
            v-if="message.editedAt"
            class="ml-1 text-[10px] text-muted-foreground"
          >
            ({{ t('chat.message.edited') }})
          </span>
        </div>

        <!-- 图片附件 -->
        <div
          v-if="message.attachments?.some(a => a.type === 'image')"
          class="mt-1.5 flex flex-wrap gap-1.5"
        >
          <img
            v-for="attachment in message.attachments.filter(a => a.type === 'image')"
            :key="attachment.id"
            :src="attachment.url"
            :alt="attachment.name"
            class="max-h-64 max-w-xs cursor-pointer rounded-lg border border-border/60 object-cover transition-opacity hover:opacity-90"
          />
        </div>

        <!-- 文件附件 -->
        <div
          v-if="message.attachments?.some(a => a.type === 'file')"
          class="mt-1.5 space-y-1"
        >
          <a
            v-for="attachment in message.attachments.filter(a => a.type === 'file')"
            :key="attachment.id"
            :href="attachment.url"
            target="_blank"
            rel="noopener noreferrer"
            class="flex max-w-sm items-center gap-2.5 rounded-lg border border-border/60 bg-muted/30 px-2.5 py-2 transition-colors hover:border-border hover:bg-muted/50"
          >
            <div class="flex h-8 w-8 shrink-0 items-center justify-center rounded-md border border-border/60 bg-background">
              <FileText class="h-4 w-4 text-muted-foreground" />
            </div>
            <div class="min-w-0 flex-1">
              <div class="truncate text-sm font-medium">
                {{ attachment.name }}
              </div>
              <div
                v-if="attachment.size"
                class="text-[11px] tabular-nums text-muted-foreground"
              >
                {{ formatFileSize(attachment.size) }}
              </div>
            </div>
          </a>
        </div>

        <!-- 表情反应 -->
        <div
          v-if="message.reactions?.length"
          class="mt-1.5 flex flex-wrap gap-1"
        >
          <button
            v-for="reaction in message.reactions"
            :key="reaction.emoji"
            type="button"
            class="inline-flex h-6 items-center gap-1 rounded-full border px-2 text-xs tabular-nums transition-colors"
            :class="[
              reaction.reacted
                ? 'border-primary/40 bg-primary/10 text-foreground'
                : 'border-border/60 bg-muted/40 text-muted-foreground hover:border-border hover:bg-muted'
            ]"
            @click="handleReaction(reaction.emoji)"
          >
            <span>{{ reaction.emoji }}</span>
            <span class="font-medium">{{ reaction.count }}</span>
          </button>
        </div>
      </div>
    </div>

    <!-- 操作按钮（悬浮显示） -->
    <div
      class="absolute right-4 top-0 -translate-y-1/2 flex items-center gap-px rounded-md border border-border/60 bg-background p-0.5 opacity-0 shadow-sm transition-opacity group-hover/msg:opacity-100"
    >
      <TooltipProvider>
        <Tooltip
          v-for="emoji in quickReactions"
          :key="emoji"
        >
          <TooltipTrigger as-child>
            <button
              type="button"
              class="inline-flex h-7 w-7 items-center justify-center rounded-md text-base transition-colors hover:bg-accent"
              @click="handleReaction(emoji)"
            >
              {{ emoji }}
            </button>
          </TooltipTrigger>
          <TooltipContent side="top">
            <p>{{ emoji }}</p>
          </TooltipContent>
        </Tooltip>

        <span class="mx-0.5 h-5 w-px bg-border" aria-hidden="true" />

        <Tooltip>
          <TooltipTrigger as-child>
            <Button
              variant="ghost"
              size="icon"
              class="h-7 w-7 rounded-md text-muted-foreground hover:text-foreground"
            >
              <Smile class="h-3.5 w-3.5" />
            </Button>
          </TooltipTrigger>
          <TooltipContent side="top">
            <p>{{ t('chat.actions.addReaction') }}</p>
          </TooltipContent>
        </Tooltip>

        <Tooltip>
          <TooltipTrigger as-child>
            <Button
              variant="ghost"
              size="icon"
              class="h-7 w-7 rounded-md text-muted-foreground hover:text-foreground"
              @click="emit('reply', message)"
            >
              <Reply class="h-3.5 w-3.5" />
            </Button>
          </TooltipTrigger>
          <TooltipContent side="top">
            <p>{{ t('comment.reply') }}</p>
          </TooltipContent>
        </Tooltip>

        <DropdownMenu>
          <DropdownMenuTrigger as-child>
            <Button
              variant="ghost"
              size="icon"
              class="h-7 w-7 rounded-md text-muted-foreground hover:text-foreground"
            >
              <MoreHorizontal class="h-3.5 w-3.5" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" class="w-48">
            <DropdownMenuItem @click="handleCopy">
              <Copy class="h-4 w-4" />
              {{ t('chat.actions.copyText') }}
            </DropdownMenuItem>
            <DropdownMenuItem
              v-if="message.canPin"
              @click="emit('pin', message.id)"
            >
              <Pin class="h-4 w-4" />
              {{
                message.isPinned
                  ? t('chat.actions.unpinMessage')
                  : t('chat.actions.pinMessage')
              }}
            </DropdownMenuItem>
            <DropdownMenuSeparator v-if="isOwn || message.canDelete" />
            <DropdownMenuItem
              v-if="isOwn"
              @click="emit('edit', message)"
            >
              <Edit3 class="h-4 w-4" />
              {{ t('chat.actions.editMessage') }}
            </DropdownMenuItem>
            <DropdownMenuItem
              v-if="isOwn || message.canDelete"
              class="text-destructive focus:text-destructive"
              @click="emit('delete', message.id)"
            >
              <Trash2 class="h-4 w-4" />
              {{ t('chat.actions.deleteMessage') }}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </TooltipProvider>
    </div>
  </div>
</template>
