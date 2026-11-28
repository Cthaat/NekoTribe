<script setup lang="ts">
import { ref } from 'vue';
import { Inbox, RefreshCw } from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import { ScrollArea } from '@/components/ui/scroll-area';
import { Skeleton } from '@/components/ui/skeleton';
import ModerationCard from './ModerationCard.vue';
import type { ModerationTweet } from './ModerationCard.vue';

const props = defineProps<{
  tweets: ModerationTweet[];
  loading?: boolean;
  hasNext?: boolean;
  selectedIds?: ReadonlySet<number>;
  selectionDisabled?: boolean;
  reviewerId?: number;
}>();

const emit = defineEmits<{
  (e: 'approve', id: number): void;
  (e: 'reject', id: number): void;
  (e: 'flag', id: number): void;
  (e: 'view-detail', tweet: ModerationTweet): void;
  (e: 'refresh'): void;
  (e: 'load-more'): void;
  (e: 'toggle-selection', id: number): void;
  (e: 'assignment', id: number, action: 'claim' | 'release'): void;
}>();

const isRefreshing = ref(false);
const { t } = useAppLocale();

const handleRefresh = async () => {
  isRefreshing.value = true;
  emit('refresh');
  setTimeout(() => {
    isRefreshing.value = false;
  }, 1000);
};

const handleApprove = (id: number) => emit('approve', id);
const handleReject = (id: number) => emit('reject', id);
const handleFlag = (id: number) => emit('flag', id);
const handleViewDetail = (tweet: ModerationTweet) =>
  emit('view-detail', tweet);
</script>

<template>
  <div class="rounded-xl border border-border/60 bg-card shadow-none">
    <div
      class="flex flex-col items-start justify-between gap-3 border-b border-border/60 bg-muted/20 px-4 py-3 sm:flex-row sm:items-center"
    >
      <div class="min-w-0">
        <p class="text-sm font-semibold tracking-tight">
          {{ t('moderation.tabs.content') }}
        </p>
        <p class="text-xs text-muted-foreground">
          {{
            t('moderation.list.count', {
              count: tweets.length
            })
          }}
        </p>
      </div>
      <slot name="selection-actions" />
      <Button
        variant="ghost"
        size="icon"
        class="size-9 bg-secondary/70"
        :aria-label="t('moderation.actions.refresh')"
        :title="t('moderation.actions.refresh')"
        :disabled="isRefreshing"
        @click="handleRefresh"
      >
        <RefreshCw
          :class="[
            'h-3.5 w-3.5',
            { 'animate-spin': isRefreshing }
          ]"
        />
      </Button>
    </div>

    <div v-if="loading && !tweets.length" class="space-y-3 p-4">
      <Skeleton
        v-for="i in 3"
        :key="i"
        class="h-44 rounded-xl"
      />
    </div>

    <div
      v-else-if="tweets.length === 0"
      class="flex flex-col items-center justify-center px-6 py-16 text-center"
    >
      <div
        class="mb-3 flex h-14 w-14 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
      >
        <Inbox class="h-6 w-6 text-muted-foreground" />
      </div>
      <h3 class="text-base font-semibold tracking-tight">
        {{ t('moderation.list.emptyTitle') }}
      </h3>
      <p class="mt-1 max-w-sm text-sm text-muted-foreground">
        {{ t('moderation.list.emptyDescription') }}
      </p>
      <Button
        variant="outline"
        size="sm"
        class="mt-4 rounded-full"
        @click="handleRefresh"
      >
        {{ t('moderation.actions.refreshList') }}
      </Button>
    </div>

    <ScrollArea
      v-else
      class="h-[max(420px,calc(100dvh-24rem))] max-h-[46rem] w-full max-sm:h-[calc(100dvh-18rem)] max-sm:min-h-[360px]"
    >
      <TransitionGroup name="w3-list" tag="div" class="relative mx-4 space-y-3 py-4">
        <div v-for="tweet in tweets" :key="tweet.id" class="grid gap-1">
          <label v-if="selectedIds" class="flex items-center gap-2 text-sm">
            <input type="checkbox" :checked="selectedIds.has(tweet.id)"
              :disabled="selectionDisabled || (selectedIds.size >= 100 && !selectedIds.has(tweet.id))"
              @change="emit('toggle-selection', tweet.id)" />
            {{ t('moderation.bulk.selectPost', { id: tweet.id }) }}
          </label>
          <ModerationCard :tweet="tweet" @approve="handleApprove" @reject="handleReject" @flag="handleFlag" @view-detail="handleViewDetail" />
          <div class="flex flex-wrap items-center gap-2 text-sm text-muted-foreground">
            <span>{{ tweet.assignedTo ? t('moderation.assignment.owner', { name: tweet.assignedTo.name }) : t('moderation.assignment.unassigned') }}</span>
            <template v-if="reviewerId && (tweet.status === 'pending' || tweet.status === 'flagged')">
              <Button v-if="!tweet.assignedTo" size="sm" variant="outline" :disabled="selectionDisabled" @click="emit('assignment', tweet.id, 'claim')">
                {{ t('moderation.assignment.claim') }}
              </Button>
              <Button v-else-if="tweet.assignedTo.id === reviewerId" size="sm" variant="outline" :disabled="selectionDisabled" @click="emit('assignment', tweet.id, 'release')">
                {{ t('moderation.assignment.release') }}
              </Button>
            </template>
          </div>
        </div>

      </TransitionGroup>
        <div v-if="hasNext" class="flex justify-center pt-2">
          <Button
            variant="outline"
            size="sm"
            class="h-8 rounded-md shadow-xs"
            @click="emit('load-more')"
          >
            {{ t('moderation.actions.loadMore') }}
          </Button>
        </div>
    </ScrollArea>
  </div>
</template>
