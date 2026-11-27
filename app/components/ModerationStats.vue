<script setup lang="ts">
import { computed } from 'vue';

export interface ModerationStatsData {
  pending: number;
  approved: number;
  rejected: number;
  flagged: number;
  todayProcessed: number;
  avgProcessTime: string;
  openReports?: number;
  appealSuccessRate?: number;
}

const props = withDefaults(
  defineProps<{
    stats: ModerationStatsData;
  }>(),
  {
    stats: () => ({
      pending: 0,
      approved: 0,
      rejected: 0,
      flagged: 0,
      todayProcessed: 0,
      avgProcessTime: '',
      openReports: 0,
      appealSuccessRate: 0
    })
  }
);

const { t } = useAppLocale();

const statsCards = computed(() => [
  {
    title: t('moderation.stats.pending'),
    value: props.stats.pending
  },
  {
    title: t('moderation.stats.approved'),
    value: props.stats.approved
  },
  {
    title: t('moderation.stats.rejected'),
    value: props.stats.rejected
  },
  {
    title: t('moderation.stats.flagged'),
    value: props.stats.flagged
  },
  {
    title: t('moderation.stats.todayProcessed'),
    value: props.stats.todayProcessed
  },
  {
    title: t('moderation.stats.avgProcessTime'),
    value:
      props.stats.avgProcessTime ||
      t('moderation.stats.zeroMinutes')
  },
  {
    title: t('moderation.stats.openReports'),
    value: props.stats.openReports ?? 0
  },
  {
    title: t('moderation.stats.appealSuccessRate'),
    value: `${props.stats.appealSuccessRate ?? 0}%`
  }
]);
</script>

<template>
  <dl class="grid grid-cols-2 gap-2.5 sm:grid-cols-4">
    <div
      v-for="stat in statsCards"
      :key="stat.title"
      class="min-w-0 rounded-2xl bg-card px-3.5 py-2.5"
    >
      <dt class="text-[11px] font-medium leading-tight text-muted-foreground">
        {{ stat.title }}
      </dt>
      <dd class="mt-0.5 min-w-0 wrap-anywhere text-lg leading-tight font-semibold tabular-nums">
        {{ typeof stat.value === 'number' ? stat.value.toLocaleString() : stat.value }}
      </dd>
    </div>
  </dl>
</template>
