<script setup lang="ts">
import { ref, computed, onMounted, watch } from 'vue';
import { toast } from 'vue-sonner';
import ModerationStats from '@/components/ModerationStats.vue';
import ModerationFilters from '@/components/ModerationFilters.vue';
import ModerationList from '@/components/ModerationList.vue';
import ModerationDetailModal from '@/components/ModerationDetailModal.vue';
import type { ModerationTweet } from '@/components/ModerationCard.vue';
import type { ModerationStatsData } from '@/components/ModerationStats.vue';
import type { ModerationFiltersData } from '@/components/ModerationFilters.vue';
import {
  getModerationStats,
  listModerationContent,
  moderatePost
} from '@/services';
import type { ModerationStatsVM } from '@/types/moderation';

const { t } = useAppLocale();

const statsData = ref<ModerationStatsData>({
  pending: 0,
  approved: 0,
  rejected: 0,
  flagged: 0,
  todayProcessed: 0,
  avgProcessTime: ''
});

const rawStats = ref<ModerationStatsVM>({
  pending: 0,
  approved: 0,
  rejected: 0,
  flagged: 0,
  todayProcessed: 0,
  avgProcessMinutes: 0,
  openReports: 0,
  appealSuccessRate: 0
});

const localizedStatsData = computed<ModerationStatsData>(() => ({
  ...statsData.value,
  avgProcessTime: t('moderation.stats.minutes', {
    count: rawStats.value.avgProcessMinutes
  })
}));

const filters = ref<ModerationFiltersData>({
  search: '',
  status: 'all',
  reportReason: 'all',
  dateRange: 'all',
  sortBy: 'newest'
});

const tweets = ref<ModerationTweet[]>([]);
const loading = ref(false);
const hasNext = ref(false);
const page = ref(1);
const pageSize = 10;

const detailModalOpen = ref(false);
const selectedTweet = ref<ModerationTweet | null>(null);

async function loadStats(): Promise<void> {
  rawStats.value = await getModerationStats();
  statsData.value = {
    pending: rawStats.value.pending,
    approved: rawStats.value.approved,
    rejected: rawStats.value.rejected,
    flagged: rawStats.value.flagged,
    todayProcessed: rawStats.value.todayProcessed,
    avgProcessTime: ''
  };
}

async function loadContent(reset = true): Promise<void> {
  loading.value = true;
  try {
    const nextPage = reset ? 1 : page.value + 1;
    const result = await listModerationContent({
      q: filters.value.search,
      status: filters.value.status,
      reason: filters.value.reportReason,
      dateRange: filters.value.dateRange,
      sort: filters.value.sortBy,
      page: nextPage,
      pageSize
    });
    tweets.value = reset
      ? result.items
      : [...tweets.value, ...result.items];
    page.value = result.page;
    hasNext.value = result.hasNext;
  } catch (error) {
    toast.error(t('moderation.feedback.loadFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    loading.value = false;
  }
}

async function refreshAll(): Promise<void> {
  await Promise.all([loadStats(), loadContent(true)]);
}

async function applyPostAction(
  id: number,
  action: 'approve' | 'reject' | 'flag',
  note = ''
): Promise<void> {
  try {
    const updated = await moderatePost(id, action, note);
    const index = tweets.value.findIndex(tweet => tweet.id === id);
    if (index >= 0) tweets.value[index] = updated;
    if (selectedTweet.value?.id === id) {
      selectedTweet.value = updated;
    }
    await loadStats();
    toast.success(
      t(
        action === 'approve'
          ? 'moderation.feedback.approved'
          : action === 'reject'
            ? 'moderation.feedback.rejected'
            : 'moderation.feedback.flagged'
      )
    );
  } catch (error) {
    toast.error(t('moderation.feedback.actionFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  }
}

const handleApprove = (id: number) => {
  void applyPostAction(id, 'approve');
};

const handleReject = (id: number) => {
  void applyPostAction(id, 'reject');
};

const handleFlag = (id: number) => {
  void applyPostAction(id, 'flag');
};

const handleViewDetail = (tweet: ModerationTweet) => {
  selectedTweet.value = tweet;
  detailModalOpen.value = true;
};

const handleDetailApprove = (id: number, note: string) => {
  void applyPostAction(id, 'approve', note);
};

const handleDetailReject = (id: number, note: string) => {
  void applyPostAction(id, 'reject', note);
};

const handleDetailFlag = (id: number, note: string) => {
  void applyPostAction(id, 'flag', note);
};

const handleRefresh = () => {
  void refreshAll().then(() => {
    toast.success(t('moderation.feedback.refreshed'));
  });
};

const handleLoadMore = () => {
  if (!hasNext.value) {
    toast.info(t('moderation.feedback.noMore'));
    return;
  }
  void loadContent(false);
};

const handleResetFilters = () => {
  toast.info(t('moderation.feedback.filtersReset'));
};

watch(
  filters,
  () => {
    void loadContent(true);
  },
  { deep: true }
);

onMounted(() => {
  void refreshAll();
});
</script>

<template>
  <div class="space-y-6">
    <!-- 统计面板 -->
    <ModerationStats :stats="localizedStatsData" />

    <!-- 过滤器 -->
    <ModerationFilters
      v-model="filters"
      @reset="handleResetFilters"
    />

    <!-- 审核列表 -->
    <ModerationList
      :tweets="tweets"
      :loading="loading"
      @approve="handleApprove"
      @reject="handleReject"
      @flag="handleFlag"
      @view-detail="handleViewDetail"
      @refresh="handleRefresh"
      @load-more="handleLoadMore"
    />

    <!-- 详情弹窗 -->
    <ModerationDetailModal
      v-model:open="detailModalOpen"
      :tweet="selectedTweet"
      @approve="handleDetailApprove"
      @reject="handleDetailReject"
      @flag="handleDetailFlag"
    />
  </div>
</template>
