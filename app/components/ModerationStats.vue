<script setup lang="ts">
import { computed } from 'vue';
import {
  Clock,
  CheckCircle,
  XCircle,
  Flag,
  TrendingUp,
  AlertTriangle
} from 'lucide-vue-next';
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle
} from '@/components/ui/card';

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
    color: 'text-yellow-500',
    bgColor: 'bg-yellow-500/10'
  },
  {
    title: t('moderation.stats.approved'),
    value: props.stats.approved,
    icon: CheckCircle,
    color: 'text-green-500',
    bgColor: 'bg-green-500/10'
  },
  {
    title: t('moderation.stats.rejected'),
    value: props.stats.rejected,
    icon: XCircle,
    color: 'text-destructive',
    bgColor: 'bg-destructive/10'
  },
  {
    title: t('moderation.stats.flagged'),
    value: props.stats.flagged,
    icon: Flag,
    color: 'text-orange-500',
    bgColor: 'bg-orange-500/10'
  },
  {
    title: t('moderation.stats.todayProcessed'),
    value: props.stats.todayProcessed,
    icon: TrendingUp,
    color: 'text-blue-500',
    bgColor: 'bg-blue-500/10'
  },
  {
    title: t('moderation.stats.avgProcessTime'),
    value:
      props.stats.avgProcessTime ||
      t('moderation.stats.zeroMinutes'),
    icon: AlertTriangle,
    color: 'text-purple-500',
    bgColor: 'bg-purple-500/10',
    isText: true
  },
  {
    title: t('moderation.stats.openReports'),
    value: props.stats.openReports ?? 0,
    icon: AlertTriangle,
    color: 'text-red-500',
    bgColor: 'bg-red-500/10'
  },
  {
    title: t('moderation.stats.appealSuccessRate'),
    value: `${props.stats.appealSuccessRate ?? 0}%`,
    icon: TrendingUp,
    color: 'text-cyan-500',
    bgColor: 'bg-cyan-500/10',
    isText: true
  }
]);
</script>

<template>
  <div
    class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-8 gap-4"
  >
    <Card
      v-for="stat in statsCards"
      :key="stat.title"
      class="hover:shadow-md transition-shadow"
    >
      <CardHeader
        class="flex flex-row items-center justify-between space-y-0 pb-2"
      >
        <CardTitle
          class="text-sm font-medium text-muted-foreground"
        >
          {{ stat.title }}
        </CardTitle>
        <div :class="[stat.bgColor, 'p-2 rounded-lg']">
          <component
            :is="stat.icon"
            :class="['h-4 w-4', stat.color]"
          />
        </div>
      </CardHeader>
      <CardContent>
        <div class="text-2xl font-bold">
          {{
            stat.isText
              ? stat.value
              : stat.value.toLocaleString()
          }}
        </div>
      </CardContent>
    </Card>
  </div>
</template>
