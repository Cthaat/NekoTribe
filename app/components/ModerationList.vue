<script setup lang="ts">
import { ref } from 'vue';
import { Inbox, RefreshCw } from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import { ScrollArea } from '@/components/ui/scroll-area';
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

// 处理刷新
const handleRefresh = async () => {
  isRefreshing.value = true;
  emit('refresh');
  // 模拟刷新延迟
  setTimeout(() => {
    isRefreshing.value = false;
  }, 1000);
};

// 处理操作事件
const handleApprove = (id: number) => {
  emit('approve', id);
};

const handleReject = (id: number) => {
  emit('reject', id);
};

const handleFlag = (id: number) => {
  emit('flag', id);
};

const handleViewDetail = (tweet: ModerationTweet) => {
  emit('view-detail', tweet);
};
</script>

<template>
  <div
    class="rounded-lg border bg-card/70 p-4 shadow-sm"
  >
    <!-- 列表头部 -->
    <div class="mb-4 flex items-center justify-between gap-3">
      <div>
        <div class="text-sm font-medium">
          {{ t('moderation.tabs.content') }}
        </div>
        <div class="text-xs text-muted-foreground">
          {{
            t('moderation.list.count', {
              count: tweets.length
            })
          }}
        </div>
      </div>
      <Button
        variant="outline"
        size="sm"
        @click="handleRefresh"
        :disabled="isRefreshing"
      >
        <RefreshCw
          :class="[
            'h-4 w-4 mr-2',
            { 'animate-spin': isRefreshing }
          ]"
        />
        {{ t('moderation.actions.refresh') }}
      </Button>
    </div>

    <!-- 加载状态 -->
    <div v-if="loading" class="space-y-3">
      <div v-for="i in 3" :key="i" class="animate-pulse">
        <div class="h-44 rounded-lg bg-muted"></div>
      </div>
    </div>

    <!-- 空状态 -->
    <div
      v-else-if="tweets.length === 0"
      class="flex flex-col items-center justify-center rounded-lg border border-dashed bg-muted/20 py-16 text-center"
    >
      <div class="p-4 bg-muted rounded-full mb-4">
        <Inbox class="h-8 w-8 text-muted-foreground" />
      </div>
      <h3 class="text-lg font-medium mb-1">
        {{ t('moderation.list.emptyTitle') }}
      </h3>
      <p class="text-sm text-muted-foreground max-w-sm">
        {{ t('moderation.list.emptyDescription') }}
      </p>
      <Button
        variant="outline"
        class="mt-4"
        @click="handleRefresh"
      >
        <RefreshCw class="h-4 w-4 mr-2" />
        {{ t('moderation.actions.refreshList') }}
      </Button>
    </div>

    <!-- 推文列表 -->
    <ScrollArea
      v-else
      class="max-h-[calc(100dvh-24rem)] min-h-[420px] pr-3"
    >
      <div class="space-y-3">
        <ModerationCard
          v-for="tweet in tweets"
          :key="tweet.id"
          :tweet="tweet"
          @approve="handleApprove"
          @reject="handleReject"
          @flag="handleFlag"
          @view-detail="handleViewDetail"
        />

        <!-- 加载更多 -->
        <div v-if="hasNext" class="flex justify-center pt-3">
          <Button
            variant="outline"
            @click="emit('load-more')"
          >
            {{ t('moderation.actions.loadMore') }}
          </Button>
        </div>
      </div>
    </ScrollArea>
  </div>
</template>
