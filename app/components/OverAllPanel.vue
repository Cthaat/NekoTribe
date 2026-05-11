<script setup lang="ts">
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle
} from '@/components/ui/card';
import type { ChartConfig } from '@/components/ui/chart';
import {
  ChartContainer,
  ChartCrosshair,
  ChartLegendContent,
  ChartTooltip,
  ChartTooltipContent,
  componentToString
} from '@/components/ui/chart';
import {
  VisAxis,
  VisLine,
  VisXYContainer
} from '@unovis/vue';
import {
  Activity,
  CalendarDays,
  FileText,
  Heart,
  MessageSquare,
  Send,
  Sparkles,
  ThumbsUp,
  TrendingUp
} from 'lucide-vue-next';
import { useAnimatedNumber } from '~/composables/useAnimatedNumber';
import type { UserDailyAnalyticsVM } from '@/types/users';

const { t, locale } = useAppLocale();

interface UserAnalyticsData {
  totalTweets: number;
  tweetsThisWeek: number;
  totalLikesReceived: number;
  avgLikesPerTweet: number;
  totalLikesGiven: number;
  totalCommentsMade: number;
  engagementScore: number;
}

const props = withDefaults(
  defineProps<{
    userAnalytics: UserAnalyticsData;
    dailyAnalytics?: UserDailyAnalyticsVM[];
  }>(),
  {
    dailyAnalytics: () => []
  }
);

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

interface DailyChartPoint {
  day: string;
  date: number;
  posts: number;
  likes: number;
  comments: number;
  interaction: number;
}

const dailyInteraction = (row: UserDailyAnalyticsVM): number =>
  row.likesReceived +
  row.commentsReceived +
  row.retweetsReceived;

const chartData = computed<DailyChartPoint[]>(() =>
  props.dailyAnalytics.map(row => ({
    day: row.day,
    date: new Date(`${row.day}T00:00:00`).getTime(),
    posts: row.postsCount,
    likes: row.likesReceived,
    comments: row.commentsReceived,
    interaction: dailyInteraction(row)
  }))
);

const chartConfig = {
  posts: {
    label: t('account.overview.overallPanel.chartPosts'),
    color: 'var(--chart-1)'
  },
  likes: {
    label: t('account.overview.overallPanel.chartLikes'),
    color: 'var(--chart-2)'
  },
  comments: {
    label: t('account.overview.overallPanel.chartComments'),
    color: 'var(--chart-3)'
  },
  interaction: {
    label: t('account.overview.overallPanel.chartInteraction'),
    color: 'var(--chart-4)'
  }
} satisfies ChartConfig;

const chartColors = [
  chartConfig.posts.color,
  chartConfig.likes.color,
  chartConfig.comments.color,
  chartConfig.interaction.color
];

const chartX = (point: DailyChartPoint): number => point.date;
const chartY = [
  (point: DailyChartPoint) => point.posts,
  (point: DailyChartPoint) => point.likes,
  (point: DailyChartPoint) => point.comments,
  (point: DailyChartPoint) => point.interaction
];

const formatChartDay = (value: number | Date): string =>
  new Intl.DateTimeFormat(locale.value, {
    month: '2-digit',
    day: '2-digit'
  }).format(value instanceof Date ? value : new Date(value));

const chartTooltipTemplate = componentToString(
  chartConfig,
  ChartTooltipContent,
  {
    labelFormatter: formatChartDay
  }
);
</script>

<template>
  <div class="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
    <!-- 卡片 1: 总推文数 -->
    <Card class="overflow-hidden">
      <CardHeader
        class="flex flex-row items-center justify-between space-y-0 pb-2"
      >
        <div class="flex items-center gap-3">
          <div
            class="flex h-10 w-10 items-center justify-center rounded-md border bg-primary/10 text-primary"
          >
            <FileText class="h-5 w-5" />
          </div>
          <CardTitle class="text-sm font-medium">
            {{
              t('account.overview.overallPanel.totalTweets')
            }}
          </CardTitle>
        </div>
        <TrendingUp class="size-4 text-muted-foreground" />
      </CardHeader>
      <CardContent>
        <div class="text-2xl font-bold">
          {{ animatedTotalTweets.toFixed(0) }}
        </div>
        <div
          class="mt-3 flex items-center gap-2 text-xs text-muted-foreground"
        >
          <CalendarDays class="h-3.5 w-3.5" />
          <span>
            {{
              t(
                'account.overview.overallPanel.tweetsThisWeek'
              )
            }}
            {{ userAnalytics.tweetsThisWeek }}
            {{
              t('account.overview.overallPanel.tweetsPiece')
            }}
          </span>
        </div>
      </CardContent>
    </Card>

    <!-- 卡片 2: 收到的赞 -->
    <Card class="overflow-hidden">
      <CardHeader
        class="flex flex-row items-center justify-between space-y-0 pb-2"
      >
        <div class="flex items-center gap-3">
          <div
            class="flex h-10 w-10 items-center justify-center rounded-md border bg-rose-500/10 text-rose-500"
          >
            <Heart class="h-5 w-5" />
          </div>
          <CardTitle class="text-sm font-medium">
            {{
              t(
                'account.overview.overallPanel.likesReceived'
              )
            }}
          </CardTitle>
        </div>
        <ThumbsUp class="size-4 text-muted-foreground" />
      </CardHeader>
      <CardContent>
        <div class="text-2xl font-bold">
          {{
            formatNumber(
              Number(animatedTotalLikesReceived.toFixed(0))
            )
          }}
        </div>
        <div
          class="mt-3 flex items-center gap-2 text-xs text-muted-foreground"
        >
          <Sparkles class="h-3.5 w-3.5" />
          <span>
            {{
              t(
                'account.overview.overallPanel.avgLikesPerTweet'
              )
            }}
            {{ animatedAvgLikesPerTweet.toFixed(1) }}
            {{
              t('account.overview.overallPanel.likesPiece')
            }}
          </span>
        </div>
      </CardContent>
    </Card>

    <!-- 卡片 3: 互动分数 -->
    <Card class="overflow-hidden">
      <CardHeader
        class="flex flex-row items-center justify-between space-y-0 pb-2"
      >
        <div class="flex items-center gap-3">
          <div
            class="flex h-10 w-10 items-center justify-center rounded-md border bg-amber-500/10 text-amber-500"
          >
            <Activity class="h-5 w-5" />
          </div>
          <CardTitle class="text-sm font-medium">
            {{
              t(
                'account.overview.overallPanel.engagementScore'
              )
            }}
          </CardTitle>
        </div>
        <TrendingUp class="size-4 text-muted-foreground" />
      </CardHeader>
      <CardContent>
        <div class="text-2xl font-bold">
          {{ animatedEngagementScore.toFixed(0) }}
        </div>
        <p class="mt-3 text-xs text-muted-foreground">
          {{
            t(
              'account.overview.overallPanel.engagementScoreDescription'
            )
          }}
        </p>
      </CardContent>
    </Card>

    <!-- 卡片 4: 发出的互动 -->
    <Card class="overflow-hidden lg:col-span-3">
      <CardHeader
        class="flex flex-row items-center justify-between space-y-0 pb-2"
      >
        <div class="flex items-center gap-3">
          <div
            class="flex h-10 w-10 items-center justify-center rounded-md border bg-sky-500/10 text-sky-500"
          >
            <Send class="h-5 w-5" />
          </div>
          <CardTitle class="text-sm font-medium">
            {{
              t(
                'account.overview.overallPanel.outgoingInteractions'
              )
            }}
          </CardTitle>
        </div>
        <MessageSquare class="size-4 text-muted-foreground" />
      </CardHeader>
      <CardContent>
        <div class="grid gap-3 sm:grid-cols-2">
          <div
            class="flex items-center gap-3 rounded-md border bg-muted/30 p-3"
          >
            <div
              class="flex h-9 w-9 items-center justify-center rounded-md bg-rose-500/10 text-rose-500"
            >
              <Heart class="h-4 w-4" />
            </div>
            <div>
              <div class="text-lg font-bold">
                {{ animatedTotalLikesGiven.toFixed(0) }}
              </div>
              <div class="text-xs text-muted-foreground">
                {{
                  t('account.overview.overallPanel.likesGiven')
                }}
              </div>
            </div>
          </div>
          <div
            class="flex items-center gap-3 rounded-md border bg-muted/30 p-3"
          >
            <div
              class="flex h-9 w-9 items-center justify-center rounded-md bg-violet-500/10 text-violet-500"
            >
              <MessageSquare class="h-4 w-4" />
            </div>
            <div>
              <div class="text-lg font-bold">
                {{ animatedTotalCommentsMade.toFixed(0) }}
              </div>
              <div class="text-xs text-muted-foreground">
                {{
                  t(
                    'account.overview.overallPanel.commentsMade'
                  )
                }}
              </div>
            </div>
          </div>
        </div>
      </CardContent>
    </Card>

    <Card class="overflow-hidden md:col-span-2 lg:col-span-3">
      <CardHeader
        class="flex flex-row items-start justify-between space-y-0"
      >
        <div class="space-y-1">
          <CardTitle class="flex items-center gap-2 text-base">
            <TrendingUp class="h-4 w-4 text-primary" />
            {{ t('account.overview.overallPanel.dailyTrend') }}
          </CardTitle>
          <p class="text-sm text-muted-foreground">
            {{
              t(
                'account.overview.overallPanel.dailyTrendDescription'
              )
            }}
          </p>
        </div>
      </CardHeader>
      <CardContent>
        <div
          v-if="chartData.length === 0"
          class="flex h-56 items-center justify-center rounded-lg border border-dashed text-sm text-muted-foreground"
        >
          {{ t('account.overview.overallPanel.noTrendData') }}
        </div>
        <div
          v-else
          class="overflow-hidden rounded-lg border bg-muted/20 p-3"
        >
          <ChartContainer
            :config="chartConfig"
            :cursor="true"
            class="h-72 w-full"
          >
            <VisXYContainer
              :data="chartData"
              :y-domain="[0, undefined]"
            >
              <VisLine
                :x="chartX"
                :y="chartY"
                :color="chartColors"
                :line-width="2.5"
              />
              <VisAxis
                type="x"
                :num-ticks="Math.min(6, chartData.length)"
                :tick-format="formatChartDay"
                :tick-line="false"
                :domain-line="false"
              />
              <VisAxis
                type="y"
                :grid-line="true"
                :tick-line="false"
                :domain-line="false"
              />
              <ChartTooltip />
              <ChartCrosshair
                :template="chartTooltipTemplate"
                :color="chartColors"
              />
            </VisXYContainer>
            <ChartLegendContent
              class="flex-wrap text-xs text-muted-foreground"
            />
          </ChartContainer>
        </div>
      </CardContent>
    </Card>
  </div>
</template>
          >
            <div class="grid grid-cols-2 gap-2">
              <span class="flex items-center gap-1">
                <span class="h-2 w-2 rounded-full bg-chart-1" />
                {{ t('account.overview.overallPanel.chartPosts') }}
              </span>
              <span class="flex items-center gap-1">
                <span class="h-2 w-2 rounded-full bg-chart-2" />
                {{ t('account.overview.overallPanel.chartLikes') }}
              </span>
              <span class="flex items-center gap-1">
                <span class="h-2 w-2 rounded-full bg-chart-3" />
                {{ t('account.overview.overallPanel.chartComments') }}
              </span>
              <span class="flex items-center gap-1">
                <span class="h-2 w-2 rounded-full bg-chart-4" />
                {{
                  t(
                    'account.overview.overallPanel.chartInteraction'
                  )
                }}
              </span>
            </div>
          </div>
        </div>
      </CardContent>
    </Card>
  </div>
</template>
