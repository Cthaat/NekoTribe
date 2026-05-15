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
      return 'destructive';
    case 'rejected':
      return 'outline';
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
};

const handleReject = () => {
  emit('reject', props.tweet.id);
};

const handleFlag = () => {
  emit('flag', props.tweet.id);
};

const handleViewDetail = () => {
  emit('view-detail', props.tweet);
};
</script>

<template>
  <Card
    class="gap-0 overflow-hidden rounded-lg border-border/70 bg-background py-0 shadow-sm transition-colors hover:bg-muted/20"
  >
    <CardHeader
      class="flex flex-col items-start justify-between gap-3 space-y-0 border-b bg-muted/20 px-4 py-3 !pb-3 sm:flex-row"
    >
      <!-- 用户信息 -->
      <div class="flex min-w-0 items-center gap-3">
        <Avatar class="h-10 w-10 shrink-0">
          <AvatarImage
            :src="tweet.author.avatar"
            :alt="tweet.author.nickname"
          />
          <AvatarFallback>{{
            tweet.author.nickname.charAt(0)
          }}</AvatarFallback>
        </Avatar>
        <div class="min-w-0">
          <div class="flex min-w-0 items-center gap-1">
            <span class="truncate text-sm font-semibold">{{
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
      <div
        class="flex max-w-full shrink-0 flex-wrap items-center gap-2 sm:justify-end"
      >
        <Badge variant="outline" class="capitalize">
          {{ tweet.priority }}
        </Badge>
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
              class="text-destructive focus:text-destructive"
            >
              <CheckCircle class="h-4 w-4 mr-2" />
              {{ t('moderation.actions.approveFull') }}
            </DropdownMenuItem>
            <DropdownMenuItem
              @click="handleReject"
              class="text-foreground"
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

    <CardContent class="p-4">
      <div class="grid gap-4 xl:grid-cols-[minmax(0,1fr)_16rem]">
        <div class="min-w-0 space-y-3">
          <!-- 推文内容 -->
          <p class="whitespace-pre-wrap text-sm leading-6 text-foreground">
            {{ tweet.content }}
          </p>

          <!-- 媒体预览 -->
          <div
            v-if="tweet.media && tweet.media.length > 0"
            class="flex max-w-[26rem] flex-wrap gap-2 rounded-md border bg-muted/30 p-2"
          >
            <div
              v-for="(media, index) in tweet.media.slice(0, 3)"
              :key="index"
              class="relative h-24 w-32 shrink-0 overflow-hidden rounded border bg-background"
            >
              <img
                :src="media.thumbnail || media.url"
                :alt="
                  t('moderation.card.mediaAlt', {
                    index: index + 1
                  })
                "
                class="h-full w-full object-cover"
              />
              <div
                v-if="media.type === 'video'"
                class="absolute inset-0 flex items-center justify-center bg-black/30"
              >
                <div
                  class="flex h-12 w-12 items-center justify-center rounded-full bg-white/80"
                >
                  <div
                    class="ml-1 h-0 w-0 border-y-[6px] border-l-[10px] border-y-transparent border-l-gray-800"
                  ></div>
                </div>
              </div>
              <div
                v-if="index === 2 && tweet.media.length > 3"
                class="absolute inset-0 flex items-center justify-center bg-background/80 text-sm font-medium"
              >
                +{{ tweet.media.length - 3 }}
              </div>
            </div>
          </div>
        </div>

        <Alert variant="destructive">
          <!-- 举报信息 -->
          <AlertTriangle class="h-4 w-4" />
          <AlertTitle>
            {{
              t('moderation.card.reportCount', {
                count: tweet.reportCount
              })
            }}
          </AlertTitle>
          <AlertDescription class="space-y-3">
            <div class="flex flex-wrap gap-1">
              <Badge
                v-for="reason in tweet.reportReasons"
                :key="reason"
                variant="outline"
                class="text-xs"
              >
                {{ getReasonLabel(reason) }}
              </Badge>
            </div>

            <!-- 时间信息 -->
            <div
              class="space-y-2 border-t pt-3 text-xs"
            >
              <div class="flex items-center gap-2">
                <Clock class="h-3 w-3" />
                <span>{{
                  t('moderation.card.publishedAt', {
                    time: formatTime(tweet.createdAt)
                  })
                }}</span>
              </div>
              <div class="flex items-center gap-2">
                <Flag class="h-3 w-3" />
                <span>{{
                  t('moderation.card.reportedAt', {
                    time: formatTime(tweet.reportedAt)
                  })
                }}</span>
              </div>
            </div>
          </AlertDescription>
        </Alert>
      </div>
    </CardContent>

    <CardFooter
      class="flex flex-wrap items-center justify-between gap-3 border-t bg-muted/10 px-4 py-3 !pt-3"
    >
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
      <div class="flex flex-wrap items-center gap-2">
        <Button
          variant="destructive"
          size="sm"
          @click="handleApprove"
        >
          <CheckCircle class="h-4 w-4 mr-1" />
          {{ t('moderation.actions.approve') }}
        </Button>
        <Button
          variant="outline"
          size="sm"
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
