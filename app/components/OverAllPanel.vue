<script setup lang="ts">
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle
} from '@/components/ui/card';
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

const { t } = useAppLocale();

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

const chartWidth = 640;
const chartHeight = 220;
const chartPadding = {
  left: 34,
  right: 18,
  top: 18,
  bottom: 34
};

const dailyRows = computed(() => props.dailyAnalytics);

const dailyInteraction = (
  row: UserDailyAnalyticsVM
): number =>
  row.likesReceived +
  row.commentsReceived +
  row.retweetsReceived;

const dailyMaxValue = computed(() =>
  Math.max(
    1,
    ...dailyRows.value.flatMap(row => [
      row.postsCount,
      row.likesReceived,
      row.commentsReceived,
      dailyInteraction(row)
    ])
  )
);

const chartX = (index: number): number => {
  const count = dailyRows.value.length;
  if (count <= 1) return chartPadding.left;
  return (
    chartPadding.left +
    (index *
      (chartWidth - chartPadding.left - chartPadding.right)) /
      (count - 1)
  );
};

const chartY = (value: number): number => {
  const usableHeight =
    chartHeight - chartPadding.top - chartPadding.bottom;
  return (
    chartPadding.top +
    usableHeight * (1 - value / dailyMaxValue.value)
  );
};

const chartPoints = (
  selector: (row: UserDailyAnalyticsVM) => number
): string =>
  dailyRows.value
    .map((row, index) =>
      [chartX(index), chartY(selector(row))].join(',')
    )
    .join(' ');

const postsPoints = computed(() =>
  chartPoints(row => row.postsCount)
);
const likesPoints = computed(() =>
  chartPoints(row => row.likesReceived)
);
const commentsPoints = computed(() =>
  chartPoints(row => row.commentsReceived)
);
const interactionPoints = computed(() =>
  chartPoints(dailyInteraction)
);

const labelStep = computed(() =>
  Math.max(1, Math.ceil(dailyRows.value.length / 6))
);

const formatChartDay = (value: string): string => {
  const [, month = '', day = ''] = value.split('-');
  return `${month}/${day}`;
};
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
        <div
          class="hidden flex-wrap items-center gap-3 text-xs text-muted-foreground sm:flex"
        >
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
            {{ t('account.overview.overallPanel.chartInteraction') }}
          </span>
        </div>
      </CardHeader>
      <CardContent>
        <div
          v-if="dailyRows.length === 0"
          class="flex h-56 items-center justify-center rounded-lg border border-dashed text-sm text-muted-foreground"
        >
          {{ t('account.overview.overallPanel.noTrendData') }}
        </div>
        <div v-else class="overflow-hidden rounded-lg border bg-muted/20 p-3">
          <svg
            class="h-64 w-full"
            :viewBox="`0 0 ${chartWidth} ${chartHeight}`"
            role="img"
            :aria-label="t('account.overview.overallPanel.dailyTrend')"
          >
            <line
              v-for="tick in [0, 0.25, 0.5, 0.75, 1]"
              :key="tick"
              :x1="chartPadding.left"
              :x2="chartWidth - chartPadding.right"
              :y1="chartPadding.top + (chartHeight - chartPadding.top - chartPadding.bottom) * tick"
              :y2="chartPadding.top + (chartHeight - chartPadding.top - chartPadding.bottom) * tick"
              class="stroke-border"
              stroke-width="1"
            />

            <polyline
              :points="interactionPoints"
              fill="none"
              stroke="var(--chart-4)"
              stroke-width="3"
              stroke-linecap="round"
              stroke-linejoin="round"
              opacity="0.9"
            />
            <polyline
              :points="likesPoints"
              fill="none"
              stroke="var(--chart-2)"
              stroke-width="2.5"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
            <polyline
              :points="commentsPoints"
              fill="none"
              stroke="var(--chart-3)"
              stroke-width="2.5"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
            <polyline
              :points="postsPoints"
              fill="none"
              stroke="var(--chart-1)"
              stroke-width="2.5"
              stroke-linecap="round"
              stroke-linejoin="round"
            />

            <g
              v-for="(row, index) in dailyRows"
              :key="row.day"
            >
              <circle
                :cx="chartX(index)"
                :cy="chartY(dailyInteraction(row))"
                r="3"
                fill="var(--chart-4)"
              />
              <text
                v-if="
                  index === 0 ||
                  index === dailyRows.length - 1 ||
                  index % labelStep === 0
                "
                :x="chartX(index)"
                :y="chartHeight - 8"
                text-anchor="middle"
                class="fill-muted-foreground text-[10px]"
              >
                {{ formatChartDay(row.day) }}
              </text>
            </g>

            <text
              :x="chartPadding.left - 8"
              :y="chartY(dailyMaxValue)"
              text-anchor="end"
              dominant-baseline="middle"
              class="fill-muted-foreground text-[10px]"
            >
              {{ dailyMaxValue }}
            </text>
            <text
              :x="chartPadding.left - 8"
              :y="chartY(0)"
              text-anchor="end"
              dominant-baseline="middle"
              class="fill-muted-foreground text-[10px]"
            >
              0
            </text>
          </svg>

          <div
            class="mt-3 grid gap-2 text-xs text-muted-foreground sm:hidden"
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
