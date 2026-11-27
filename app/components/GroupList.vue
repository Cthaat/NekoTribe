<script setup lang="ts">
import { ref } from 'vue';
import { RefreshCw } from 'lucide-vue-next';
import AppEmptyState from '@/components/app/AppEmptyState.vue';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import GroupCard from './GroupCard.vue';
import type { Group } from './GroupCard.vue';

defineProps<{
  groups: Group[];
  loading?: boolean;
  showCreateButton?: boolean;
  hasNext?: boolean;
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
const { t } = useAppLocale();

const handleRefresh = async () => {
  isRefreshing.value = true;
  emit('refresh');
  setTimeout(() => {
    isRefreshing.value = false;
  }, 1000);
};

const handleJoin = (id: number) => emit('join', id);
const handleLeave = (id: number) => emit('leave', id);
const handleViewDetail = (group: Group) => emit('view-detail', group);
const handleSettings = (id: number) => emit('settings', id);
</script>

<template>
  <div class="space-y-4">
    <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
      <div class="text-sm text-muted-foreground">
        <span class="tabular-nums font-medium text-foreground">
          {{ t('groups.list.count', { count: groups.length }) }}
        </span>
      </div>
      <div class="flex items-center gap-2">
        <Button
          variant="secondary"
          size="icon"
          class="size-9"
          :aria-label="t('common.refresh')"
          :title="t('common.refresh')"
          :disabled="isRefreshing"
          @click="handleRefresh"
        >
          <RefreshCw
            :class="['h-4 w-4', { 'animate-spin': isRefreshing }]"
          />
        </Button>
        <Button
          v-if="showCreateButton"
            class="rounded-full px-4 font-semibold"
          @click="emit('create')"
        >
          {{ t('groups.actions.create') }}
        </Button>
      </div>
    </div>

    <div
      v-if="loading"
      class="grid grid-cols-1 gap-3.5 md:grid-cols-2 lg:grid-cols-3"
    >
      <Skeleton
        v-for="i in 6"
        :key="i"
        class="h-64 rounded-[20px]"
      />
    </div>

    <AppEmptyState
      v-else-if="groups.length === 0"
      :title="t('groups.empty.title')"
      :description="t('groups.empty.description')"
      class="max-w-none py-16"
    >
      <div class="flex flex-col gap-2 sm:flex-row">
        <Button variant="ghost" size="sm" class="rounded-full bg-secondary" @click="handleRefresh">
          {{ t('groups.actions.refreshList') }}
        </Button>
        <Button
          v-if="showCreateButton"
          size="sm"
          class="rounded-full font-semibold"
          @click="emit('create')"
        >
          {{ t('groups.actions.create') }}
        </Button>
      </div>
    </AppEmptyState>

    <div
      v-else
      class="grid grid-cols-1 gap-3.5 md:grid-cols-2 lg:grid-cols-3"
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

    <div
      v-if="groups.length > 0 && hasNext !== false"
      class="flex justify-center pt-2"
    >
      <Button variant="ghost" size="sm" class="rounded-full bg-card px-5 shadow-[0_1px_3px_rgba(15,23,42,0.03)] dark:shadow-none" @click="emit('load-more')">
        {{ t('common.loadMore') }}
      </Button>
    </div>
  </div>
</template>
