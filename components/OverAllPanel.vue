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
import { useAnimatedNumber } from '~/composables/useAnimatedNumber';

interface UserAnalyticsData {
  totalTweets: number;
  tweetsThisWeek: number;
  totalLikesReceived: number;
  avgLikesPerTweet: number;
  totalLikesGiven: number;
  totalCommentsMade: number;
  engagementScore: number;
}

const props = defineProps({
  userAnalytics: {
    type: Object as PropType<UserAnalyticsData>,
    required: true
  }
});

const totalTweets = computed(
  () => props.userAnalytics.totalTweets
);
const animatedTotalTweets = useAnimatedNumber(totalTweets);

const totalLikesReceived = computed(
  () => props.userAnalytics.totalLikesReceived
);
const animatedTotalLikesReceived = useAnimatedNumber(
  totalLikesReceived
);

const avgLikesPerTweet = computed(
  () => props.userAnalytics.avgLikesPerTweet
);
const animatedAvgLikesPerTweet = useAnimatedNumber(
  avgLikesPerTweet,
  { duration: 2000 }
);

const engagementScore = computed(
  () => props.userAnalytics.engagementScore
);
const animatedEngagementScore =
  useAnimatedNumber(engagementScore);

const totalLikesGiven = computed(
  () => props.userAnalytics.totalLikesGiven
);
const animatedTotalLikesGiven = useAnimatedNumber(
  totalLikesGiven,
  { duration: 1000 }
);

const totalCommentsMade = computed(
  () => props.userAnalytics.totalCommentsMade
);
const animatedTotalCommentsMade = useAnimatedNumber(
  totalCommentsMade,
  { duration: 1200 }
);

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
          {{
            $t('account.overview.overallPanel.totalTweets')
          }}
        </CardTitle>
        <Twitter class="size-4 text-muted-foreground" />
      </CardHeader>
      <CardContent>
        <div class="text-2xl font-bold">
          {{ animatedTotalTweets.toFixed(0) }}
        </div>
        <p class="text-xs text-muted-foreground">
          {{
            $t(
              'account.overview.overallPanel.tweetsThisWeek'
            )
          }}
          {{ userAnalytics.tweetsThisWeek }}
          {{
            $t('account.overview.overallPanel.tweetsPiece')
          }}
        </p>
      </CardContent>
    </Card>

    <!-- 卡片 2: 收到的赞 -->
    <Card>
      <CardHeader
        class="flex flex-row items-center justify-between space-y-0 pb-2"
      >
        <CardTitle class="text-sm font-medium">
          {{
            $t(
              'account.overview.overallPanel.likesReceived'
            )
          }}
        </CardTitle>
        <Heart class="size-4 text-muted-foreground" />
      </CardHeader>
      <CardContent>
        <div class="text-2xl font-bold">
          {{
            formatNumber(
              Number(animatedTotalLikesReceived.toFixed(0))
            )
          }}
        </div>
        <p class="text-xs text-muted-foreground">
          {{
            $t(
              'account.overview.overallPanel.avgLikesPerTweet'
            )
          }}
          {{ animatedAvgLikesPerTweet.toFixed(1) }}
          {{
            $t('account.overview.overallPanel.likesPiece')
          }}
        </p>
      </CardContent>
    </Card>

    <!-- 卡片 3: 互动分数 -->
    <Card>
      <CardHeader
        class="flex flex-row items-center justify-between space-y-0 pb-2"
      >
        <CardTitle class="text-sm font-medium">
          {{
            $t(
              'account.overview.overallPanel.engagementScore'
            )
          }}
        </CardTitle>
        <Star class="size-4 text-muted-foreground" />
      </CardHeader>
      <CardContent>
        <div class="text-2xl font-bold">
          {{ animatedEngagementScore.toFixed(0) }}
        </div>
        <p class="text-xs text-muted-foreground">
          {{
            $t(
              'account.overview.overallPanel.engagementScoreDescription'
            )
          }}
        </p>
      </CardContent>
    </Card>

    <!-- 卡片 4: 发出的互动 -->
    <Card>
      <CardHeader
        class="flex flex-row items-center justify-between space-y-0 pb-2"
      >
        <CardTitle class="text-sm font-medium">
          {{
            $t(
              'account.overview.overallPanel.outgoingInteractions'
            )
          }}
        </CardTitle>
        <BarChart3 class="size-4 text-muted-foreground" />
      </CardHeader>
      <CardContent>
        <div class="text-lg font-bold">
          {{
            $t('account.overview.overallPanel.likesGiven')
          }}: {{ animatedTotalLikesGiven.toFixed(0) }}
        </div>
        <div class="text-lg font-bold">
          {{
            $t(
              'account.overview.overallPanel.commentsMade'
            )
          }}: {{ animatedTotalCommentsMade.toFixed(0) }}
        </div>
      </CardContent>
    </Card>
  </div>
</template>
