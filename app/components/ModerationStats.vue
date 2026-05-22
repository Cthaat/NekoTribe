<script setup lang="ts">
import { computed } from 'vue';
import {
  Clock,
  CheckCircle,
  XCircle,
  Flag,
  TrendingUp,
  AlertTriangle,
  Gauge,
  ShieldCheck
} from 'lucide-vue-next';

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
    value: props.stats.pending,
    icon: Clock,
    tone: 'amber'
  },
  {
    title: t('moderation.stats.approved'),
    value: props.stats.approved,
    icon: CheckCircle,
    tone: 'emerald'
  },
  {
    title: t('moderation.stats.rejected'),
    value: props.stats.rejected,
    icon: XCircle,
    tone: 'rose'
  },
  {
    title: t('moderation.stats.flagged'),
    value: props.stats.flagged,
    icon: Flag,
    tone: 'orange'
  },
  {
    title: t('moderation.stats.todayProcessed'),
    value: props.stats.todayProcessed,
    icon: TrendingUp,
    tone: 'sky'
  },
  {
    title: t('moderation.stats.avgProcessTime'),
    value:
      props.stats.avgProcessTime ||
      t('moderation.stats.zeroMinutes'),
    icon: Gauge,
    tone: 'violet',
    isText: true
  },
  {
    title: t('moderation.stats.openReports'),
    value: props.stats.openReports ?? 0,
    icon: AlertTriangle,
    tone: 'red'
  },
  {
    title: t('moderation.stats.appealSuccessRate'),
    value: `${props.stats.appealSuccessRate ?? 0}%`,
    icon: ShieldCheck,
    tone: 'cyan',
    isText: true
  }
]);

const toneClasses: Record<string, string> = {
  amber: 'bg-amber-500/10 text-amber-600 dark:text-amber-400',
  emerald: 'bg-emerald-500/10 text-emerald-600 dark:text-emerald-400',
  rose: 'bg-rose-500/10 text-rose-600 dark:text-rose-400',
  orange: 'bg-orange-500/10 text-orange-600 dark:text-orange-400',
  sky: 'bg-sky-500/10 text-sky-600 dark:text-sky-400',
  violet: 'bg-violet-500/10 text-violet-600 dark:text-violet-400',
  red: 'bg-red-500/10 text-red-600 dark:text-red-400',
  cyan: 'bg-cyan-500/10 text-cyan-600 dark:text-cyan-400'
};
</script>

<template>
  <div
    class="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4"
  >
    <div
      v-for="stat in statsCards"
      :key="stat.title"
      class="rounded-xl border border-border/60 bg-card p-4 shadow-none transition-shadow hover:shadow-md"
    >
      <div class="flex items-center justify-between gap-3">
        <p class="text-xs font-medium text-muted-foreground">
          {{ stat.title }}
        </p>
        <div
          :class="[
            'flex h-8 w-8 shrink-0 items-center justify-center rounded-md',
            toneClasses[stat.tone]
          ]"
        >
          <component :is="stat.icon" class="h-4 w-4" />
        </div>
      </div>
      <p class="mt-2 truncate text-2xl font-semibold tracking-tight">
        {{
          stat.isText
            ? stat.value
            : Number(stat.value).toLocaleString()
        }}
      </p>
    </div>
  </div>
</template>
