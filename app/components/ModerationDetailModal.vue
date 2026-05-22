<script setup lang="ts">
import { ref, computed, watch } from 'vue';
import {
  Heart,
  MessageCircle,
  Repeat,
  Flag,
  CheckCircle,
  XCircle,
  AlertTriangle,
  Calendar,
  Eye,
  ChevronLeft,
  ChevronRight,
  Sparkles
} from 'lucide-vue-next';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle
} from '@/components/ui/dialog';
import {
  Avatar,
  AvatarFallback,
  AvatarImage
} from '@/components/ui/avatar';
import { Button } from '@/components/ui/button';
import { ScrollArea } from '@/components/ui/scroll-area';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import type {
  ModerationReportReason,
  ModerationTweet
} from './ModerationCard.vue';

const props = defineProps<{
  open: boolean;
  tweet: ModerationTweet | null;
}>();

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void;
  (e: 'approve', id: number, note: string): void;
  (e: 'reject', id: number, note: string): void;
  (e: 'flag', id: number, note: string): void;
}>();

const { t, locale } = useAppLocale();

const moderationNote = ref('');
const selectedImageIndex = ref(0);

watch(
  () => props.open,
  isOpen => {
    if (!isOpen) {
      moderationNote.value = '';
      selectedImageIndex.value = 0;
    }
  }
);

const formatTime = (dateStr: string): string => {
  const date = new Date(dateStr);
  return date.toLocaleString(locale.value, {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit'
  });
};

const statusBadge = computed(() => {
  const status = props.tweet?.status;
  switch (status) {
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

const reportReasonDetails: Record<
  ModerationReportReason,
  { titleKey: string; descriptionKey: string }
> = {
  spam: {
    titleKey: 'moderation.reportDetails.spam.title',
    descriptionKey: 'moderation.reportDetails.spam.description'
  },
  harassment: {
    titleKey: 'moderation.reportDetails.harassment.title',
    descriptionKey: 'moderation.reportDetails.harassment.description'
  },
  hate: {
    titleKey: 'moderation.reportDetails.hate.title',
    descriptionKey: 'moderation.reportDetails.hate.description'
  },
  violence: {
    titleKey: 'moderation.reportDetails.violence.title',
    descriptionKey: 'moderation.reportDetails.violence.description'
  },
  adult: {
    titleKey: 'moderation.reportDetails.adult.title',
    descriptionKey: 'moderation.reportDetails.adult.description'
  },
  misinformation: {
    titleKey: 'moderation.reportDetails.misinformation.title',
    descriptionKey:
      'moderation.reportDetails.misinformation.description'
  },
  copyright: {
    titleKey: 'moderation.reportDetails.copyright.title',
    descriptionKey: 'moderation.reportDetails.copyright.description'
  },
  other: {
    titleKey: 'moderation.reportDetails.other.title',
    descriptionKey: 'moderation.reportDetails.other.description'
  }
};

const getReportReasonTitle = (
  reason: ModerationReportReason
): string => t(reportReasonDetails[reason].titleKey);

const getReportReasonDescription = (
  reason: ModerationReportReason
): string => t(reportReasonDetails[reason].descriptionKey);

const selectedMedia = computed(
  () => props.tweet?.media?.[selectedImageIndex.value] ?? null
);

const prevImage = () => {
  if (props.tweet?.media && selectedImageIndex.value > 0) {
    selectedImageIndex.value--;
  }
};

const nextImage = () => {
  if (
    props.tweet?.media &&
    selectedImageIndex.value < props.tweet.media.length - 1
  ) {
    selectedImageIndex.value++;
  }
};

const handleApprove = () => {
  if (props.tweet) {
    emit('approve', props.tweet.id, moderationNote.value);
    emit('update:open', false);
  }
};

const handleReject = () => {
  if (props.tweet) {
    emit('reject', props.tweet.id, moderationNote.value);
    emit('update:open', false);
  }
};

const handleFlag = () => {
  if (props.tweet) {
    emit('flag', props.tweet.id, moderationNote.value);
    emit('update:open', false);
  }
};

const closeDialog = () => {
  emit('update:open', false);
};
</script>

<template>
  <Dialog :open="open" @update:open="closeDialog">
    <DialogContent
      class="grid max-h-[calc(100dvh-1rem)] max-w-5xl grid-rows-[auto_minmax(0,1fr)_auto] gap-0 overflow-hidden p-0"
    >
      <DialogHeader
        class="border-b border-border/60 bg-background/60 px-5 py-3 backdrop-blur sm:px-6"
      >
        <DialogTitle class="flex items-center gap-2 text-base tracking-tight">
          <Eye class="h-4 w-4" />
          {{ t('moderation.detail.title') }}
        </DialogTitle>
        <DialogDescription class="text-xs">
          {{ t('moderation.detail.description') }}
        </DialogDescription>
      </DialogHeader>

      <ScrollArea v-if="tweet" class="min-h-0">
        <div class="space-y-5 px-5 py-5 sm:px-6">
          <div
            class="flex items-start gap-3 rounded-xl border border-border/60 bg-muted/30 p-3 sm:gap-4 sm:p-4"
          >
            <Avatar
              class="h-12 w-12 shrink-0 ring-1 ring-border sm:h-14 sm:w-14"
            >
              <AvatarImage
                :src="tweet.author.avatar"
                :alt="tweet.author.nickname"
              />
              <AvatarFallback class="text-sm">{{
                tweet.author.nickname.charAt(0).toUpperCase()
              }}</AvatarFallback>
            </Avatar>
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-1.5">
                <span class="text-sm font-semibold">{{
                  tweet.author.nickname
                }}</span>
                <Sparkles
                  v-if="tweet.author.isVerified"
                  class="h-3.5 w-3.5 text-sky-500"
                />
                <span
                  :class="[
                    'inline-flex items-center rounded-full border px-2 py-0.5 text-[10px] font-medium',
                    statusBadge.class
                  ]"
                >
                  {{ statusBadge.label }}
                </span>
              </div>
              <span class="text-xs text-muted-foreground">
                @{{ tweet.author.username }}
              </span>
              <div
                class="mt-2 flex flex-wrap items-center gap-3 text-[11px] text-muted-foreground"
              >
                <div class="flex items-center gap-1">
                  <Calendar class="h-3 w-3" />
                  <span>{{
                    t('moderation.detail.publishedAt', {
                      time: formatTime(tweet.createdAt)
                    })
                  }}</span>
                </div>
                <div class="flex items-center gap-1">
                  <Flag class="h-3 w-3" />
                  <span>{{
                    t('moderation.detail.reportedAt', {
                      time: formatTime(tweet.reportedAt)
                    })
                  }}</span>
                </div>
              </div>
            </div>
          </div>

          <div>
            <h4
              class="mb-2 text-xs font-semibold uppercase tracking-wider text-muted-foreground"
            >
              {{ t('moderation.detail.postContent') }}
            </h4>
            <div
              class="rounded-xl border border-border/60 bg-card p-4"
            >
              <p
                class="whitespace-pre-wrap break-words text-sm leading-6 text-foreground"
              >
                {{ tweet.content }}
              </p>
            </div>
          </div>

          <div v-if="tweet.media && tweet.media.length > 0">
            <h4
              class="mb-2 text-xs font-semibold uppercase tracking-wider text-muted-foreground"
            >
              {{
                t('moderation.detail.mediaContent', {
                  current: selectedImageIndex + 1,
                  total: tweet.media.length
                })
              }}
            </h4>
            <div class="relative">
              <div
                class="aspect-video overflow-hidden rounded-xl border border-border/60 bg-muted/40"
              >
                <img
                  v-if="selectedMedia"
                  :src="selectedMedia.url"
                  :alt="t('moderation.detail.mediaAlt')"
                  class="h-full w-full object-contain"
                />
              </div>

              <div
                v-if="tweet.media.length > 1"
                class="pointer-events-none absolute inset-y-0 left-0 right-0 flex items-center justify-between px-2"
              >
                <Button
                  variant="secondary"
                  size="icon"
                  class="pointer-events-auto h-8 w-8 rounded-full shadow-md"
                  :disabled="selectedImageIndex === 0"
                  @click="prevImage"
                >
                  <ChevronLeft class="h-4 w-4" />
                </Button>
                <Button
                  variant="secondary"
                  size="icon"
                  class="pointer-events-auto h-8 w-8 rounded-full shadow-md"
                  :disabled="
                    selectedImageIndex ===
                    tweet.media.length - 1
                  "
                  @click="nextImage"
                >
                  <ChevronRight class="h-4 w-4" />
                </Button>
              </div>

              <div
                v-if="tweet.media.length > 1"
                class="mt-2 flex justify-center gap-1.5 overflow-x-auto pb-1"
              >
                <button
                  v-for="(media, index) in tweet.media"
                  :key="index"
                  type="button"
                  class="h-12 w-16 shrink-0 overflow-hidden rounded-md border-2 transition-colors"
                  :class="
                    selectedImageIndex === index
                      ? 'border-primary'
                      : 'border-border/60 opacity-60 hover:opacity-100'
                  "
                  @click="selectedImageIndex = index"
                >
                  <img
                    :src="media.thumbnail || media.url"
                    alt=""
                    class="h-full w-full object-cover"
                  />
                </button>
              </div>
            </div>
          </div>

          <div>
            <h4
              class="mb-2 flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wider text-muted-foreground"
            >
              <AlertTriangle
                class="h-3 w-3 text-rose-500"
              />
              {{
                t('moderation.detail.reportInfo', {
                  count: tweet.reportCount
                })
              }}
            </h4>
            <div class="space-y-2">
              <div
                v-for="reason in tweet.reportReasons"
                :key="reason"
                class="rounded-lg border border-rose-200/60 bg-rose-50/60 p-3 dark:border-rose-900/40 dark:bg-rose-950/30"
              >
                <div
                  class="text-sm font-medium text-rose-800 dark:text-rose-200"
                >
                  {{ getReportReasonTitle(reason) }}
                </div>
                <div
                  class="mt-1 text-xs text-rose-700/80 dark:text-rose-300/80"
                >
                  {{ getReportReasonDescription(reason) }}
                </div>
              </div>
            </div>
          </div>

          <div>
            <h4
              class="mb-2 text-xs font-semibold uppercase tracking-wider text-muted-foreground"
            >
              {{ t('moderation.detail.engagement') }}
            </h4>
            <div
              class="grid grid-cols-3 gap-3 rounded-xl border border-border/60 bg-card p-4"
            >
              <div class="flex flex-col items-center gap-1">
                <div
                  class="flex h-9 w-9 items-center justify-center rounded-full bg-rose-500/10"
                >
                  <Heart class="h-4 w-4 text-rose-500" />
                </div>
                <span class="text-base font-semibold tabular-nums">
                  {{ tweet.likes }}
                </span>
                <span class="text-xs text-muted-foreground">
                  {{ t('moderation.detail.likes') }}
                </span>
              </div>
              <div class="flex flex-col items-center gap-1">
                <div
                  class="flex h-9 w-9 items-center justify-center rounded-full bg-emerald-500/10"
                >
                  <Repeat class="h-4 w-4 text-emerald-500" />
                </div>
                <span class="text-base font-semibold tabular-nums">
                  {{ tweet.retweets }}
                </span>
                <span class="text-xs text-muted-foreground">
                  {{ t('moderation.detail.retweets') }}
                </span>
              </div>
              <div class="flex flex-col items-center gap-1">
                <div
                  class="flex h-9 w-9 items-center justify-center rounded-full bg-sky-500/10"
                >
                  <MessageCircle class="h-4 w-4 text-sky-500" />
                </div>
                <span class="text-base font-semibold tabular-nums">
                  {{ tweet.replies }}
                </span>
                <span class="text-xs text-muted-foreground">
                  {{ t('moderation.detail.replies') }}
                </span>
              </div>
            </div>
          </div>

          <div>
            <Label
              for="moderation-note"
              class="text-xs font-semibold uppercase tracking-wider text-muted-foreground"
            >
              {{ t('moderation.detail.note') }}
            </Label>
            <Textarea
              id="moderation-note"
              v-model="moderationNote"
              :placeholder="t('moderation.detail.notePlaceholder')"
              class="mt-2 min-h-[88px] resize-none shadow-xs"
              rows="3"
            />
          </div>
        </div>
      </ScrollArea>

      <DialogFooter
        class="flex flex-col-reverse gap-2 border-t border-border/60 bg-background/60 px-5 py-3 backdrop-blur sm:flex-row sm:justify-end sm:px-6"
      >
        <Button
          variant="ghost"
          size="sm"
          class="h-9 rounded-md"
          @click="closeDialog"
        >
          {{ t('common.cancel') }}
        </Button>
        <Button
          variant="outline"
          size="sm"
          class="h-9 rounded-md text-amber-600 shadow-xs hover:bg-amber-500/10 hover:text-amber-700 dark:text-amber-400 dark:hover:text-amber-300"
          @click="handleFlag"
        >
          <Flag class="h-4 w-4" />
          {{ t('moderation.actions.flag') }}
        </Button>
        <Button
          variant="outline"
          size="sm"
          class="h-9 rounded-md shadow-xs"
          @click="handleReject"
        >
          <XCircle class="h-4 w-4" />
          {{ t('moderation.actions.reject') }}
        </Button>
        <Button
          size="sm"
          class="h-9 rounded-md shadow-xs"
          @click="handleApprove"
        >
          <CheckCircle class="h-4 w-4" />
          {{ t('moderation.actions.approve') }}
        </Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>
</template>
