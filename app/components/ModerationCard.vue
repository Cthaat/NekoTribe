<script setup lang="ts">
import { computed } from 'vue';
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
  AlertTriangle,
  Play,
  Sparkles
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

const statusBadge = computed(() => {
  switch (props.tweet.status) {
    case 'pending':
      return {
        label: t('moderation.status.pending'),
        class:
          'border-amber-200/60 bg-amber-100/60 text-amber-700 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-300'
      };
    case 'approved':
      return {
        label: t('moderation.status.approved'),
        class:
          'border-emerald-200/60 bg-emerald-100/60 text-emerald-700 dark:border-emerald-900/40 dark:bg-emerald-950/40 dark:text-emerald-300'
      };
    case 'rejected':
      return {
        label: t('moderation.status.rejected'),
        class:
          'border-border/60 bg-muted/40 text-muted-foreground'
      };
    case 'flagged':
      return {
        label: t('moderation.status.flagged'),
        class:
          'border-orange-200/60 bg-orange-100/60 text-orange-700 dark:border-orange-900/40 dark:bg-orange-950/40 dark:text-orange-300'
      };
    case 'removed':
      return {
        label: t('moderation.status.removed'),
        class:
          'border-rose-200/60 bg-rose-100/60 text-rose-700 dark:border-rose-900/40 dark:bg-rose-950/40 dark:text-rose-300'
      };
    case 'restored':
      return {
        label: t('moderation.status.restored'),
        class:
          'border-sky-200/60 bg-sky-100/60 text-sky-700 dark:border-sky-900/40 dark:bg-sky-950/40 dark:text-sky-300'
      };
    default:
      return {
        label: t('moderation.status.unknown'),
        class:
          'border-border/60 bg-muted/40 text-muted-foreground'
      };
  }
});

const priorityBadge = computed(() => {
  const priority = props.tweet.priority?.toLowerCase();
  if (priority === 'urgent' || priority === 'high') {
    return 'border-rose-200/60 bg-rose-100/60 text-rose-700 dark:border-rose-900/40 dark:bg-rose-950/40 dark:text-rose-300';
  }
  if (priority === 'medium') {
    return 'border-amber-200/60 bg-amber-100/60 text-amber-700 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-300';
  }
  return 'border-border/60 bg-muted/40 text-muted-foreground';
});

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

const handleApprove = () => emit('approve', props.tweet.id);
const handleReject = () => emit('reject', props.tweet.id);
const handleFlag = () => emit('flag', props.tweet.id);
const handleViewDetail = () =>
  emit('view-detail', props.tweet);
</script>

<template>
  <div
    class="overflow-hidden rounded-xl border border-border/60 bg-card shadow-none transition-shadow hover:shadow-md"
  >
    <div
      class="flex flex-col items-start justify-between gap-3 border-b border-border/60 bg-muted/20 px-4 py-3 sm:flex-row sm:items-center"
    >
      <div class="flex min-w-0 items-center gap-3">
        <Avatar class="h-10 w-10 shrink-0 ring-1 ring-border">
          <AvatarImage
            :src="tweet.author.avatar"
            :alt="tweet.author.nickname"
          />
          <AvatarFallback class="text-xs">{{
            tweet.author.nickname.charAt(0).toUpperCase()
          }}</AvatarFallback>
        </Avatar>
        <div class="min-w-0">
          <div class="flex min-w-0 items-center gap-1.5">
            <span class="truncate text-sm font-semibold">
              {{ tweet.author.nickname }}
            </span>
            <Sparkles
              v-if="tweet.author.isVerified"
              class="h-3.5 w-3.5 shrink-0 text-sky-500"
            />
          </div>
          <span class="text-xs text-muted-foreground">
            @{{ tweet.author.username }}
          </span>
        </div>
      </div>

      <div
        class="flex max-w-full shrink-0 flex-wrap items-center gap-1.5 sm:justify-end"
      >
        <span
          :class="[
            'inline-flex items-center rounded-full border px-2 py-0.5 text-[10px] font-medium capitalize',
            priorityBadge
          ]"
        >
          {{ tweet.priority }}
        </span>
        <span
          :class="[
            'inline-flex items-center rounded-full border px-2 py-0.5 text-[10px] font-medium',
            statusBadge.class
          ]"
        >
          {{ statusBadge.label }}
        </span>
        <DropdownMenu>
          <DropdownMenuTrigger as-child>
            <Button
              variant="ghost"
              size="icon"
              class="h-7 w-7 rounded-md text-muted-foreground hover:text-foreground"
            >
              <MoreHorizontal class="h-4 w-4" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" class="w-48">
            <DropdownMenuItem @click="handleViewDetail">
              <Eye class="h-4 w-4" />
              {{ t('moderation.actions.viewDetail') }}
            </DropdownMenuItem>
            <DropdownMenuSeparator />
            <DropdownMenuItem @click="handleApprove">
              <CheckCircle class="h-4 w-4" />
              {{ t('moderation.actions.approveFull') }}
            </DropdownMenuItem>
            <DropdownMenuItem @click="handleReject">
              <XCircle class="h-4 w-4" />
              {{ t('moderation.actions.rejectPost') }}
            </DropdownMenuItem>
            <DropdownMenuItem
              class="text-amber-600 focus:text-amber-600 dark:text-amber-400 dark:focus:text-amber-400"
              @click="handleFlag"
            >
              <Flag class="h-4 w-4" />
              {{ t('moderation.actions.flag') }}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
    </div>

    <div class="p-4">
      <div class="grid gap-4 xl:grid-cols-[minmax(0,1fr)_18rem]">
        <div class="min-w-0 space-y-3">
          <p
            class="whitespace-pre-wrap text-sm leading-6 text-foreground"
          >
            {{ tweet.content }}
          </p>

          <div
            v-if="tweet.media && tweet.media.length > 0"
            class="flex max-w-[26rem] flex-wrap gap-1.5"
          >
            <div
              v-for="(media, index) in tweet.media.slice(0, 3)"
              :key="index"
              class="relative h-24 w-32 shrink-0 overflow-hidden rounded-md border border-border/60 bg-background"
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
                class="absolute inset-0 flex items-center justify-center bg-black/40"
              >
                <div
                  class="flex h-10 w-10 items-center justify-center rounded-full bg-white/90 backdrop-blur-sm"
                >
                  <Play class="h-4 w-4 fill-zinc-900 text-zinc-900" />
                </div>
              </div>
              <div
                v-if="index === 2 && tweet.media.length > 3"
                class="absolute inset-0 flex items-center justify-center bg-background/85 text-sm font-semibold"
              >
                +{{ tweet.media.length - 3 }}
              </div>
            </div>
          </div>
        </div>

        <div
          class="rounded-lg border border-rose-200/60 bg-rose-50/60 p-3 dark:border-rose-900/40 dark:bg-rose-950/30"
        >
          <div class="flex items-center gap-2">
            <AlertTriangle
              class="h-4 w-4 text-rose-600 dark:text-rose-400"
            />
            <span
              class="text-sm font-medium text-rose-700 dark:text-rose-300"
            >
              {{
                t('moderation.card.reportCount', {
                  count: tweet.reportCount
                })
              }}
            </span>
          </div>
          <div class="mt-2 flex flex-wrap gap-1">
            <span
              v-for="reason in tweet.reportReasons"
              :key="reason"
              class="inline-flex items-center rounded-full border border-rose-200/60 bg-white/60 px-1.5 py-0 text-[10px] font-medium text-rose-700 dark:border-rose-900/40 dark:bg-rose-950/40 dark:text-rose-300"
            >
              {{ getReasonLabel(reason) }}
            </span>
          </div>
          <div
            class="mt-3 space-y-1.5 border-t border-rose-200/40 pt-2.5 text-[11px] text-rose-700/80 dark:border-rose-900/30 dark:text-rose-300/80"
          >
            <div class="flex items-center gap-1.5">
              <Clock class="h-3 w-3" />
              <span>{{
                t('moderation.card.publishedAt', {
                  time: formatTime(tweet.createdAt)
                })
              }}</span>
            </div>
            <div class="flex items-center gap-1.5">
              <Flag class="h-3 w-3" />
              <span>{{
                t('moderation.card.reportedAt', {
                  time: formatTime(tweet.reportedAt)
                })
              }}</span>
            </div>
          </div>
        </div>
      </div>
    </div>

    <div
      class="flex flex-wrap items-center justify-between gap-3 border-t border-border/60 bg-muted/10 px-4 py-2.5"
    >
      <div
        class="flex items-center gap-4 text-xs text-muted-foreground"
      >
        <div class="flex items-center gap-1 tabular-nums">
          <Heart class="h-3.5 w-3.5" />
          <span>{{ tweet.likes }}</span>
        </div>
        <div class="flex items-center gap-1 tabular-nums">
          <Repeat class="h-3.5 w-3.5" />
          <span>{{ tweet.retweets }}</span>
        </div>
        <div class="flex items-center gap-1 tabular-nums">
          <MessageCircle class="h-3.5 w-3.5" />
          <span>{{ tweet.replies }}</span>
        </div>
      </div>

      <div class="flex flex-wrap items-center gap-1.5">
        <Button
          variant="outline"
          size="sm"
          class="h-8 rounded-md text-amber-600 shadow-xs hover:bg-amber-500/10 hover:text-amber-700 dark:text-amber-400 dark:hover:text-amber-300"
          @click="handleFlag"
        >
          <Flag class="h-3.5 w-3.5" />
          {{ t('moderation.actions.flag') }}
        </Button>
        <Button
          variant="outline"
          size="sm"
          class="h-8 rounded-md shadow-xs"
          @click="handleReject"
        >
          <XCircle class="h-3.5 w-3.5" />
          {{ t('moderation.actions.reject') }}
        </Button>
        <Button
          size="sm"
          class="h-8 rounded-md shadow-xs"
          @click="handleApprove"
        >
          <CheckCircle class="h-3.5 w-3.5" />
          {{ t('moderation.actions.approve') }}
        </Button>
      </div>
    </div>
  </div>
</template>
