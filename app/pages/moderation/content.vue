<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted, watch } from 'vue';
import { useNuxtApp } from '#app';
import { authQueueFor } from '@/services/auth-request-queue';
import { usePreferenceStore } from '@/stores/user';
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
import { v2BulkModeratePosts } from '@/api/v2/moderation';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Textarea } from '@/components/ui/textarea';

const { t } = useAppLocale();
const queue = authQueueFor(useNuxtApp());
const account = usePreferenceStore();
const owner = queue.revision;
let disposed = false;
let request = 0;
const current = () => !disposed && !queue.isIdentityChanging && queue.revision === owner;

const statsData = ref<ModerationStatsData>({
  pending: 0,
  approved: 0,
  rejected: 0,
  flagged: 0,
  todayProcessed: 0,
  avgProcessTime: '',
  openReports: 0,
  appealSuccessRate: 0
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
  priority: 'all',
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
const applyingAction = ref(false);
const bulkActions = ['approve', 'reject', 'flag', 'remove', 'restore'] as const;
type BulkAction = typeof bulkActions[number];
const selectedIds = ref(new Set<number>());
const bulkOpen = ref(false);
const bulkAction = ref<BulkAction>('flag');
const bulkNote = ref('');
const bulkNoteTooLong = computed(() => new TextEncoder().encode(bulkNote.value.trim()).length > 1000);

function clearBulkSelection(): void {
  selectedIds.value.clear();
  bulkOpen.value = false;
  bulkNote.value = '';
}

function toggleBulkSelection(id: number): void {
  if (!current() || loading.value || applyingAction.value || !tweets.value.some(tweet => tweet.id === id)) return;
  if (selectedIds.value.has(id)) selectedIds.value.delete(id);
  else if (selectedIds.value.size < 100) selectedIds.value.add(id);
}

function openBulkDialog(): void {
  if (!current() || loading.value || applyingAction.value || !selectedIds.value.size) return;
  bulkAction.value = 'flag';
  bulkNote.value = '';
  bulkOpen.value = true;
}

async function submitBulkAction(): Promise<void> {
  if (!current() || loading.value || applyingAction.value || !bulkOpen.value || bulkNoteTooLong.value) return;
  const ids = [...selectedIds.value];
  if (!ids.length) return;
  const note = bulkNote.value.trim();
  applyingAction.value = true;
  try {
    const result = await v2BulkModeratePosts({ post_ids: ids, action: bulkAction.value, ...(note ? { note } : {}) });
    if (!current()) return;
    clearBulkSelection();
    toast.success(t('moderation.bulk.processed', { count: result.processed_count }));
    await Promise.allSettled([loadStats(), loadContent(true)]);
  } catch (error) {
    if (current()) toast.error(t('moderation.feedback.actionFailed'), {
      description: error instanceof Error ? error.message : undefined
    });
  } finally {
    applyingAction.value = false;
  }
}

async function loadStats(): Promise<void> {
  if (!current()) return;
  const data = await getModerationStats();
  if (!current()) return;
  rawStats.value = data;
  statsData.value = {
    pending: rawStats.value.pending,
    approved: rawStats.value.approved,
    rejected: rawStats.value.rejected,
    flagged: rawStats.value.flagged,
    todayProcessed: rawStats.value.todayProcessed,
    avgProcessTime: '',
    openReports: rawStats.value.openReports,
    appealSuccessRate: rawStats.value.appealSuccessRate
  };
}

async function loadContent(reset = true): Promise<void> {
  if (!current() || (!reset && loading.value)) return;
  const revision = ++request;
  if (reset) {
    clearBulkSelection();
    tweets.value = [];
  }
  loading.value = true;
  try {
    const nextPage = reset ? 1 : page.value + 1;
    const result = await listModerationContent({
      q: filters.value.search,
      status: filters.value.status,
      priority: filters.value.priority,
      reason: filters.value.reportReason,
      dateRange: filters.value.dateRange,
      sort: filters.value.sortBy,
      page: nextPage,
      pageSize
    });
    if (!current() || revision !== request) return;
    tweets.value = reset
      ? result.items
      : [...tweets.value, ...result.items];
    page.value = result.page;
    hasNext.value = result.hasNext;
  } catch (error) {
    if (!current() || revision !== request) return;
    toast.error(t('moderation.feedback.loadFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    if (current() && revision === request) loading.value = false;
  }
}

async function refreshAll(): Promise<void> {
  await Promise.all([loadStats(), loadContent(true)]);
}

async function applyPostAction(
  id: number,
  action: 'approve' | 'reject' | 'flag' | 'claim' | 'release',
  note = ''
): Promise<void> {
  if (!current() || applyingAction.value) return;
  applyingAction.value = true;
  try {
    const updated = await moderatePost(id, action, note);
    if (!current()) return;
    if (action === 'claim' || action === 'release') {
      toast.success(t(`moderation.assignment.${action}Done`));
      await Promise.allSettled([loadStats(), loadContent(true)]);
      return;
    }
    selectedIds.value.delete(id);
    const index = tweets.value.findIndex(tweet => tweet.id === id);
    if (index >= 0) tweets.value[index] = updated;
    if (selectedTweet.value?.id === id) {
      selectedTweet.value = updated;
      detailModalOpen.value = false;
    }
    void loadStats().catch(() => {});
    if (!current()) return;
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
    if (!current()) return;
    toast.error(t('moderation.feedback.actionFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
    if ((action === 'claim' || action === 'release') &&
        (error as { statusCode?: number } | null)?.statusCode === 409) {
      await loadContent(true);
    }
  } finally {
    applyingAction.value = false;
  }
}

const handleApprove = (id: number) => {
  void applyPostAction(id, 'approve');
};

const handleReject = (id: number) => {
  const item = tweets.value.find(tweet => tweet.id === id);
  if (current() && item) handleViewDetail(item);
};

const handleFlag = (id: number) => {
  void applyPostAction(id, 'flag');
};

function handleAssignment(id: number, action: 'claim' | 'release'): void {
  const item = tweets.value.find(tweet => tweet.id === id);
  const userId = account.preferences.user.id;
  if (!item || loading.value || !userId || !['pending', 'flagged'].includes(item.status)) return;
  if (action === 'claim' ? item.assignedTo : item.assignedTo?.id !== userId) return;
  void applyPostAction(id, action);
}

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

let unsubscribe: (() => void) | undefined;
onMounted(() => {
  unsubscribe = queue.subscribe(() => {
    if (current()) return;
    request++;
    clearBulkSelection();
    tweets.value = [];
    selectedTweet.value = null;
    detailModalOpen.value = false;
    loading.value = false;
    hasNext.value = false;
    rawStats.value = {
      pending: 0, approved: 0, rejected: 0, flagged: 0, todayProcessed: 0,
      avgProcessMinutes: 0, openReports: 0, appealSuccessRate: 0
    };
    statsData.value = {...rawStats.value,avgProcessTime:''};
  });
  void refreshAll();
});
onUnmounted(() => {
  disposed = true;
  unsubscribe?.();
});
</script>

<template>
  <div class="grid gap-3.5">
    <ModerationStats :stats="localizedStatsData" />

    <ModerationFilters
      v-model="filters"
      @reset="handleResetFilters"
    />

    <ModerationList
      :tweets="tweets"
      :loading="loading"
      :has-next="hasNext"
      :selected-ids="selectedIds"
      :selection-disabled="applyingAction"
      :reviewer-id="account.preferences.user.id"
      @toggle-selection="toggleBulkSelection"
      @assignment="handleAssignment"
      @approve="handleApprove"
      @reject="handleReject"
      @flag="handleFlag"
      @view-detail="handleViewDetail"
      @refresh="handleRefresh"
      @load-more="handleLoadMore"
    >
      <template #selection-actions>
        <Button v-if="selectedIds.size" :disabled="loading || applyingAction" size="sm" @click="openBulkDialog">
          {{ t('moderation.bulk.selected', { count: selectedIds.size }) }}
        </Button>
      </template>
    </ModerationList>

    <Dialog :open="bulkOpen" @update:open="value => { if (!applyingAction) bulkOpen = value }">
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{{ t('moderation.bulk.title') }}</DialogTitle>
          <DialogDescription>{{ t('moderation.bulk.confirm', { count: selectedIds.size }) }}</DialogDescription>
        </DialogHeader>
        <label class="grid gap-2 text-sm">
          {{ t('moderation.bulk.action') }}
          <select v-model="bulkAction" :disabled="applyingAction" class="rounded-md border bg-background px-3 py-2">
            <option v-for="action in bulkActions" :key="action" :value="action">{{ t(`moderation.bulk.${action}`) }}</option>
          </select>
        </label>
        <label class="grid gap-2 text-sm">
          {{ t('moderation.bulk.note') }}
          <Textarea v-model="bulkNote" :disabled="applyingAction" :aria-invalid="bulkNoteTooLong" />
          <span v-if="bulkNoteTooLong" class="text-destructive" role="alert">{{ t('moderation.bulk.noteTooLong') }}</span>
        </label>
        <DialogFooter>
          <Button variant="outline" :disabled="applyingAction" @click="bulkOpen = false">{{ t('common.cancel') }}</Button>
          <Button :disabled="applyingAction || bulkNoteTooLong" @click="submitBulkAction">{{ t('moderation.bulk.title') }}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>

    <ModerationDetailModal
      v-model:open="detailModalOpen"
      :tweet="selectedTweet"
      @approve="handleDetailApprove"
      @reject="handleDetailReject"
      @flag="handleDetailFlag"
    />
  </div>
</template>
