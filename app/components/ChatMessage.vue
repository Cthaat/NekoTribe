<script setup lang="ts">
import { computed } from 'vue';
import PrivateMediaDownload from '@/components/PrivateMediaDownload.vue';
import { isPrivateMediaContent } from '@/utils/private-media';
import {
  Copy,
  Crown,
  Edit3,
  FileText,
  MoreHorizontal,
  Pin,
  Reply,
  Shield,
  Smile,
  Trash2
} from 'lucide-vue-next';
import UserAvatar from '@/components/UserAvatar.vue';
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

const props = withDefaults(defineProps<{
  message: ChatMessageType;
  isOwn?: boolean;
  showAvatar?: boolean;
  isFirstInGroup?: boolean;
  isLastInGroup?: boolean;
  animate?: boolean;
  allowEdit?: boolean;
  allowDelete?: boolean;
  hideReply?: boolean;
}>(), { allowEdit: undefined, allowDelete: undefined, isLastInGroup: true, animate: false });

const showDeleteAction = computed(() => props.allowDelete ?? (props.isOwn || props.message.canDelete));
const showEditAction = computed(() => props.isOwn && props.message.type === 'text' && props.allowEdit !== false);

const emit = defineEmits<{
  (e: 'reply', message: ChatMessageType): void;
  (e: 'edit', message: ChatMessageType): void;
  (e: 'delete', id: number): void;
  (e: 'pin', id: number): void;
  (e: 'react', id: number, emoji: string): void;
  (e: 'copy', content: string): void;
  (e: 'view-profile', userId: number): void;
}>();

const privateAttachments = computed(() =>
  props.message.attachments?.filter(asset => isPrivateMediaContent(asset.id, asset.url)) ?? []
);
const publicImages = computed(() =>
  props.message.attachments?.filter(asset => asset.type === 'image' && !isPrivateMediaContent(asset.id, asset.url)) ?? []
);
const publicFiles = computed(() =>
  props.message.attachments?.filter(asset => asset.type === 'file' && !isPrivateMediaContent(asset.id, asset.url)) ?? []
);

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

const showTailAvatar = computed(() => props.showAvatar && props.isLastInGroup !== false);

const bubbleRadiusClass = computed(() => {
  if (props.isOwn) {
    return props.isFirstInGroup
      ? 'rounded-[18px] rounded-br-[4px]'
      : 'rounded-[18px] rounded-tr-[4px] rounded-br-[4px]';
  }
  return props.isFirstInGroup
    ? 'rounded-[18px] rounded-bl-[4px]'
    : 'rounded-[18px] rounded-tl-[4px] rounded-bl-[4px]';
});

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

  <!-- 普通消息 (Telegram / iMessage Bubble) -->
  <div
    v-else
    class="group/msg relative px-3 sm:px-4"
    :class="[
      isFirstInGroup ? 'mt-2.5' : 'mt-0.5',
      animate ? 'animate-bubble-in' : ''
    ]"
  >
    <div
      class="flex items-end gap-2"
      :class="isOwn ? 'justify-end' : 'justify-start'"
    >
      <!-- 他人头像区域（同组最后一条消息底部对齐） -->
      <div v-if="!isOwn" class="w-8 shrink-0">
        <button
          v-if="showTailAvatar"
          type="button"
          class="rounded-full focus:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
          @click="handleViewProfile"
        >
          <UserAvatar
            :src="message.author.avatar"
            :name="message.author.nickname"
            :username="message.author.username"
            :seed="message.author.id"
            size="sm"
          />
        </button>
      </div>

      <!-- 气泡主体 -->
      <div class="relative min-w-0 max-w-[78%] sm:max-w-[70%]">
        <div
          class="relative px-3.5 py-2.5 transition-colors"
          :class="[
            bubbleRadiusClass,
            isOwn
              ? 'bg-primary text-primary-foreground dark:bg-primary/20 dark:text-foreground'
              : 'bg-secondary text-foreground'
          ]"
        >
          <!-- 他人组首名称与徽章 -->
          <div
            v-if="!isOwn && isFirstInGroup"
            class="mb-1 flex flex-wrap items-center gap-x-1.5 gap-y-0.5"
          >
            <button
              type="button"
              class="text-xs font-bold text-primary hover:underline"
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
              class="inline-flex shrink-0 items-center gap-1 rounded-full bg-background/60 px-1.5 py-0 text-[10px] font-medium text-muted-foreground"
            >
              <Pin class="h-2.5 w-2.5" />
              {{ t('chat.message.pinned') }}
            </span>
          </div>

          <!-- 回复引用 -->
          <div
            v-if="message.replyTo"
            class="mb-1.5 flex items-center gap-1.5 rounded-lg border-l-2 px-2.5 py-1 text-xs"
            :class="isOwn ? 'border-primary-foreground/60 bg-black/15 text-primary-foreground/95 dark:border-primary/60 dark:bg-background/50 dark:text-foreground' : 'border-primary/50 bg-background/60 text-foreground'"
          >
            <Reply class="h-3 w-3 shrink-0 opacity-75" />
            <span class="shrink-0 font-semibold">
              {{ message.replyTo.author.nickname }}
            </span>
            <span class="min-w-0 truncate opacity-85">
              {{ message.replyTo.content }}
            </span>
          </div>

          <!-- 消息内容 -->
          <div
            v-if="message.content"
            class="whitespace-pre-wrap break-words text-sm leading-relaxed"
          >
            {{ message.content }}
            <span
              v-if="message.editedAt"
              class="ml-1 text-[10px] opacity-75"
            >
              ({{ t('chat.message.edited') }})
            </span>
          </div>

          <LinkPreviewCard :text="message.content" />

          <!-- 图片附件 -->
          <div
            v-if="publicImages.length"
            class="mt-1.5 flex flex-wrap gap-1.5"
          >
            <img
              v-for="attachment in publicImages"
              :key="attachment.id"
              :src="attachment.url"
              :alt="attachment.name"
              class="max-h-64 max-w-xs cursor-pointer rounded-xl object-cover transition-opacity hover:opacity-90"
            />
          </div>

          <!-- 文件附件 -->
          <div
            v-if="publicFiles.length || privateAttachments.length"
            class="mt-1.5 space-y-1"
          >
            <a
              v-for="attachment in publicFiles"
              :key="attachment.id"
              :href="attachment.url"
              target="_blank"
              rel="noopener noreferrer"
              class="flex max-w-sm items-center gap-2.5 rounded-xl bg-background/90 px-2.5 py-2 text-foreground transition-colors hover:bg-background"
            >
              <div class="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-[var(--hover)]">
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
            <PrivateMediaDownload
              v-for="attachment in privateAttachments"
              :key="attachment.id"
              :media-id="attachment.id"
              :file-name="attachment.name"
              class="max-w-sm"
            />
          </div>

          <!-- 表情反应 + 时间戳 -->
          <div class="mt-1 flex flex-wrap items-center justify-end gap-1.5">
            <div
              v-if="message.reactions?.length"
              class="mr-auto flex flex-wrap gap-1"
            >
              <button
                v-for="reaction in message.reactions"
                :key="reaction.emoji"
                type="button"
                class="inline-flex h-6 items-center gap-1 rounded-full px-2 text-xs tabular-nums transition-colors"
                :class="[
                  isOwn
                    ? (reaction.reacted ? 'bg-primary-foreground text-primary font-semibold' : 'bg-black/15 text-primary-foreground hover:bg-black/25')
                    : (reaction.reacted ? 'bg-primary/15 text-primary font-semibold' : 'bg-background/70 text-foreground hover:bg-background')
                ]"
                @click="handleReaction(reaction.emoji)"
              >
                <span>{{ reaction.emoji }}</span>
                <span>{{ reaction.count }}</span>
              </button>
            </div>
            <span
              v-if="message.isPinned && isOwn"
              class="inline-flex items-center gap-0.5 text-[10px] opacity-80"
            >
              <Pin class="h-2.5 w-2.5" />
            </span>
            <span
              class="text-[10px] tabular-nums"
              :class="isOwn ? 'text-primary-foreground/75' : 'text-muted-foreground'"
              :title="formatTime(message.createdAt)"
            >
              {{ formatShortTime(message.createdAt) }}
            </span>
          </div>
        </div>
      </div>
    </div>

    <!-- 操作按钮（悬浮显示） -->
    <div
      class="absolute top-0 -translate-y-1/2 z-10 flex items-center gap-px rounded-full border border-[var(--divider)] bg-background/95 p-0.5 opacity-0 shadow-sm backdrop-blur transition-opacity group-hover/msg:opacity-100"
      :class="isOwn ? 'left-4' : 'right-4'"
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
              class="size-8 text-muted-foreground hover:text-foreground"
              :aria-label="t('chat.actions.addReaction')"
            >
              <Smile class="h-3.5 w-3.5" />
            </Button>
          </TooltipTrigger>
          <TooltipContent side="top">
            <p>{{ t('chat.actions.addReaction') }}</p>
          </TooltipContent>
        </Tooltip>

        <Tooltip v-if="!hideReply">
          <TooltipTrigger as-child>
            <Button
              variant="ghost"
              size="icon"
              class="size-8 text-muted-foreground hover:text-foreground"
              :aria-label="t('comment.reply')"
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
              class="size-8 text-muted-foreground hover:text-foreground"
              :aria-label="t('common.more')"
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
            <DropdownMenuSeparator v-if="showEditAction || showDeleteAction" />
            <DropdownMenuItem
              v-if="showEditAction"
              @click="emit('edit', message)"
            >
              <Edit3 class="h-4 w-4" />
              {{ t('chat.actions.editMessage') }}
            </DropdownMenuItem>
            <DropdownMenuItem
              v-if="showDeleteAction"
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
