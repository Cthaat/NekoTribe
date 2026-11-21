<script setup lang="ts">
import { onMounted, onUnmounted, ref, watch, computed } from 'vue';
import { useNuxtApp } from '#app';
import { authQueueFor } from '@/services/auth-request-queue';
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
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Textarea } from '@/components/ui/textarea';
import ModerationAdvicePanel from '@/components/ModerationAdvicePanel.vue';
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
const queue = authQueueFor(useNuxtApp());
let owner = queue.revision;
let disposed = false;
const expired = ref(queue.isIdentityChanging);
const changing = ref(queue.isIdentityChanging);
const current = (revision = owner) => !disposed && !expired.value &&
  !queue.isIdentityChanging && queue.revision === revision && owner === revision;

const reports = ref<ModerationReportVM[]>([]);
const appeals = ref<ModerationAppealVM[]>([]);
const loading = ref(false);
const page = ref(1);
const hasNext = ref(false);
const appealFilter = ref('pending');
const appealPage = ref(1);
const moreAppeals = ref(false);
const appealsLoading = ref(false);
const appealsError = ref(false);
const deciding = ref(false);
const decision = ref<{id: number; status: 'approved' | 'rejected'; revision: number} | null>(null);
const reply = ref('');
const replyTooLong = computed(() => new TextEncoder().encode(reply.value.trim()).length > 2000);
const decisionOpen = computed({
  get: () => decision.value !== null,
  set: (open: boolean) => { if (!open && !deciding.value) closeDecision(); }
});
const pageSize = 20;
const filters = ref({
  status: 'all',
  reason: 'all',
  targetType: 'all'
});

function evidenceHref(value: string | null | undefined): string | undefined {
  if (!value || /[\x00-\x20\x7f\\]/.test(value)) return;
  if (value.startsWith('/') && !value.startsWith('//')) return value;
  if (/^https?:\/\/[^/?#]+/.test(value)) return value;
}

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
  if (!current()) return;
  const revision = owner;
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
    if (!current(revision)) return;
    reports.value = reset
      ? result.items
      : [...reports.value, ...result.items];
    page.value = result.page;
    hasNext.value = result.hasNext;
  } catch (error) {
    if (!current(revision)) return;
    toast.error(t('moderation.feedback.loadFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    if (current(revision)) loading.value = false;
  }
}

async function loadAppeals(reset = true): Promise<void> {
  if (!current() || appealsLoading.value) return;
  const revision = owner;
  const nextPage = reset ? 1 : appealPage.value + 1;
  appealsLoading.value = true;
  appealsError.value = false;
  if (reset) {
    appeals.value = [];
    moreAppeals.value = false;
  }
  try {
    const result = await listModerationAppeals({
      status: appealFilter.value,
      page: nextPage,
      pageSize: 10
    });
    if (!current(revision)) return;
    appeals.value = reset ? result.items : [...appeals.value, ...result.items];
    appealPage.value = result.page;
    moreAppeals.value = result.hasNext;
  } catch (error) {
    if (!current(revision)) return;
    appealsError.value = true;
    toast.error(t('moderation.feedback.loadFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    if (current(revision)) appealsLoading.value = false;
  }
}

async function setReportStatus(
  report: ModerationReportVM,
  status: ModerationReportStatusVM
): Promise<void> {
  if (!current()) return;
  const revision = owner;
  try {
    const updated = await updateModerationReportStatus(report.id, status);
    if (!current(revision)) return;
    const index = reports.value.findIndex(item => item.id === report.id);
    if (index >= 0) reports.value[index] = updated;
    toast.success(t('moderation.feedback.actionSuccess'));
  } catch (error) {
    if (!current(revision)) return;
    toast.error(t('moderation.feedback.actionFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  }
}

function openDecision(
  appeal: ModerationAppealVM,
  status: 'approved' | 'rejected'
): void {
  if (!current() || deciding.value || appealsLoading.value || appeal.status !== 'pending' || !appeals.value.includes(appeal)) return;
  decision.value = {id:appeal.id,status,revision:owner};
  reply.value = '';
}

function closeDecision(): void {
  decision.value = null;
  reply.value = '';
}

async function submitDecision(): Promise<void> {
  const intent = decision.value;
  if (!intent || !current(intent.revision) || deciding.value || replyTooLong.value) return;
  deciding.value = true;
  try {
    await updateModerationAppeal(intent.id, intent.status, reply.value.trim());
    if (!current(intent.revision)) return;
    closeDecision();
    toast.success(t('moderation.feedback.actionSuccess'));
    await loadAppeals();
  } catch (error) {
    if (!current(intent.revision)) return;
    if (error && typeof error === 'object' && 'statusCode' in error && error.statusCode === 409) {
      closeDecision();
      toast.error(t('moderation.appeals.handled'));
      await loadAppeals();
      return;
    }
    toast.error(t('moderation.feedback.actionFailed'), {
      description:
        error instanceof Error ? error.message : undefined
    });
  } finally {
    if (current(intent.revision)) deciding.value = false;
  }
}

function reopen(): void {
  if (queue.isIdentityChanging || disposed) return;
  owner = queue.revision;
  expired.value = false;
  void loadReports();
  void loadAppeals();
}

const stop = queue.subscribe(() => {
  changing.value = queue.isIdentityChanging;
  if (queue.revision === owner && !changing.value) return;
  expired.value = true;
  reports.value = [];
  appeals.value = [];
  loading.value = false;
  appealsLoading.value = false;
  moreAppeals.value = false;
  appealsError.value = false;
  hasNext.value = false;
  deciding.value = false;
  closeDecision();
});
onUnmounted(() => { disposed = true; stop(); });
watch(appealFilter, () => { void loadAppeals(); });

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
  <div v-if="expired" role="status" class="grid gap-3 rounded-xl border border-border/60 bg-card p-5">
    <p>{{ t('account.settings.sessionChanged') }}</p>
    <Button :disabled="changing" class="w-fit" @click="reopen">{{ t('account.settings.reopen') }}</Button>
  </div>
  <div v-else class="grid gap-4">
    <section
      class="grid min-w-0 gap-3 rounded-xl border border-border/60 bg-card p-4 shadow-none sm:flex sm:flex-wrap sm:items-center"
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
        class="grid min-w-0 gap-3 overflow-hidden rounded-xl border border-border/60 bg-card p-5 shadow-none transition-all hover:border-border hover:shadow-md"
      >
        <header class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div class="flex min-w-0 items-start gap-3">
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
          <div class="flex min-w-0 flex-wrap gap-2 sm:justify-end">
            <span :class="priorityPillClass(report.priority)">
              {{ report.priority }}
            </span>
            <span :class="statusPillClass(report.status)">
              {{ report.status }}
            </span>
          </div>
        </header>

        <p class="break-all text-sm leading-relaxed">
          {{ report.description || t('moderation.detail.reportFallback') }}
        </p>

        <a
          v-if="evidenceHref(report.evidenceUrl)"
          :href="evidenceHref(report.evidenceUrl)"
          target="_blank"
          rel="noreferrer"
          class="inline-flex w-fit items-center gap-1.5 text-xs font-medium text-primary underline-offset-4 hover:underline"
        >
          <ExternalLink class="h-3.5 w-3.5" />
          {{ t('moderation.reports.evidence') }}
        </a>

        <ModerationAdvicePanel
          :key="`${report.targetType}:${report.targetId}`"
          :kind="report.targetType"
          :target-id="report.targetId"
        />

        <div class="flex min-w-0 flex-wrap gap-2 border-t border-border/60 pt-3">
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
      class="grid min-w-0 gap-4 overflow-hidden rounded-xl border border-border/60 bg-card p-5 shadow-none"
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
        </div>
      </header>

      <Select v-model="appealFilter" :disabled="appealsLoading || deciding">
        <SelectTrigger class="w-full sm:w-48" :aria-label="t('moderation.reports.status')"><SelectValue /></SelectTrigger>
        <SelectContent>
          <SelectItem v-for="status in ['all', 'pending', 'approved', 'rejected']" :key="status" :value="status">
            {{ t(`moderation.appeals.status.${status}`) }}
          </SelectItem>
        </SelectContent>
      </Select>
      <p v-if="appealsLoading && !appeals.length" role="status" class="text-sm text-muted-foreground">
        {{ t('common.loading') }}
      </p>
      <div v-else-if="appealsError && !appeals.length" role="alert" class="flex items-center gap-2 text-sm">
        {{ t('moderation.feedback.loadFailed') }}
        <Button variant="outline" size="sm" @click="loadAppeals()">{{ t('common.retry') }}</Button>
      </div>
      <div
        v-else-if="appeals.length === 0"
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
          class="grid min-w-0 gap-3 overflow-hidden rounded-lg border border-border/60 bg-card p-4 shadow-xs"
        >
          <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div class="min-w-0">
              <div class="flex min-w-0 items-center gap-2 text-sm font-medium">
                <span class="min-w-0 break-all">{{ appeal.userName }}</span>
                <span class="font-mono text-xs text-muted-foreground">
                  #{{ appeal.statementId }}
                </span>
              </div>
              <p class="mt-0.5 truncate text-xs text-muted-foreground">
                @{{ appeal.username }}
              </p>
            </div>
            <span :class="appealStatusPillClass(appeal.status)">
              {{ t(`moderation.appeals.status.${appeal.status}`) }}
            </span>
          </div>
          <p class="break-all text-sm leading-relaxed">{{ appeal.message }}</p>
          <p v-if="appeal.adminResponse" class="whitespace-pre-wrap break-words text-sm text-muted-foreground">
            {{ t('moderation.appeals.reply') }} · {{ appeal.adminResponse }}
          </p>
          <div v-if="appeal.status === 'pending'" class="flex min-w-0 flex-wrap gap-2 border-t border-border/60 pt-3">
            <Button
              size="sm"
              class="h-8 rounded-md shadow-xs"
              :disabled="deciding || appealsLoading"
              @click="openDecision(appeal, 'approved')"
            >
              {{ t('moderation.appeals.approve') }}
            </Button>
            <Button
              size="sm"
              variant="destructive"
              class="h-8 rounded-md shadow-xs"
              :disabled="deciding || appealsLoading"
              @click="openDecision(appeal, 'rejected')"
            >
              {{ t('moderation.appeals.reject') }}
            </Button>
          </div>
        </div>
      </div>
      <Button v-if="moreAppeals" variant="outline" class="justify-self-start" :disabled="appealsLoading || deciding" @click="loadAppeals(false)">
        {{ t(appealsLoading ? 'common.loading' : 'common.loadMore') }}
      </Button>
    </section>
    <Dialog v-model:open="decisionOpen">
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{{ t(decision?.status === 'approved' ? 'moderation.appeals.approve' : 'moderation.appeals.reject') }}</DialogTitle>
          <DialogDescription>{{ t('moderation.appeals.replyOptional') }}</DialogDescription>
        </DialogHeader>
        <Textarea v-model="reply" :aria-label="t('moderation.appeals.reply')" :disabled="deciding" :aria-invalid="replyTooLong" />
        <p v-if="replyTooLong" role="alert" class="text-sm text-destructive">{{ t('moderation.appeals.replyTooLong') }}</p>
        <DialogFooter>
          <Button variant="outline" :disabled="deciding" @click="closeDecision">{{ t('common.cancel') }}</Button>
          <Button :disabled="deciding || replyTooLong" @click="submitDecision">{{ t(deciding ? 'common.processing' : 'common.confirm') }}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  </div>
</template>
