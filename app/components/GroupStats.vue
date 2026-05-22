<script setup lang="ts">
import { computed } from 'vue';
import {
  Users,
  FileText,
  UserPlus,
  TrendingUp,
  Clock,
  MessageSquare
} from 'lucide-vue-next';
import type { GroupStatsData } from '@/types/groups';

export type { GroupStatsData } from '@/types/groups';

const props = withDefaults(
  defineProps<{
    stats: GroupStatsData;
  }>(),
  {
    stats: () => ({
      totalGroups: 0,
      myGroups: 0,
      pendingInvites: 0,
      todayPosts: 0,
      activeMembers: 0,
      newMembers: 0
    })
  }
);

const { t } = useAppLocale();

const statsCards = computed(() => [
  {
    title: t('groups.stats.totalGroups'),
    value: props.stats.totalGroups,
    icon: Users,
    accent: 'text-sky-600 dark:text-sky-400',
    bgAccent: 'bg-sky-500/10'
  },
  {
    title: t('groups.stats.myGroups'),
    value: props.stats.myGroups,
    icon: FileText,
    accent: 'text-emerald-600 dark:text-emerald-400',
    bgAccent: 'bg-emerald-500/10'
  },
  {
    title: t('groups.stats.pendingInvites'),
    value: props.stats.pendingInvites,
    icon: UserPlus,
    accent: 'text-amber-600 dark:text-amber-400',
    bgAccent: 'bg-amber-500/10'
  },
  {
    title: t('groups.stats.todayPosts'),
    value: props.stats.todayPosts,
    icon: MessageSquare,
    accent: 'text-violet-600 dark:text-violet-400',
    bgAccent: 'bg-violet-500/10'
  },
  {
    title: t('groups.stats.activeMembers'),
    value: props.stats.activeMembers,
    icon: TrendingUp,
    accent: 'text-orange-600 dark:text-orange-400',
    bgAccent: 'bg-orange-500/10'
  },
  {
    title: t('groups.stats.newMembers'),
    value: props.stats.newMembers,
    icon: Clock,
    accent: 'text-rose-600 dark:text-rose-400',
    bgAccent: 'bg-rose-500/10'
  }
]);
</script>

<template>
  <div class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
    <div
      v-for="stat in statsCards"
      :key="stat.title"
      class="group relative overflow-hidden rounded-xl border border-border/60 bg-card p-4 transition-all duration-200 hover:border-border hover:shadow-md"
    >
      <div class="flex items-start justify-between gap-2">
        <span class="min-w-0 text-xs font-medium text-muted-foreground">
          {{ stat.title }}
        </span>
        <div :class="[stat.bgAccent, 'flex h-7 w-7 shrink-0 items-center justify-center rounded-md']">
          <component
            :is="stat.icon"
            :class="['h-3.5 w-3.5', stat.accent]"
          />
        </div>
      </div>
      <div class="mt-2 tabular-nums text-2xl font-semibold tracking-tight">
        {{ stat.value.toLocaleString() }}
      </div>
    </div>
  </div>
</template>
