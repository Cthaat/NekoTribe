<script setup lang="ts">
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle
} from '@/components/ui/card';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow
} from '@/components/ui/table';
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
  VisArea,
  VisDonut,
  VisGroupedBar,
  VisLine,
  VisSingleContainer,
  VisStackedBar,
  VisXYContainer
} from '@unovis/vue';
import {
  Activity,
  BarChart3,
  CalendarDays,
  FileText,
  Heart,
  MessageSquare,
  PieChart,
  Table2 as TableIcon,
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

function chartText(
  key: string,
  zhFallback: string,
  enFallback: string
): string {
  const value = t(key);
  if (value !== key) return value;
  return locale.value === 'en' ? enFallback : zhFallback;
}

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
  retweets: number;
  interaction: number;
  givenLikes: number;
  madeComments: number;
  outgoing: number;
  score: number;
}

const dailyInteraction = (row: UserDailyAnalyticsVM): number =>
  row.likesReceived +
  row.commentsReceived +
  row.retweetsReceived;

const hasAggregateData = computed(() =>
  [
    props.userAnalytics.totalTweets,
    props.userAnalytics.tweetsThisWeek,
    props.userAnalytics.totalLikesReceived,
    props.userAnalytics.totalLikesGiven,
    props.userAnalytics.totalCommentsMade,
    props.userAnalytics.engagementScore
  ].some(value => value > 0)
);

const normalizedDailyAnalytics = computed(() =>
  props.dailyAnalytics.filter(row => row.day)
);

const fallbackChartData = computed<DailyChartPoint[]>(() => {
  if (!hasAggregateData.value) return [];
  const today = new Date().toISOString().slice(0, 10);
  return [
    {
      day: today,
      date: new Date(`${today}T00:00:00`).getTime(),
      posts:
        props.userAnalytics.tweetsThisWeek ||
        props.userAnalytics.totalTweets,
      likes: props.userAnalytics.totalLikesReceived,
      comments: 0,
      retweets: 0,
      interaction: props.userAnalytics.totalLikesReceived,
      givenLikes: props.userAnalytics.totalLikesGiven,
      madeComments: props.userAnalytics.totalCommentsMade,
      outgoing:
        props.userAnalytics.totalLikesGiven +
        props.userAnalytics.totalCommentsMade,
      score: props.userAnalytics.engagementScore
    }
  ];
});

const chartData = computed<DailyChartPoint[]>(() => {
  if (normalizedDailyAnalytics.value.length === 0) {
    return fallbackChartData.value;
  }

  return normalizedDailyAnalytics.value.map(row => ({
    day: row.day,
    date: new Date(`${row.day}T00:00:00`).getTime(),
    posts: row.postsCount,
    likes: row.likesReceived,
    comments: row.commentsReceived,
    retweets: row.retweetsReceived,
    interaction: dailyInteraction(row),
    givenLikes: row.likesGiven,
    madeComments: row.commentsMade,
    outgoing: row.likesGiven + row.commentsMade,
    score: row.engagementScore
  }));
});

const totalPostsInRange = computed(() =>
  chartData.value.reduce((total, point) => total + point.posts, 0)
);
const totalReceivedInRange = computed(() =>
  chartData.value.reduce(
    (total, point) =>
      total + point.likes + point.comments + point.retweets,
    0
  )
);
const totalOutgoingInRange = computed(() =>
  chartData.value.reduce(
    (total, point) =>
      total + point.givenLikes + point.madeComments,
    0
  )
);
const totalScoreInRange = computed(() =>
  chartData.value.reduce((total, point) => total + point.score, 0)
);
const hasChartData = computed(() => chartData.value.length > 0);

const chartConfig = computed(
  () =>
    ({
  posts: {
    label: chartText(
      'account.overview.overallPanel.chartPosts',
      '发帖',
      'Posts'
    ),
    color: 'var(--chart-1)'
  },
  likes: {
    label: chartText(
      'account.overview.overallPanel.chartLikes',
      '获赞',
      'Likes'
    ),
    color: 'var(--chart-2)'
  },
  comments: {
    label: chartText(
      'account.overview.overallPanel.chartComments',
      '评论',
      'Comments'
    ),
    color: 'var(--chart-3)'
  },
  retweets: {
    label: chartText(
      'account.overview.overallPanel.chartRetweets',
      '转发',
      'Retweets'
    ),
    color: 'var(--chart-5)'
  },
  interaction: {
    label: chartText(
      'account.overview.overallPanel.chartInteraction',
      '互动',
      'Engagement'
    ),
    color: 'var(--chart-4)'
  }
    }) satisfies ChartConfig
);

const receivedChartConfig = computed(
  () =>
    ({
      likes: chartConfig.value.likes,
      comments: chartConfig.value.comments,
      retweets: chartConfig.value.retweets
    }) satisfies ChartConfig
);

const outgoingChartConfig = computed(
  () =>
    ({
      givenLikes: {
        label: chartText(
          'account.overview.overallPanel.chartGivenLikes',
          '送出赞',
          'Likes Given'
        ),
        color: 'var(--chart-2)'
      },
      madeComments: {
        label: chartText(
          'account.overview.overallPanel.chartMadeComments',
          '发出评论',
          'Comments Made'
        ),
        color: 'var(--chart-4)'
      }
    }) satisfies ChartConfig
);

const scoreChartConfig = computed(
  () =>
    ({
      score: {
        label: chartText(
          'account.overview.overallPanel.chartScore',
          '互动分',
          'Score'
        ),
        color: 'var(--chart-1)'
      }
    }) satisfies ChartConfig
);

const compositionChartConfig = computed(
  () =>
    ({
      posts: chartConfig.value.posts,
      received: {
        label: chartText(
          'account.overview.overallPanel.chartReceived',
          '收获互动',
          'Received'
        ),
        color: 'var(--chart-2)'
      },
      outgoing: {
        label: chartText(
          'account.overview.overallPanel.chartOutgoing',
          '发出互动',
          'Outgoing'
        ),
        color: 'var(--chart-4)'
      },
      score: scoreChartConfig.value.score
    }) satisfies ChartConfig
);

const chartColors = computed(() => [
  chartConfig.value.posts.color,
  chartConfig.value.likes.color,
  chartConfig.value.comments.color,
  chartConfig.value.interaction.color
]);

const chartX = (point: DailyChartPoint): number => point.date;
const chartY = [
  (point: DailyChartPoint) => point.posts,
  (point: DailyChartPoint) => point.likes,
  (point: DailyChartPoint) => point.comments,
  (point: DailyChartPoint) => point.interaction
];
const receivedChartY = [
  (point: DailyChartPoint) => point.likes,
  (point: DailyChartPoint) => point.comments,
  (point: DailyChartPoint) => point.retweets
];
const outgoingChartY = [
  (point: DailyChartPoint) => point.givenLikes,
  (point: DailyChartPoint) => point.madeComments
];
const scoreChartY = (point: DailyChartPoint): number => point.score;

const receivedChartColors = computed(() => [
  receivedChartConfig.value.likes.color,
  receivedChartConfig.value.comments.color,
  receivedChartConfig.value.retweets.color
]);
const outgoingChartColors = computed(() => [
  outgoingChartConfig.value.givenLikes.color,
  outgoingChartConfig.value.madeComments.color
]);

const formatChartDay = (value: number | Date): string =>
  new Intl.DateTimeFormat(locale.value, {
    month: '2-digit',
    day: '2-digit'
  }).format(value instanceof Date ? value : new Date(value));

const chartTooltipTemplate = componentToString(
  chartConfig.value,
  ChartTooltipContent,
  {
    labelFormatter: formatChartDay
  }
);
const receivedTooltipTemplate = componentToString(
  receivedChartConfig.value,
  ChartTooltipContent,
  {
    labelFormatter: formatChartDay
  }
);
const outgoingTooltipTemplate = componentToString(
  outgoingChartConfig.value,
  ChartTooltipContent,
  {
    labelFormatter: formatChartDay
  }
);
const scoreTooltipTemplate = componentToString(
  scoreChartConfig.value,
  ChartTooltipContent,
  {
    labelFormatter: formatChartDay
  }
);

type CompositionKey = 'posts' | 'received' | 'outgoing' | 'score';

interface CompositionPoint {
  key: CompositionKey;
  label: string;
  value: number;
  color: string;
}

const compositionData = computed<CompositionPoint[]>(() => [
  {
    key: 'posts',
    label: String(compositionChartConfig.value.posts.label),
    value: totalPostsInRange.value,
    color: String(compositionChartConfig.value.posts.color)
  },
  {
    key: 'received',
    label: String(compositionChartConfig.value.received.label),
    value: totalReceivedInRange.value,
    color: String(compositionChartConfig.value.received.color)
  },
  {
    key: 'outgoing',
    label: String(compositionChartConfig.value.outgoing.label),
    value: totalOutgoingInRange.value,
    color: String(compositionChartConfig.value.outgoing.color)
  },
  {
    key: 'score',
    label: String(compositionChartConfig.value.score.label),
    value: totalScoreInRange.value,
    color: String(compositionChartConfig.value.score.color)
  }
]);

const compositionTotal = computed(() =>
  compositionData.value.reduce(
    (total, item) => total + item.value,
    0
  )
);
const hasCompositionData = computed(
  () => compositionTotal.value > 0
);

const formatShare = (value: number): string => {
  if (!compositionTotal.value) return '0%';
  return `${Math.round((value / compositionTotal.value) * 100)}%`;
};
const compositionValue = (item: CompositionPoint): number =>
  item.value;
const compositionColor = (item: CompositionPoint): string =>
  item.color;

const tableRows = computed(() =>
  [...chartData.value].sort((a, b) => b.date - a.date)
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
          v-if="!hasChartData"
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

    <Card class="overflow-hidden md:col-span-2 lg:col-span-2">
      <CardHeader
        class="flex flex-row items-start justify-between space-y-0"
      >
        <div class="space-y-1">
          <CardTitle class="flex items-center gap-2 text-base">
            <BarChart3 class="h-4 w-4 text-primary" />
            {{ t('account.overview.overallPanel.receivedBreakdown') }}
          </CardTitle>
          <p class="text-sm text-muted-foreground">
            {{
              t(
                'account.overview.overallPanel.receivedBreakdownDescription'
              )
            }}
          </p>
        </div>
      </CardHeader>
      <CardContent>
        <div
          v-if="!hasChartData"
          class="flex h-64 items-center justify-center rounded-lg border border-dashed text-sm text-muted-foreground"
        >
          {{ t('account.overview.overallPanel.noTrendData') }}
        </div>
        <div
          v-else
          class="overflow-hidden rounded-lg border bg-muted/20 p-3"
        >
          <ChartContainer
            :config="receivedChartConfig"
            :cursor="true"
            class="h-64 w-full"
          >
            <VisXYContainer
              :data="chartData"
              :y-domain="[0, undefined]"
            >
              <VisStackedBar
                :x="chartX"
                :y="receivedChartY"
                :color="receivedChartColors"
                :bar-padding="0.12"
                :rounded-corners="4"
              />
              <VisAxis
                type="x"
                :num-ticks="Math.min(5, chartData.length)"
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
                :template="receivedTooltipTemplate"
                :color="receivedChartColors"
              />
            </VisXYContainer>
            <ChartLegendContent
              class="flex-wrap text-xs text-muted-foreground"
            />
          </ChartContainer>
        </div>
      </CardContent>
    </Card>

    <Card class="overflow-hidden md:col-span-2 lg:col-span-1">
      <CardHeader
        class="flex flex-row items-start justify-between space-y-0"
      >
        <div class="space-y-1">
          <CardTitle class="flex items-center gap-2 text-base">
            <Send class="h-4 w-4 text-primary" />
            {{ t('account.overview.overallPanel.outgoingTrend') }}
          </CardTitle>
          <p class="text-sm text-muted-foreground">
            {{
              t(
                'account.overview.overallPanel.outgoingTrendDescription'
              )
            }}
          </p>
        </div>
      </CardHeader>
      <CardContent>
        <div
          v-if="!hasChartData"
          class="flex h-64 items-center justify-center rounded-lg border border-dashed text-sm text-muted-foreground"
        >
          {{ t('account.overview.overallPanel.noTrendData') }}
        </div>
        <div
          v-else
          class="overflow-hidden rounded-lg border bg-muted/20 p-3"
        >
          <ChartContainer
            :config="outgoingChartConfig"
            :cursor="true"
            class="h-64 w-full"
          >
            <VisXYContainer
              :data="chartData"
              :y-domain="[0, undefined]"
            >
              <VisGroupedBar
                :x="chartX"
                :y="outgoingChartY"
                :color="outgoingChartColors"
                :group-padding="0.16"
                :bar-padding="0.08"
                :rounded-corners="4"
              />
              <VisAxis
                type="x"
                :num-ticks="Math.min(5, chartData.length)"
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
                :template="outgoingTooltipTemplate"
                :color="outgoingChartColors"
              />
            </VisXYContainer>
            <ChartLegendContent
              class="flex-wrap text-xs text-muted-foreground"
            />
          </ChartContainer>
        </div>
      </CardContent>
    </Card>

    <Card class="overflow-hidden md:col-span-2 lg:col-span-3">
      <CardHeader
        class="flex flex-row items-start justify-between space-y-0"
      >
        <div class="space-y-1">
          <CardTitle class="flex items-center gap-2 text-base">
            <Activity class="h-4 w-4 text-primary" />
            {{ t('account.overview.overallPanel.scoreTrend') }}
          </CardTitle>
          <p class="text-sm text-muted-foreground">
            {{
              t(
                'account.overview.overallPanel.scoreTrendDescription'
              )
            }}
          </p>
        </div>
      </CardHeader>
      <CardContent>
        <div
          v-if="!hasChartData"
          class="flex h-64 items-center justify-center rounded-lg border border-dashed text-sm text-muted-foreground"
        >
          {{ t('account.overview.overallPanel.noTrendData') }}
        </div>
        <div
          v-else
          class="overflow-hidden rounded-lg border bg-muted/20 p-3"
        >
          <ChartContainer
            :config="scoreChartConfig"
            :cursor="true"
            class="h-56 w-full"
          >
            <VisXYContainer
              :data="chartData"
              :y-domain="[0, undefined]"
            >
              <VisArea
                :x="chartX"
                :y="scoreChartY"
                :color="scoreChartConfig.score.color"
                :line="true"
                :line-color="scoreChartConfig.score.color"
                :opacity="0.18"
              />
              <VisAxis
                type="x"
                :num-ticks="Math.min(5, chartData.length)"
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
                :template="scoreTooltipTemplate"
                :color="scoreChartConfig.score.color"
              />
            </VisXYContainer>
            <ChartLegendContent
              class="flex-wrap text-xs text-muted-foreground"
            />
          </ChartContainer>
        </div>
      </CardContent>
    </Card>

    <Card class="overflow-hidden md:col-span-2 lg:col-span-3">
      <CardHeader
        class="flex flex-row items-start justify-between space-y-0"
      >
        <div class="space-y-1">
          <CardTitle class="flex items-center gap-2 text-base">
            <PieChart class="h-4 w-4 text-primary" />
            {{ t('account.overview.overallPanel.compositionTitle') }}
          </CardTitle>
          <p class="text-sm text-muted-foreground">
            {{
              t(
                'account.overview.overallPanel.compositionDescription'
              )
            }}
          </p>
        </div>
      </CardHeader>
      <CardContent>
        <div
          v-if="!hasCompositionData"
          class="flex h-64 items-center justify-center rounded-lg border border-dashed text-sm text-muted-foreground"
        >
          {{ t('account.overview.overallPanel.noTrendData') }}
        </div>
        <div
          v-else
          class="grid gap-4 rounded-lg border bg-muted/20 p-4 lg:grid-cols-[minmax(14rem,18rem)_1fr]"
        >
          <ChartContainer
            :config="compositionChartConfig"
            class="h-56 w-full"
          >
            <VisSingleContainer :data="compositionData">
              <VisDonut
                :value="compositionValue"
                :color="compositionColor"
                :arc-width="32"
                :corner-radius="6"
                :pad-angle="0.025"
                :central-label="formatNumber(compositionTotal)"
                :central-sub-label="t('account.overview.overallPanel.compositionTotal')"
              />
            </VisSingleContainer>
          </ChartContainer>

          <div class="grid content-center gap-3 sm:grid-cols-2">
            <div
              v-for="item in compositionData"
              :key="item.key"
              class="rounded-md border bg-background/70 p-3"
            >
              <div class="flex items-center justify-between gap-3">
                <div class="flex min-w-0 items-center gap-2">
                  <span
                    class="h-2.5 w-2.5 shrink-0 rounded-sm"
                    :style="{ backgroundColor: item.color }"
                  />
                  <span class="truncate text-sm text-muted-foreground">
                    {{ item.label }}
                  </span>
                </div>
                <span class="text-xs text-muted-foreground">
                  {{ formatShare(item.value) }}
                </span>
              </div>
              <div class="mt-2 text-2xl font-semibold">
                {{ formatNumber(item.value) }}
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
            <TableIcon class="h-4 w-4 text-primary" />
            {{ t('account.overview.overallPanel.dataTableTitle') }}
          </CardTitle>
          <p class="text-sm text-muted-foreground">
            {{
              t(
                'account.overview.overallPanel.dataTableDescription'
              )
            }}
          </p>
        </div>
      </CardHeader>
      <CardContent>
        <div
          v-if="!hasChartData"
          class="flex h-40 items-center justify-center rounded-lg border border-dashed text-sm text-muted-foreground"
        >
          {{ t('account.overview.overallPanel.noTrendData') }}
        </div>
        <div v-else class="overflow-hidden rounded-lg border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>
                  {{ t('account.overview.overallPanel.tableDate') }}
                </TableHead>
                <TableHead class="text-right">
                  {{ t('account.overview.overallPanel.tablePosts') }}
                </TableHead>
                <TableHead class="text-right">
                  {{ t('account.overview.overallPanel.tableLikes') }}
                </TableHead>
                <TableHead class="text-right">
                  {{ t('account.overview.overallPanel.tableComments') }}
                </TableHead>
                <TableHead class="text-right">
                  {{ t('account.overview.overallPanel.tableRetweets') }}
                </TableHead>
                <TableHead class="text-right">
                  {{ t('account.overview.overallPanel.tableOutgoing') }}
                </TableHead>
                <TableHead class="text-right">
                  {{ t('account.overview.overallPanel.tableScore') }}
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              <TableRow
                v-for="row in tableRows"
                :key="row.day"
              >
                <TableCell class="font-medium">
                  {{ formatChartDay(row.date) }}
                </TableCell>
                <TableCell class="text-right">
                  {{ formatNumber(row.posts) }}
                </TableCell>
                <TableCell class="text-right">
                  {{ formatNumber(row.likes) }}
                </TableCell>
                <TableCell class="text-right">
                  {{ formatNumber(row.comments) }}
                </TableCell>
                <TableCell class="text-right">
                  {{ formatNumber(row.retweets) }}
                </TableCell>
                <TableCell class="text-right">
                  {{ formatNumber(row.outgoing) }}
                </TableCell>
                <TableCell class="text-right">
                  {{ formatNumber(row.score) }}
                </TableCell>
              </TableRow>
            </TableBody>
          </Table>
        </div>
      </CardContent>
    </Card>
  </div>
</template>
