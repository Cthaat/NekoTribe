<script setup lang="ts">
import { onMounted, ref, watch, computed } from 'vue';
import {
  ExternalLink,
  Filter,
  Flag,
  Inbox,
  Loader2,
  MessageSquareWarning,
  RefreshCw
} from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@/components/ui/select';
import {
  listModerationAppeals,
  listModerationReports,
  updateModerationAppeal,
  updateModerationReportStatus
} from '@/services';
import type {
  ModerationAppealVM,
  ModerationReportStatusVM,
  ModerationReportVM
} from '@/types/moderation';

const { t } = useAppLocale();

const reports = ref<ModerationReportVM[]>([]);
const appeals = ref<ModerationAppealVM[]>([]);
const loading = ref(false);
const page = ref(1);
const hasNext = ref(false);
const pageSize = 20;
const filters = ref({
  status: 'all',
  reason: 'all',
  targetType: 'all'
});

const PILL_BASE =
  'inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-medium';

function priorityPillClass(priority: string): string {
  switch (priority) {
    case 'urgent':
    case 'high':
      return `${PILL_BASE} border-rose-200/60 bg-rose-100/60 text-rose-700 dark:border-rose-900/40 dark:bg-rose-950/40 dark:text-rose-300`;
    case 'medium':
      return `${PILL_BASE} border-amber-200/60 bg-amber-100/60 text-amber-700 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-300`;
    default:
      return `${PILL_BASE} border-border/60 bg-muted/40 text-muted-foreground`;
  }
}

function statusPillClass(status: string): string {
  switch (status) {
    case 'resolved':
      return `${PILL_BASE} border-emerald-200/60 bg-emerald-100/60 text-emerald-700 dark:border-emerald-900/40 dark:bg-emerald-950/40 dark:text-emerald-300`;
    case 'in_review':
      return `${PILL_BASE} border-sky-200/60 bg-sky-100/60 text-sky-700 dark:border-sky-900/40 dark:bg-sky-950/40 dark:text-sky-300`;
    case 'dismissed':
      return `${PILL_BASE} border-border/60 bg-muted/40 text-muted-foreground`;
    case 'pending':
    default:
      return `${PILL_BASE} border-amber-200/60 bg-amber-100/60 text-amber-700 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-300`;
  }
}

function appealStatusPillClass(status: string): string {
  switch (status) {
    case 'approved':
      return `${PILL_BASE} border-emerald-200/60 bg-emerald-100/60 text-emerald-700 dark:border-emerald-900/40 dark:bg-emerald-950/40 dark:text-emerald-300`;
    case 'rejected':
      return `${PILL_BASE} border-rose-200/60 bg-rose-100/60 text-rose-700 dark:border-rose-900/40 dark:bg-rose-950/40 dark:text-rose-300`;
    default:
      return `${PILL_BASE} border-amber-200/60 bg-amber-100/60 text-amber-700 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-300`;
  }
}

async function loadReports(reset = true): Promise<void> {
  loading.value = true;
  try {
    const nextPage = reset ? 1 : page.value + 1;
    const result = await listModerationReports({
      status: filters.value.status,
      reason: filters.value.reason,
      targetType: filters.value.targetType,
      page: nextPage,
      pageSize
    });
    reports.value = reset
      ? result.items
      : [...reports.value, ...result.items];
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

async function loadAppeals(): Promise<void> {
  try {
    const result = await listModerationAppeals({
      status: 'all',
      page: 1,
      pageSize: 10
    });
    appeals.value = result.items;
  } catch (error) {
    toast.error(t('moderation.feedback.loadFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  }
}

async function setReportStatus(
  report: ModerationReportVM,
  status: ModerationReportStatusVM
): Promise<void> {
  try {
    const updated = await updateModerationReportStatus(report.id, status);
    const index = reports.value.findIndex(item => item.id === report.id);
    if (index >= 0) reports.value[index] = updated;
    toast.success(t('moderation.feedback.actionSuccess'));
  } catch (error) {
    toast.error(t('moderation.feedback.actionFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  }
}

async function setAppealStatus(
  appeal: ModerationAppealVM,
  status: 'approved' | 'rejected'
): Promise<void> {
  try {
    const updated = await updateModerationAppeal(
      appeal.id,
      status,
      t('moderation.appeals.defaultResponse')
    );
    const index = appeals.value.findIndex(item => item.id === appeal.id);
    if (index >= 0) appeals.value[index] = updated;
    toast.success(t('moderation.feedback.actionSuccess'));
  } catch (error) {
    toast.error(t('moderation.feedback.actionFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  }
}

watch(
  filters,
  () => {
    void loadReports(true);
  },
  { deep: true }
);

onMounted(() => {
  void loadReports(true);
  void loadAppeals();
});
</script>

<template>
  <div class="grid gap-4">
    <section
      class="grid gap-3 rounded-xl border border-border/60 bg-card p-4 shadow-none sm:flex sm:flex-wrap sm:items-center"
    >
      <div class="flex items-center gap-2 text-xs font-medium text-muted-foreground sm:mr-2">
        <Filter class="h-3.5 w-3.5" />
        <span class="uppercase tracking-wider">
          {{ t('moderation.filters.title') }}
        </span>
      </div>
      <Select v-model="filters.status">
        <SelectTrigger class="h-9 w-full rounded-md shadow-xs sm:w-[160px]">
          <SelectValue :placeholder="t('moderation.reports.status')" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">{{ t('moderation.status.all') }}</SelectItem>
          <SelectItem value="pending">{{ t('moderation.reportStatus.pending') }}</SelectItem>
          <SelectItem value="in_review">{{ t('moderation.reportStatus.inReview') }}</SelectItem>
          <SelectItem value="resolved">{{ t('moderation.reportStatus.resolved') }}</SelectItem>
          <SelectItem value="dismissed">{{ t('moderation.reportStatus.dismissed') }}</SelectItem>
        </SelectContent>
      </Select>
      <Select v-model="filters.reason">
        <SelectTrigger class="h-9 w-full rounded-md shadow-xs sm:w-[160px]">
          <SelectValue :placeholder="t('moderation.filters.reportReasonPlaceholder')" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">{{ t('moderation.filters.reasons.all') }}</SelectItem>
          <SelectItem value="spam">{{ t('moderation.filters.reasons.spam') }}</SelectItem>
          <SelectItem value="harassment">{{ t('moderation.filters.reasons.harassment') }}</SelectItem>
          <SelectItem value="hate">{{ t('moderation.filters.reasons.hate') }}</SelectItem>
          <SelectItem value="violence">{{ t('moderation.filters.reasons.violence') }}</SelectItem>
          <SelectItem value="adult">{{ t('moderation.filters.reasons.adult') }}</SelectItem>
          <SelectItem value="misinformation">{{ t('moderation.filters.reasons.misinformation') }}</SelectItem>
          <SelectItem value="copyright">{{ t('moderation.filters.reasons.copyright') }}</SelectItem>
          <SelectItem value="other">{{ t('moderation.filters.reasons.other') }}</SelectItem>
        </SelectContent>
      </Select>
      <Select v-model="filters.targetType">
        <SelectTrigger class="h-9 w-full rounded-md shadow-xs sm:w-[160px]">
          <SelectValue :placeholder="t('moderation.reports.targetType')" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">{{ t('common.more') }}</SelectItem>
          <SelectItem value="post">{{ t('moderation.reports.targetPost') }}</SelectItem>
          <SelectItem value="comment">{{ t('moderation.reports.targetComment') }}</SelectItem>
          <SelectItem value="user">{{ t('moderation.reports.targetUser') }}</SelectItem>
        </SelectContent>
      </Select>
      <Button
        variant="outline"
        class="h-9 w-full rounded-md shadow-xs sm:ml-auto sm:w-auto"
        @click="loadReports(true)"
      >
        <RefreshCw class="h-3.5 w-3.5" />
        {{ t('moderation.actions.refresh') }}
      </Button>
    </section>

    <div v-if="loading && reports.length === 0" class="grid gap-3">
      <div
        v-for="item in 4"
        :key="item"
        class="rounded-xl border border-border/60 bg-card p-5 shadow-none"
      >
        <Skeleton class="h-24 rounded-lg" />
      </div>
    </div>

    <div
      v-else-if="reports.length === 0"
      class="flex flex-col items-center justify-center gap-2 rounded-xl border border-dashed border-border/60 bg-muted/10 py-12 text-center"
    >
      <span
        class="flex h-12 w-12 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
      >
        <Inbox class="h-5 w-5 text-muted-foreground" />
      </span>
      <p class="text-sm text-muted-foreground">
        {{ t('moderation.reports.empty') }}
      </p>
    </div>

    <template v-else>
      <article
        v-for="report in reports"
        :key="report.id"
        class="grid gap-3 rounded-xl border border-border/60 bg-card p-5 shadow-none transition-all hover:border-border hover:shadow-md"
      >
        <header class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div class="flex items-start gap-3">
            <span
              class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-rose-500/10 text-rose-600 dark:text-rose-400"
            >
              <Flag class="h-4 w-4" />
            </span>
            <div class="min-w-0">
              <h3 class="flex min-w-0 items-center gap-2 text-base font-semibold tracking-tight">
                <span class="font-mono text-xs text-muted-foreground">#{{ report.id }}</span>
                <span class="truncate">
                  {{ t(`moderation.filters.reasons.${report.reason}`) }}
                </span>
              </h3>
              <p class="mt-0.5 truncate text-xs text-muted-foreground">
                {{ report.reporterName || t('moderation.reports.anonymous') }}
                <span class="mx-1">·</span>
                <span class="font-mono">{{ report.targetType }} #{{ report.targetId }}</span>
              </p>
            </div>
          </div>
          <div class="flex flex-wrap gap-2 sm:justify-end">
            <span :class="priorityPillClass(report.priority)">
              {{ report.priority }}
            </span>
            <span :class="statusPillClass(report.status)">
              {{ report.status }}
            </span>
          </div>
        </header>

        <p class="text-sm leading-relaxed">
          {{ report.description || t('moderation.detail.reportFallback') }}
        </p>

        <a
          v-if="report.evidenceUrl"
          :href="report.evidenceUrl"
          target="_blank"
          rel="noreferrer"
          class="inline-flex w-fit items-center gap-1.5 text-xs font-medium text-primary underline-offset-4 hover:underline"
        >
          <ExternalLink class="h-3.5 w-3.5" />
          {{ t('moderation.reports.evidence') }}
        </a>

        <div class="flex flex-wrap gap-2 border-t border-border/60 pt-3">
          <Button
            size="sm"
            variant="outline"
            class="h-8 rounded-md shadow-xs"
            @click="setReportStatus(report, 'in_review')"
          >
            {{ t('moderation.reportStatus.inReview') }}
          </Button>
          <Button
            size="sm"
            class="h-8 rounded-md shadow-xs"
            @click="setReportStatus(report, 'resolved')"
          >
            {{ t('moderation.reportStatus.resolved') }}
          </Button>
          <Button
            size="sm"
            variant="secondary"
            class="h-8 rounded-md shadow-xs"
            @click="setReportStatus(report, 'dismissed')"
          >
            {{ t('moderation.reportStatus.dismissed') }}
          </Button>
          <Button
            size="sm"
            variant="ghost"
            class="h-8 rounded-md"
            @click="setReportStatus(report, 'pending')"
          >
            {{ t('moderation.reportStatus.pending') }}
          </Button>
        </div>
      </article>
    </template>

    <div v-if="hasNext" class="flex justify-center pt-1">
      <Button
        variant="outline"
        class="h-9 rounded-md shadow-xs"
        :disabled="loading"
        @click="loadReports(false)"
      >
        <Loader2 v-if="loading" class="h-3.5 w-3.5 animate-spin" />
        {{ loading ? t('common.loading') : t('common.loadMore') }}
      </Button>
    </div>

    <section
      class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none"
    >
      <header class="flex items-start gap-3">
        <span
          class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-violet-500/10 text-violet-600 dark:text-violet-400"
        >
          <MessageSquareWarning class="h-4 w-4" />
        </span>
        <div class="min-w-0 grid gap-0.5">
          <h2 class="text-lg font-semibold tracking-tight">
            {{ t('moderation.appeals.title') }}
          </h2>
          <p class="text-xs text-muted-foreground">
            {{ t('moderation.appeals.description') }}
          </p>
        </div>
      </header>

      <div
        v-if="appeals.length === 0"
        class="flex flex-col items-center justify-center gap-2 rounded-lg border border-dashed border-border/60 bg-muted/10 py-10 text-center"
      >
        <span
          class="flex h-12 w-12 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
        >
          <Inbox class="h-5 w-5 text-muted-foreground" />
        </span>
        <p class="text-sm text-muted-foreground">
          {{ t('moderation.appeals.empty') }}
        </p>
      </div>

      <div v-else class="grid gap-3">
        <div
          v-for="appeal in appeals"
          :key="appeal.id"
          class="grid gap-3 rounded-lg border border-border/60 bg-card p-4 shadow-xs"
        >
          <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div class="min-w-0">
              <div class="flex items-center gap-2 text-sm font-medium">
                <span>{{ appeal.userName }}</span>
                <span class="font-mono text-xs text-muted-foreground">
                  #{{ appeal.statementId }}
                </span>
              </div>
              <p class="mt-0.5 truncate text-xs text-muted-foreground">
                @{{ appeal.username }}
              </p>
            </div>
            <span :class="appealStatusPillClass(appeal.status)">
              {{ appeal.status }}
            </span>
          </div>
          <p class="text-sm leading-relaxed">{{ appeal.message }}</p>
          <div class="flex flex-wrap gap-2 border-t border-border/60 pt-3">
            <Button
              size="sm"
              class="h-8 rounded-md shadow-xs"
              @click="setAppealStatus(appeal, 'approved')"
            >
              {{ t('moderation.appeals.approve') }}
            </Button>
            <Button
              size="sm"
              variant="destructive"
              class="h-8 rounded-md shadow-xs"
              @click="setAppealStatus(appeal, 'rejected')"
            >
              {{ t('moderation.appeals.reject') }}
            </Button>
          </div>
        </div>
      </div>
    </section>
  </div>
</template>
