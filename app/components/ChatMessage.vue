<script setup lang="ts">
import { computed } from 'vue';
import {
  MoreHorizontal,
  Reply,
  Edit3,
  Trash2,
  Pin,
  Smile,
  Copy
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
import { Badge } from '@/components/ui/badge';

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

// 获取角色颜色
const roleColor = computed(() => {
  switch (props.message.author.role) {
    case 'owner':
      return 'text-amber-500';
    case 'admin':
      return 'text-blue-500';
    case 'moderator':
      return 'text-emerald-500';
    default:
      return 'text-foreground';
  }
});

// 获取角色标签
const roleBadge = computed(() => {
  switch (props.message.author.role) {
    case 'owner':
      return { label: t('groups.detail.owner'), variant: 'default' as const };
    case 'admin':
      return {
        label: t('groups.member.roles.admin'),
        variant: 'secondary' as const
      };
    case 'moderator':
      return {
        label: t('groups.member.roles.moderator'),
        variant: 'outline' as const
      };
    default:
      return null;
  }
});

// 格式化时间
const formatTime = (dateStr: string) => {
  const date = new Date(dateStr);
  const now = new Date();
  const diffMs = now.getTime() - date.getTime();
  const diffDays = Math.floor(
    diffMs / (1000 * 60 * 60 * 24)
  );

  if (diffDays === 0) {
    return t('time.todayAt', {
      time: `${date.getHours().toString().padStart(2, '0')}:${date.getMinutes().toString().padStart(2, '0')}`
    });
  } else if (diffDays === 1) {
    return t('time.yesterdayAt', {
      time: `${date.getHours().toString().padStart(2, '0')}:${date.getMinutes().toString().padStart(2, '0')}`
    });
  } else {
    return `${date.getMonth() + 1}/${date.getDate()} ${date.getHours().toString().padStart(2, '0')}:${date.getMinutes().toString().padStart(2, '0')}`;
  }
};

// 常用表情
const quickReactions = ['👍', '❤️', '😂', '😮', '😢', '😡'];

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
    class="flex justify-center py-2"
  >
    <span
      class="text-xs text-muted-foreground bg-muted px-3 py-1 rounded-full"
    >
      {{ message.content }}
    </span>
  </div>

  <!-- 普通消息 -->
  <div
    v-else
    class="group px-4 py-1 transition-colors relative"
    :class="{ 'mt-4': isFirstInGroup, 'flex justify-end': isOwn, 'flex': !isOwn }"
  >
    <!-- 头像区域 -->
    <div v-if="showAvatar && !isOwn" class="w-10 flex-shrink-0">
      <Button
        type="button"
        variant="ghost"
        class="h-10 w-10 rounded-full p-0"
        @click="handleViewProfile"
      >
        <Avatar class="h-10 w-10">
          <AvatarImage
            :src="message.author.avatar"
            :alt="message.author.nickname"
          />
          <AvatarFallback>{{ message.author.nickname.slice(0, 2) }}</AvatarFallback>
        </Avatar>
      </Button>
    </div>

    <!-- 消息内容区域 -->
    <div class="flex-1 min-w-0 flex flex-col">
      <!-- 用户名和时间 -->
      <div
        v-if="isFirstInGroup"
        class="flex items-center gap-2 mb-1"
      >
        <Button
          type="button"
          variant="link"
          class="h-auto p-0 font-medium"
          :class="roleColor"
          @click="handleViewProfile"
        >
          {{ message.author.nickname }}
        </Button>
        <Badge
          v-if="roleBadge"
          :variant="roleBadge.variant"
          class="text-xs h-5"
        >
          {{ roleBadge.label }}
        </Badge>
        <span class="text-xs text-muted-foreground">
          {{ formatTime(message.createdAt) }}
        </span>
        <Badge
          v-if="message.isPinned"
          variant="outline"
          class="text-xs h-5 gap-1"
        >
          <Pin class="h-3 w-3" />
          {{ t('chat.message.pinned') }}
        </Badge>
      </div>

      <!-- 回复引用 -->
      <div
        v-if="message.replyTo"
        class="flex items-center gap-2 text-xs text-muted-foreground mb-1 pl-2 border-l-2 border-muted-foreground/30"
      >
        <Reply class="h-3 w-3" />
        <span class="font-medium">{{
          message.replyTo.author.nickname
        }}</span>
        <span class="truncate max-w-xs">{{
          message.replyTo.content
        }}</span>
      </div>

      <!-- 气泡容器 -->
      <div class="mt-0">
        <div :class="[
          'inline-block text-sm whitespace-pre-wrap break-words',
          isOwn
            ? 'ml-auto text-right rounded-2xl px-4 py-2 shadow-md bg-gradient-to-r from-primary to-primary/80 text-white'
            : 'rounded-2xl px-4 py-2 bg-card text-foreground border'
        ]">
          {{ message.content }}
          <span v-if="message.editedAt" class="text-xs text-muted-foreground ml-1">{{ t('chat.message.edited') }}</span>
        </div>
      </div>

      <!-- 图片附件 -->
      <div v-if="message.attachments?.some(a => a.type === 'image')" class="mt-2 flex flex-wrap gap-2">
        <img
          v-for="attachment in message.attachments.filter(a => a.type === 'image')"
          :key="attachment.id"
          :src="attachment.url"
          :alt="attachment.name"
          class="max-w-xs max-h-64 rounded-2xl cursor-pointer hover:opacity-90 transition-opacity border"
        />
      </div>

      <!-- 文件附件 -->
      <div
        v-if="
          message.attachments?.some(a => a.type === 'file')
        "
        class="mt-2 space-y-1"
      >
        <div
          v-for="attachment in message.attachments.filter(
            a => a.type === 'file'
          )"
          :key="attachment.id"
          class="flex items-center gap-2 p-2 bg-muted rounded-lg max-w-xs"
        >
          <div class="p-2 bg-background rounded">📄</div>
          <div class="flex-1 min-w-0">
            <Button
              as="a"
              :href="attachment.url"
              target="_blank"
              rel="noopener noreferrer"
              variant="link"
              class="h-auto max-w-full justify-start truncate p-0 text-sm font-medium"
            >
              {{ attachment.name }}
            </Button>
            <div class="text-xs text-muted-foreground">
              {{
                attachment.size
                  ? `${(attachment.size / 1024).toFixed(1)} KB`
                  : ''
              }}
            </div>
          </div>
        </div>
      </div>

      <!-- 表情反应 -->
      <div v-if="message.reactions?.length" class="mt-2 flex flex-wrap gap-1">
        <Button
          v-for="reaction in message.reactions"
          :key="reaction.emoji"
          variant="outline"
          size="sm"
          class="h-6 px-2 text-xs gap-1"
          :class="{ 'bg-primary/10 border-primary': reaction.reacted }"
          @click="handleReaction(reaction.emoji)"
        >
          {{ reaction.emoji }}
          <span class="text-muted-foreground">{{ reaction.count }}</span>
        </Button>
      </div>
    </div>

    <!-- 操作按钮（悬浮显示） -->
    <div class="absolute right-4 top-0 -translate-y-1/2 opacity-0 group-hover:opacity-100 transition-opacity flex items-center gap-0.5 bg-background border rounded-lg shadow-sm p-0.5">
      <TooltipProvider>
        <!-- 快速表情 -->
        <Tooltip
          v-for="emoji in quickReactions"
          :key="emoji"
        >
          <TooltipTrigger as-child>
            <Button
              variant="ghost"
              size="sm"
              class="h-7 w-7 p-0 text-base"
              @click="handleReaction(emoji)"
            >
              {{ emoji }}
            </Button>
          </TooltipTrigger>
          <TooltipContent side="top">
            <p>{{ emoji }}</p>
          </TooltipContent>
        </Tooltip>

        <!-- 表情选择器 -->
        <Tooltip>
          <TooltipTrigger as-child>
            <Button
              variant="ghost"
              size="sm"
              class="h-7 w-7 p-0"
            >
              <Smile class="h-4 w-4" />
            </Button>
          </TooltipTrigger>
          <TooltipContent side="top">
            <p>{{ t('chat.actions.addReaction') }}</p>
          </TooltipContent>
        </Tooltip>

        <!-- 回复 -->
        <Tooltip>
          <TooltipTrigger as-child>
            <Button
              variant="ghost"
              size="sm"
              class="h-7 w-7 p-0"
              @click="emit('reply', message)"
            >
              <Reply class="h-4 w-4" />
            </Button>
          </TooltipTrigger>
          <TooltipContent side="top">
            <p>{{ t('comment.reply') }}</p>
          </TooltipContent>
        </Tooltip>

        <!-- 更多操作 -->
        <DropdownMenu>
          <DropdownMenuTrigger as-child>
            <Button
              variant="ghost"
              size="sm"
              class="h-7 w-7 p-0"
            >
              <MoreHorizontal class="h-4 w-4" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem @click="handleCopy">
              <Copy class="mr-2 h-4 w-4" />
              {{ t('chat.actions.copyText') }}
            </DropdownMenuItem>
            <DropdownMenuItem
              v-if="message.canPin"
              @click="emit('pin', message.id)"
            >
              <Pin class="mr-2 h-4 w-4" />
              {{
                message.isPinned
                  ? t('chat.actions.unpinMessage')
                  : t('chat.actions.pinMessage')
              }}
            </DropdownMenuItem>
            <DropdownMenuSeparator
              v-if="isOwn || message.canDelete"
            />
            <DropdownMenuItem
              v-if="isOwn"
              @click="emit('edit', message)"
            >
              <Edit3 class="mr-2 h-4 w-4" />
              {{ t('chat.actions.editMessage') }}
            </DropdownMenuItem>
            <DropdownMenuItem
              v-if="isOwn || message.canDelete"
              class="text-destructive focus:text-destructive"
              @click="emit('delete', message.id)"
            >
              <Trash2 class="mr-2 h-4 w-4" />
              {{ t('chat.actions.deleteMessage') }}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </TooltipProvider>
    </div>
  </div>
</template>
