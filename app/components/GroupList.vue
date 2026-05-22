<script setup lang="ts">
import { ref } from 'vue';
import { Inbox, RefreshCw, Plus } from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import GroupCard from './GroupCard.vue';
import type { Group } from './GroupCard.vue';

defineProps<{
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
          {{ groups.length }}
        </span>
        <span class="ml-1">
          {{ t('groups.list.count', { count: groups.length }) }}
        </span>
      </div>
      <div class="flex flex-col gap-2 sm:flex-row sm:items-center">
        <Button
          variant="outline"
          size="sm"
          class="w-full sm:w-auto"
          :disabled="isRefreshing"
          @click="handleRefresh"
        >
          <RefreshCw
            :class="['h-4 w-4', { 'animate-spin': isRefreshing }]"
          />
          {{ t('common.refresh') }}
        </Button>
        <Button
          v-if="showCreateButton"
          size="sm"
          class="w-full sm:w-auto"
          @click="emit('create')"
        >
          <Plus class="h-4 w-4" />
          {{ t('groups.actions.create') }}
        </Button>
      </div>
    </div>

    <div
      v-if="loading"
      class="grid grid-cols-1 gap-4 md:grid-cols-2 lg:grid-cols-3"
    >
      <Skeleton
        v-for="i in 6"
        :key="i"
        class="h-64 rounded-xl"
      />
    </div>

    <div
      v-else-if="groups.length === 0"
      class="flex flex-col items-center justify-center rounded-xl border border-dashed border-border/60 bg-muted/10 px-6 py-16 text-center"
    >
      <div
        class="mb-4 flex h-12 w-12 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
      >
        <Inbox class="h-5 w-5 text-muted-foreground" />
      </div>
      <h3 class="text-base font-semibold tracking-tight">
        {{ t('groups.empty.title') }}
      </h3>
      <p class="mt-1.5 max-w-sm text-sm leading-relaxed text-muted-foreground">
        {{ t('groups.empty.description') }}
      </p>
      <div class="mt-5 flex flex-col gap-2 sm:flex-row">
        <Button variant="outline" size="sm" @click="handleRefresh">
          <RefreshCw class="h-4 w-4" />
          {{ t('groups.actions.refreshList') }}
        </Button>
        <Button
          v-if="showCreateButton"
          size="sm"
          @click="emit('create')"
        >
          <Plus class="h-4 w-4" />
          {{ t('groups.actions.create') }}
        </Button>
      </div>
    </div>

    <div
      v-else
      class="grid grid-cols-1 gap-4 md:grid-cols-2 lg:grid-cols-3"
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
      v-if="groups.length > 0"
      class="flex justify-center pt-2"
    >
      <Button variant="outline" size="sm" @click="emit('load-more')">
        {{ t('common.loadMore') }}
      </Button>
    </div>
  </div>
</template>
