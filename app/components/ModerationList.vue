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
}>();

const emit = defineEmits<{
  (e: 'approve', id: number): void;
  (e: 'reject', id: number): void;
  (e: 'flag', id: number): void;
  (e: 'view-detail', tweet: ModerationTweet): void;
  (e: 'refresh'): void;
  (e: 'load-more'): void;
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
      class="flex items-center justify-between gap-3 border-b border-border/60 bg-muted/20 px-4 py-3"
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
      <Button
        variant="outline"
        size="sm"
        class="h-8 rounded-md shadow-xs"
        :disabled="isRefreshing"
        @click="handleRefresh"
      >
        <RefreshCw
          :class="[
            'h-3.5 w-3.5',
            { 'animate-spin': isRefreshing }
          ]"
        />
        {{ t('moderation.actions.refresh') }}
      </Button>
    </div>

    <div v-if="loading" class="space-y-3 p-4">
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
        class="mt-4 h-8 rounded-md shadow-xs"
        @click="handleRefresh"
      >
        <RefreshCw class="h-3.5 w-3.5" />
        {{ t('moderation.actions.refreshList') }}
      </Button>
    </div>

    <ScrollArea
      v-else
      class="h-[calc(100dvh-24rem)] max-h-[46rem] min-h-[420px] w-full"
    >
      <div class="space-y-3 p-4">
        <ModerationCard
          v-for="tweet in tweets"
          :key="tweet.id"
          :tweet="tweet"
          @approve="handleApprove"
          @reject="handleReject"
          @flag="handleFlag"
          @view-detail="handleViewDetail"
        />

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
      </div>
    </ScrollArea>
  </div>
</template>
