<script setup lang="ts">
import { ref, computed } from 'vue';
import {
  Heart,
  MessageCircle,
  Repeat,
  MoreHorizontal,
  Flag,
  CheckCircle,
  XCircle,
  Eye,
  Clock,
  AlertTriangle
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
import { Badge } from '@/components/ui/badge';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger
} from '@/components/ui/dropdown-menu';
import { toast } from 'vue-sonner';
import type {
  ModerationReportReasonVM,
  ModerationTweetVM
} from '@/types/moderation';

export type ModerationReportReason =
  ModerationReportReasonVM;
export type ModerationTweet = ModerationTweetVM;

const props = defineProps<{
  tweet: ModerationTweet;
}>();

const { t } = useAppLocale();

const reasonLabelKeys: Record<ModerationReportReason, string> = {
  spam: 'moderation.filters.reasons.spam',
  harassment: 'moderation.filters.reasons.harassment',
  hate: 'moderation.filters.reasons.hate',
  violence: 'moderation.filters.reasons.violence',
  adult: 'moderation.filters.reasons.adult',
  misinformation: 'moderation.filters.reasons.misinformation',
  copyright: 'moderation.filters.reasons.copyright',
  other: 'moderation.filters.reasons.other'
};

const emit = defineEmits<{
  (e: 'approve', id: number): void;
  (e: 'reject', id: number): void;
  (e: 'flag', id: number): void;
  (e: 'view-detail', tweet: ModerationTweet): void;
}>();

// 获取状态徽章变体
const statusBadgeVariant = computed(() => {
  switch (props.tweet.status) {
    case 'pending':
      return 'secondary';
    case 'approved':
      return 'default';
    case 'rejected':
      return 'destructive';
    case 'flagged':
      return 'outline';
    case 'removed':
      return 'destructive';
    case 'restored':
      return 'default';
    default:
      return 'secondary';
  }
});

// 获取状态文本
const statusText = computed(() => {
  switch (props.tweet.status) {
    case 'pending':
      return t('moderation.status.pending');
    case 'approved':
      return t('moderation.status.approved');
    case 'rejected':
      return t('moderation.status.rejected');
    case 'flagged':
      return t('moderation.status.flagged');
    case 'removed':
      return t('moderation.status.removed');
    case 'restored':
      return t('moderation.status.restored');
    default:
      return t('moderation.status.unknown');
  }
});

// 格式化时间
const formatTime = (dateStr: string): string => {
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
    return t('time.daysAgo', { count: days });
  }
};

const getReasonLabel = (
  reason: ModerationReportReason
): string => t(reasonLabelKeys[reason]);

// 处理审核操作
const handleApprove = () => {
  emit('approve', props.tweet.id);
  toast.success(t('moderation.feedback.approved'));
};

const handleReject = () => {
  emit('reject', props.tweet.id);
  toast.success(t('moderation.feedback.rejected'));
};

const handleFlag = () => {
  emit('flag', props.tweet.id);
  toast.info(t('moderation.feedback.flagged'));
};

const handleViewDetail = () => {
  emit('view-detail', props.tweet);
};
</script>

<template>
  <Card class="hover:bg-muted/50 transition-colors">
    <CardHeader
      class="flex flex-row items-start justify-between space-y-0 pb-2"
    >
      <!-- 用户信息 -->
      <div class="flex items-center gap-3">
        <Avatar class="h-10 w-10">
          <AvatarImage
            :src="tweet.author.avatar"
            :alt="tweet.author.nickname"
          />
          <AvatarFallback>{{
            tweet.author.nickname.charAt(0)
          }}</AvatarFallback>
        </Avatar>
        <div class="flex flex-col">
          <div class="flex items-center gap-1">
            <span class="font-semibold text-sm">{{
              tweet.author.nickname
            }}</span>
            <span
              v-if="tweet.author.isVerified"
              class="text-primary"
            >
              <CheckCircle class="h-4 w-4" />
            </span>
          </div>
          <span class="text-xs text-muted-foreground"
            >@{{ tweet.author.username }}</span
          >
        </div>
      </div>

      <!-- 状态和操作 -->
      <div class="flex items-center gap-2">
        <Badge :variant="statusBadgeVariant">
          {{ statusText }}
        </Badge>
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
            <DropdownMenuItem @click="handleViewDetail">
              <Eye class="h-4 w-4 mr-2" />
              {{ t('moderation.actions.viewDetail') }}
            </DropdownMenuItem>
            <DropdownMenuSeparator />
            <DropdownMenuItem
              @click="handleApprove"
              class="text-green-600"
            >
              <CheckCircle class="h-4 w-4 mr-2" />
              {{ t('moderation.actions.approveFull') }}
            </DropdownMenuItem>
            <DropdownMenuItem
              @click="handleReject"
              class="text-destructive"
            >
              <XCircle class="h-4 w-4 mr-2" />
              {{ t('moderation.actions.rejectPost') }}
            </DropdownMenuItem>
            <DropdownMenuItem
              @click="handleFlag"
              class="text-yellow-600"
            >
              <Flag class="h-4 w-4 mr-2" />
              {{ t('moderation.actions.flag') }}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
    </CardHeader>

    <CardContent class="pb-3">
      <!-- 推文内容 -->
      <p class="text-sm whitespace-pre-wrap mb-3">
        {{ tweet.content }}
      </p>

      <!-- 媒体预览 -->
      <div
        v-if="tweet.media && tweet.media.length > 0"
        class="grid gap-2 mb-3"
        :class="{
          'grid-cols-1': tweet.media.length === 1,
          'grid-cols-2': tweet.media.length >= 2
        }"
      >
        <div
          v-for="(media, index) in tweet.media.slice(0, 4)"
          :key="index"
          class="relative aspect-video rounded-lg overflow-hidden bg-muted"
        >
          <img
            :src="media.thumbnail || media.url"
            :alt="
              t('moderation.card.mediaAlt', {
                index: index + 1
              })
            "
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
              ></div>
            </div>
          </div>
        </div>
      </div>

      <!-- 举报信息 -->
      <div
        class="flex items-center gap-2 p-3 bg-destructive/10 rounded-lg"
      >
        <AlertTriangle class="h-4 w-4 text-destructive" />
        <div class="flex-1">
          <span class="text-sm font-medium text-destructive"
            >{{
              t('moderation.card.reportCount', {
                count: tweet.reportCount
              })
            }}</span
          >
          <div class="flex flex-wrap gap-1 mt-1">
            <Badge
              v-for="reason in tweet.reportReasons"
              :key="reason"
              variant="outline"
              class="text-xs"
            >
              {{ getReasonLabel(reason) }}
            </Badge>
          </div>
        </div>
      </div>

      <!-- 时间信息 -->
      <div
        class="flex items-center gap-4 mt-3 text-xs text-muted-foreground"
      >
        <div class="flex items-center gap-1">
          <Clock class="h-3 w-3" />
          <span
            >{{
              t('moderation.card.publishedAt', {
                time: formatTime(tweet.createdAt)
              })
            }}</span
          >
        </div>
        <div class="flex items-center gap-1">
          <Flag class="h-3 w-3" />
          <span
            >{{
              t('moderation.card.reportedAt', {
                time: formatTime(tweet.reportedAt)
              })
            }}</span
          >
        </div>
      </div>
    </CardContent>

    <CardFooter class="flex justify-between border-t pt-3">
      <!-- 互动数据 -->
      <div
        class="flex items-center gap-4 text-muted-foreground"
      >
        <div class="flex items-center gap-1 text-sm">
          <Heart class="h-4 w-4" />
          <span>{{ tweet.likes }}</span>
        </div>
        <div class="flex items-center gap-1 text-sm">
          <Repeat class="h-4 w-4" />
          <span>{{ tweet.retweets }}</span>
        </div>
        <div class="flex items-center gap-1 text-sm">
          <MessageCircle class="h-4 w-4" />
          <span>{{ tweet.replies }}</span>
        </div>
      </div>

      <!-- 快速操作按钮 -->
      <div class="flex items-center gap-2">
        <Button
          variant="outline"
          size="sm"
          class="text-green-600 hover:text-green-700 hover:bg-green-50"
          @click="handleApprove"
        >
          <CheckCircle class="h-4 w-4 mr-1" />
          {{ t('moderation.actions.approve') }}
        </Button>
        <Button
          variant="outline"
          size="sm"
          class="text-destructive hover:bg-destructive/10"
          @click="handleReject"
        >
          <XCircle class="h-4 w-4 mr-1" />
          {{ t('moderation.actions.reject') }}
        </Button>
        <Button
          variant="ghost"
          size="sm"
          class="text-yellow-600 hover:text-yellow-700"
          @click="handleFlag"
        >
          <Flag class="h-4 w-4" />
        </Button>
      </div>
    </CardFooter>
  </Card>
</template>
