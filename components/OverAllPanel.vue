<script setup lang="ts">
import { ref } from 'vue';
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
  CardDescription
} from '@/components/ui/card';
import {
  Twitter,
  Heart,
  MessageSquare,
  BarChart3,
  Star
} from 'lucide-vue-next';

interface UserAnalyticsData {
  totalTweets: number;
  tweetsThisWeek: number;
  totalLikesReceived: number;
  avgLikesPerTweet: number;
  totalLikesGiven: number;
  totalCommentsMade: number;
  engagementScore: number;
}

defineProps({
  userAnalytics: {
    type: Object as PropType<UserAnalyticsData>,
    required: true
  }
});

// 格式化大数字，例如 10011 -> 10k
const formatNumber = (num: number) => {
  if (num >= 1000) {
    return `${(num / 1000).toFixed(1)}k`;
  }
  return num.toString();
};
</script>

<template>
  <div class="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
    <!-- 卡片 1: 总推文数 -->
    <Card>
      <CardHeader
        class="flex flex-row items-center justify-between space-y-0 pb-2"
      >
        <CardTitle class="text-sm font-medium">
          总推文数
        </CardTitle>
        <Twitter class="size-4 text-muted-foreground" />
      </CardHeader>
      <CardContent>
        <div class="text-2xl font-bold">
          {{ userAnalytics.totalTweets }}
        </div>
        <p class="text-xs text-muted-foreground">
          本周新增 {{ userAnalytics.tweetsThisWeek }} 条
        </p>
      </CardContent>
    </Card>

    <!-- 卡片 2: 收到的赞 -->
    <Card>
      <CardHeader
        class="flex flex-row items-center justify-between space-y-0 pb-2"
      >
        <CardTitle class="text-sm font-medium">
          收到的赞
        </CardTitle>
        <Heart class="size-4 text-muted-foreground" />
      </CardHeader>
      <CardContent>
        <div class="text-2xl font-bold">
          {{
            formatNumber(userAnalytics.totalLikesReceived)
          }}
        </div>
        <p class="text-xs text-muted-foreground">
          平均每条
          {{ userAnalytics.avgLikesPerTweet.toFixed(1) }} 赞
        </p>
      </CardContent>
    </Card>

    <!-- 卡片 3: 互动分数 -->
    <Card>
      <CardHeader
        class="flex flex-row items-center justify-between space-y-0 pb-2"
      >
        <CardTitle class="text-sm font-medium">
          互动分数
        </CardTitle>
        <Star class="size-4 text-muted-foreground" />
      </CardHeader>
      <CardContent>
        <div class="text-2xl font-bold">
          {{ userAnalytics.engagementScore.toFixed(0) }}
        </div>
        <p class="text-xs text-muted-foreground">
          综合评估用户活跃度
        </p>
      </CardContent>
    </Card>

    <!-- 卡片 4: 发出的互动 -->
    <Card>
      <CardHeader
        class="flex flex-row items-center justify-between space-y-0 pb-2"
      >
        <CardTitle class="text-sm font-medium">
          发出的互动
        </CardTitle>
        <BarChart3 class="size-4 text-muted-foreground" />
      </CardHeader>
      <CardContent>
        <div class="text-lg font-bold">
          送出赞: {{ userAnalytics.totalLikesGiven }}
        </div>
        <div class="text-lg font-bold">
          发表评论: {{ userAnalytics.totalCommentsMade }}
        </div>
      </CardContent>
    </Card>
  </div>
</template>
