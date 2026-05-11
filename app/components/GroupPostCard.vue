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
  Users
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
import {
  Alert,
  AlertDescription,
  AlertTitle
} from '@/components/ui/alert';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
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

// 格式化时间
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
    return date.toLocaleDateString(locale.value === 'zh' ? 'zh-CN' : 'en-US', {
      month: 'short',
      day: 'numeric'
    });
  }
};

// 获取角色徽章
const getRoleBadge = (role: string) => {
  switch (role) {
    case 'owner':
      return { text: t('groups.detail.owner'), variant: 'default' as const };
    case 'admin':
    case 'moderator':
      return {
        text: t('groups.member.roles.admin'),
        variant: 'secondary' as const
      };
    default:
      return null;
  }
};

// 处理点赞
const handleLike = () => {
  isLiked.value = !isLiked.value;
  likeCount.value += isLiked.value ? 1 : -1;
  emit('like', props.post.id);
};

// 处理评论
const handleComment = () => {
  emit('comment', props.post.id);
};

// 处理置顶
const handlePin = () => {
  if (props.post.isPinned) {
    emit('unpin', props.post.id);
    toast.success(t('groups.post.feedback.unpinned'));
  } else {
    emit('pin', props.post.id);
    toast.success(t('groups.post.feedback.pinned'));
  }
};

// 处理删除
const handleDelete = () => {
  emit('delete', props.post.id);
  toast.success(t('groups.post.feedback.deleted'));
};

// 处理举报
const handleReport = () => {
  emit('report', props.post.id);
  toast.success(t('groups.post.feedback.reported'));
};

// 处理分享
const handleShare = () => {
  emit('share', props.post.id);
};

const openAuthorProfile = () => {
  if (!Number.isFinite(props.post.author.id) || props.post.author.id <= 0) {
    return;
  }
  void navigateTo(localePath(`/user/${props.post.author.id}/profile`));
};
</script>

<template>
  <Card
    :class="{
      'border-primary/50 bg-primary/5': post.isPinned
    }"
  >
    <CardHeader class="space-y-3 pb-2">
      <Alert
        v-if="groupContext"
        class="bg-muted/30"
      >
        <Users class="h-4 w-4" />
        <AlertTitle class="flex min-w-0 items-center gap-2">
          <Avatar class="h-6 w-6">
            <AvatarImage
              :src="groupContext.avatar"
              :alt="groupContext.name"
            />
            <AvatarFallback>{{
              groupContext.name.charAt(0)
            }}</AvatarFallback>
          </Avatar>
          <span class="truncate">{{ groupContext.name }}</span>
          <Badge
            v-if="groupContext.canManage"
            variant="outline"
            class="ml-auto text-xs"
          >
            {{ t('groups.posts.manageable') }}
          </Badge>
        </AlertTitle>
        <AlertDescription>
          {{ t('groups.posts.groupContext') }}
        </AlertDescription>
      </Alert>

      <div class="flex items-start justify-between gap-3">
        <!-- 作者信息 -->
        <Button
          type="button"
          variant="ghost"
          class="h-auto min-w-0 justify-start gap-3 px-2 py-2 text-left"
          @click="openAuthorProfile"
        >
          <Avatar class="h-10 w-10">
            <AvatarImage
              :src="post.author.avatar"
              :alt="post.author.nickname"
            />
            <AvatarFallback>{{
              post.author.nickname.charAt(0)
            }}</AvatarFallback>
          </Avatar>
          <div class="flex flex-col">
            <div class="flex items-center gap-2">
              <span class="font-semibold text-sm">{{
                post.author.nickname
              }}</span>
              <Badge
                v-if="getRoleBadge(post.author.role)"
                :variant="
                  getRoleBadge(post.author.role)?.variant
                "
                class="text-xs"
              >
                {{ getRoleBadge(post.author.role)?.text }}
              </Badge>
              <Badge
                v-if="post.isPinned"
                variant="outline"
                class="gap-1 text-xs"
              >
                <Pin class="h-3 w-3" />
                {{ t('groups.post.pinned') }}
              </Badge>
            </div>
            <span class="text-xs text-muted-foreground">
              @{{ post.author.username }} ·
              {{ formatTime(post.createdAt) }}
            </span>
          </div>
        </Button>

        <!-- 操作菜单 -->
        <DropdownMenu>
          <DropdownMenuTrigger as-child>
            <Button
              variant="ghost"
              size="icon"
              class="h-8 w-8"
            >
              <MoreHorizontal class="h-4 w-4" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem @click="handleShare">
              <Share2 class="h-4 w-4 mr-2" />
              {{ t('groups.post.actions.share') }}
            </DropdownMenuItem>
            <DropdownMenuSeparator
              v-if="canManage || isAuthor"
            />
            <DropdownMenuItem
              v-if="canManage"
              @click="handlePin"
            >
              <Pin class="h-4 w-4 mr-2" />
              {{
                post.isPinned
                  ? t('groups.post.actions.unpin')
                  : t('groups.post.actions.pin')
              }}
            </DropdownMenuItem>
            <DropdownMenuItem
              v-if="canManage || isAuthor"
              class="text-destructive"
              @click="handleDelete"
            >
              <Trash2 class="h-4 w-4 mr-2" />
              {{ t('groups.post.actions.delete') }}
            </DropdownMenuItem>
            <DropdownMenuSeparator v-if="!isAuthor" />
            <DropdownMenuItem
              v-if="!isAuthor"
              @click="handleReport"
            >
              <Flag class="h-4 w-4 mr-2" />
              {{ t('groups.post.actions.report') }}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
    </CardHeader>

    <CardContent class="pb-3">
      <!-- 帖子内容 -->
      <p class="text-sm whitespace-pre-wrap mb-3">
        {{ post.content }}
      </p>

      <!-- 媒体预览 -->
      <div
        v-if="post.media && post.media.length > 0"
        class="grid gap-2"
        :class="{
          'grid-cols-1': post.media.length === 1,
          'grid-cols-2': post.media.length >= 2
        }"
      >
        <div
          v-for="(media, index) in post.media.slice(0, 4)"
          :key="index"
          class="relative aspect-video rounded-lg overflow-hidden bg-muted"
        >
          <img
            :src="media.thumbnail || media.url"
            :alt="t('groups.post.mediaAlt', { index: index + 1 })"
            class="w-full h-full object-cover"
          />
          <div
            v-if="media.type === 'video'"
            class="absolute inset-0 flex items-center justify-center bg-black/30"
          >
            <div
              class="w-12 h-12 rounded-full bg-white/80 flex items-center justify-center"
            >
              <div
                class="w-0 h-0 border-t-6 border-b-6 border-l-10 border-transparent border-l-gray-800 ml-1"
              />
            </div>
          </div>
        </div>
      </div>
    </CardContent>

    <CardFooter class="border-t pt-3">
      <!-- 互动按钮 -->
      <div class="flex items-center gap-4">
        <Button
          variant="ghost"
          size="sm"
          class="gap-1"
          :class="{ 'text-pink-500': isLiked }"
          @click="handleLike"
        >
          <Heart
            :class="[
              'h-4 w-4',
              { 'fill-current': isLiked }
            ]"
          />
          <span>{{ likeCount }}</span>
        </Button>
        <Button
          variant="ghost"
          size="sm"
          class="gap-1"
          @click="handleComment"
        >
          <MessageCircle class="h-4 w-4" />
          <span>{{ post.commentCount }}</span>
        </Button>
        <Button
          variant="ghost"
          size="sm"
          @click="handleShare"
        >
          <Share2 class="h-4 w-4" />
        </Button>
      </div>
    </CardFooter>
  </Card>
</template>
