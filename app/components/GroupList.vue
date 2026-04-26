<script setup lang="ts">
import { ref } from 'vue';
import { Inbox, RefreshCw, Plus } from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import GroupCard from './GroupCard.vue';
import type { Group } from './GroupCard.vue';

const props = defineProps<{
  groups: Group[];
  loading?: boolean;
  showCreateButton?: boolean;
}>();

const emit = defineEmits<{
  (e: 'join', id: number): void;
  (e: 'leave', id: number): void;
  (e: 'view-detail', group: Group): void;
  (e: 'settings', id: number): void;
  (e: 'refresh'): void;
  (e: 'load-more'): void;
  (e: 'create'): void;
}>();

const isRefreshing = ref(false);

// 处理刷新
const handleRefresh = async () => {
  isRefreshing.value = true;
  emit('refresh');
  setTimeout(() => {
    isRefreshing.value = false;
  }, 1000);
};

// 处理事件
const handleJoin = (id: number) => {
  emit('join', id);
};

const handleLeave = (id: number) => {
  emit('leave', id);
};

const handleViewDetail = (group: Group) => {
  emit('view-detail', group);
};

const handleSettings = (id: number) => {
  emit('settings', id);
};
</script>

<template>
  <div class="space-y-4">
    <!-- 列表头部 -->
    <div class="flex items-center justify-between">
      <div class="text-sm text-muted-foreground">
        共
        <span class="font-medium text-foreground">{{
          groups.length
        }}</span>
        个群组
      </div>
      <div class="flex items-center gap-2">
        <Button
          v-if="showCreateButton"
          @click="emit('create')"
        >
          <Plus class="h-4 w-4 mr-2" />
          创建群组
        </Button>
        <Button
          variant="outline"
          size="sm"
          :disabled="isRefreshing"
          @click="handleRefresh"
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
    </div>

    <!-- 加载状态 -->
    <div
      v-if="loading"
      class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"
    >
      <div v-for="i in 6" :key="i" class="animate-pulse">
        <div class="h-64 bg-muted rounded-lg" />
      </div>
    </div>

    <!-- 空状态 -->
    <div
      v-else-if="groups.length === 0"
      class="flex flex-col items-center justify-center py-16 text-center"
    >
      <div class="p-4 bg-muted rounded-full mb-4">
        <Inbox class="h-8 w-8 text-muted-foreground" />
      </div>
      <h3 class="text-lg font-medium mb-1">没有找到群组</h3>
      <p class="text-sm text-muted-foreground max-w-sm">
        尝试调整过滤条件或创建一个新的群组
      </p>
      <div class="flex gap-2 mt-4">
        <Button variant="outline" @click="handleRefresh">
          <RefreshCw class="h-4 w-4 mr-2" />
          刷新列表
        </Button>
        <Button
          v-if="showCreateButton"
          @click="emit('create')"
        >
          <Plus class="h-4 w-4 mr-2" />
          创建群组
        </Button>
      </div>
    </div>

    <!-- 群组网格 -->
    <div
      v-else
      class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"
    >
      <GroupCard
        v-for="group in groups"
        :key="group.id"
        :group="group"
        @join="handleJoin"
        @leave="handleLeave"
        @view-detail="handleViewDetail"
        @settings="handleSettings"
      />
    </div>

    <!-- 加载更多 -->
    <div
      v-if="groups.length > 0"
      class="flex justify-center pt-4"
    >
      <Button variant="outline" @click="emit('load-more')">
        加载更多
      </Button>
    </div>
  </div>
</template>
