<script setup lang="ts">
import { computed } from 'vue';
import {
  Heart,
  MessageCircle,
  Repeat,
  MoreHorizontal,
  Flag,
  Check,
  X,
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
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger
} from '@/components/ui/tooltip';
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
          'bg-amber-500/10 text-amber-700 dark:text-amber-300'
      };
    case 'approved':
      return {
        label: t('moderation.status.approved'),
        class:
          'bg-emerald-500/10 text-emerald-700 dark:text-emerald-300'
      };
    case 'rejected':
      return {
        label: t('moderation.status.rejected'),
        class:
          'bg-secondary text-muted-foreground'
      };
    case 'flagged':
      return {
        label: t('moderation.status.flagged'),
        class:
          'bg-orange-500/10 text-orange-700 dark:text-orange-300'
      };
    case 'removed':
      return {
        label: t('moderation.status.removed'),
        class:
          'bg-rose-500/10 text-rose-700 dark:text-rose-300'
      };
    case 'restored':
      return {
        label: t('moderation.status.restored'),
        class:
          'bg-sky-500/10 text-sky-700 dark:text-sky-300'
      };
    default:
      return {
        label: t('moderation.status.unknown'),
        class:
          'bg-secondary text-muted-foreground'
      };
  }
});

const priorityBadge = computed(() => {
  const priority = props.tweet.priority?.toLowerCase();
  if (priority === 'urgent' || priority === 'high') {
    return 'bg-rose-500/10 text-rose-700 dark:text-rose-300';
  }
  if (priority === 'medium') {
    return 'bg-amber-500/10 text-amber-700 dark:text-amber-300';
  }
  return 'bg-secondary text-muted-foreground';
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

const reviewActions = [
  { label: 'moderation.actions.flag', icon: Flag, run: handleFlag },
  { label: 'moderation.actions.reject', icon: X, run: handleReject },
  { label: 'moderation.actions.approve', icon: Check, run: handleApprove }
];
</script>

<template>
  <div
    class="overflow-hidden rounded-[20px] bg-card shadow-[0_1px_3px_rgba(15,23,42,0.03)] dark:shadow-none"
  >
    <div
      class="flex flex-col items-start justify-between gap-3 px-4 pt-4 pb-2 sm:flex-row sm:items-center"
    >
      <div class="flex min-w-0 items-center gap-3">
        <Avatar class="h-10 w-10 shrink-0">
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
            'inline-flex items-center rounded-full px-2.5 py-0.5 text-[11px] font-medium capitalize',
            priorityBadge
          ]"
        >
          {{ tweet.priority }}
        </span>
        <span
          :class="[
            'inline-flex items-center rounded-full px-2.5 py-0.5 text-[11px] font-medium',
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
              class="size-8 text-muted-foreground hover:text-foreground"
              :aria-label="t('common.more')"
            >
              <MoreHorizontal class="h-4 w-4" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" class="w-48">
            <DropdownMenuItem @click="handleViewDetail">
              {{ t('moderation.actions.viewDetail') }}
            </DropdownMenuItem>
            <DropdownMenuSeparator />
            <DropdownMenuItem @click="handleApprove">
              {{ t('moderation.actions.approveFull') }}
            </DropdownMenuItem>
            <DropdownMenuItem @click="handleReject">
              {{ t('moderation.actions.rejectPost') }}
            </DropdownMenuItem>
            <DropdownMenuItem @click="handleFlag">
              {{ t('moderation.actions.flag') }}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
    </div>

    <div class="px-4 py-2">
      <div class="grid items-start gap-2.5">
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
              class="relative h-24 w-32 shrink-0 overflow-hidden rounded-xl bg-secondary"
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

          <p v-if="tweet.sentimentSignal" class="text-xs text-muted-foreground">
            {{ t('moderation.card.sentimentSignal', {
              label: t(`moderation.card.sentimentLabels.${tweet.sentimentSignal.label}`),
              confidence: Math.round(tweet.sentimentSignal.confidence * 100),
            }) }}
          </p>
        </div>

        <div class="flex flex-wrap items-center gap-x-2.5 gap-y-1.5 rounded-xl bg-secondary/70 px-3 py-2">
          <span class="rounded-full bg-rose-500/12 px-2 py-0.5 text-xs font-semibold text-rose-600 dark:text-rose-300">
            {{ t('moderation.card.reportCount', { count: tweet.reportCount }) }}
          </span>
          <div v-if="tweet.reportReasons.length" class="flex flex-wrap gap-1.5">
            <span
              v-for="reason in tweet.reportReasons"
              :key="reason"
              class="inline-flex items-center rounded-full bg-secondary px-2 py-0.5 text-xs font-medium text-foreground"
            >
              {{ getReasonLabel(reason) }}
            </span>
          </div>
          <div class="flex flex-wrap gap-x-3 gap-y-1 text-[11px] text-muted-foreground sm:ml-auto">
            <span>{{
                t('moderation.card.publishedAt', {
                  time: formatTime(tweet.createdAt)
                })
            }}</span>
            <span>{{
                t('moderation.card.reportedAt', {
                  time: formatTime(tweet.reportedAt)
                })
            }}</span>
          </div>
        </div>
      </div>
    </div>

    <div
      class="flex flex-wrap items-center justify-between gap-3 px-4 pb-3 pt-1"
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

      <div class="ml-auto flex items-center gap-0.5 rounded-full bg-secondary/70 p-0.5">
        <TooltipProvider :delay-duration="250">
          <Tooltip v-for="action in reviewActions" :key="action.label">
            <TooltipTrigger as-child>
              <Button
                type="button"
                variant="ghost"
                size="icon"
                class="text-muted-foreground hover:text-foreground focus-visible:text-foreground"
                :aria-label="t(action.label)"
                @click="action.run"
              >
                <component :is="action.icon" class="size-4" :stroke-width="1.75" aria-hidden="true" />
              </Button>
            </TooltipTrigger>
            <TooltipContent class="rounded-lg bg-popover text-popover-foreground shadow-sm [&_svg]:hidden">
              {{ t(action.label) }}
            </TooltipContent>
          </Tooltip>
        </TooltipProvider>
      </div>
    </div>
  </div>
</template>
