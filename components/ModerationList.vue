<script setup lang="ts">
import { ref, computed } from 'vue';
import { Inbox, RefreshCw } from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import ModerationCard from './ModerationCard.vue';
import type { ModerationTweet } from './ModerationCard.vue';

const props = defineProps<{
  tweets: ModerationTweet[];
  loading?: boolean;
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
  <div class="space-y-4">
    <!-- 列表头部 -->
    <div class="flex items-center justify-between">
      <div class="text-sm text-muted-foreground">
        共
        <span class="font-medium text-foreground">{{
          tweets.length
        }}</span>
        条待审核内容
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
        刷新
      </Button>
    </div>

    <!-- 加载状态 -->
    <div v-if="loading" class="space-y-4">
      <div v-for="i in 3" :key="i" class="animate-pulse">
        <div class="h-48 bg-muted rounded-lg"></div>
      </div>
    </div>

    <!-- 空状态 -->
    <div
      v-else-if="tweets.length === 0"
      class="flex flex-col items-center justify-center py-16 text-center"
    >
      <div class="p-4 bg-muted rounded-full mb-4">
        <Inbox class="h-8 w-8 text-muted-foreground" />
      </div>
      <h3 class="text-lg font-medium mb-1">
        没有待审核的内容
      </h3>
      <p class="text-sm text-muted-foreground max-w-sm">
        当前没有需要审核的推文。新的举报内容将会显示在这里。
      </p>
      <Button
        variant="outline"
        class="mt-4"
        @click="handleRefresh"
      >
        <RefreshCw class="h-4 w-4 mr-2" />
        刷新列表
      </Button>
    </div>

    <!-- 推文列表 -->
    <div v-else class="space-y-4">
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
      <div class="flex justify-center pt-4">
        <Button
          variant="outline"
          @click="emit('load-more')"
        >
          加载更多
        </Button>
      </div>
    </div>
  </div>
</template>
