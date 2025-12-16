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
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle
} from '@/components/ui/card';

export interface GroupStatsData {
  totalGroups: number;
  myGroups: number;
  pendingInvites: number;
  todayPosts: number;
  activeMembers: number;
  newMembers: number;
}

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

const statsCards = computed(() => [
  {
    title: '全部群组',
    value: props.stats.totalGroups,
    icon: Users,
    color: 'text-blue-500',
    bgColor: 'bg-blue-500/10'
  },
  {
    title: '我的群组',
    value: props.stats.myGroups,
    icon: FileText,
    color: 'text-green-500',
    bgColor: 'bg-green-500/10'
  },
  {
    title: '待处理邀请',
    value: props.stats.pendingInvites,
    icon: UserPlus,
    color: 'text-yellow-500',
    bgColor: 'bg-yellow-500/10'
  },
  {
    title: '今日帖子',
    value: props.stats.todayPosts,
    icon: MessageSquare,
    color: 'text-purple-500',
    bgColor: 'bg-purple-500/10'
  },
  {
    title: '活跃成员',
    value: props.stats.activeMembers,
    icon: TrendingUp,
    color: 'text-orange-500',
    bgColor: 'bg-orange-500/10'
  },
  {
    title: '新增成员',
    value: props.stats.newMembers,
    icon: Clock,
    color: 'text-pink-500',
    bgColor: 'bg-pink-500/10'
  }
]);
</script>

<template>
  <div
    class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-4"
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
          {{ stat.value.toLocaleString() }}
        </div>
      </CardContent>
    </Card>
  </div>
</template>
