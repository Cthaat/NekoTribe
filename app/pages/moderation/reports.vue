<script setup lang="ts">
import { onMounted, ref, watch } from 'vue';
import { ExternalLink, Flag } from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
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
  <div class="space-y-4">
    <Card>
      <CardContent class="flex flex-wrap gap-3 p-4">
        <Select v-model="filters.status">
          <SelectTrigger class="w-[160px]">
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
          <SelectTrigger class="w-[160px]">
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
          <SelectTrigger class="w-[160px]">
            <SelectValue :placeholder="t('moderation.reports.targetType')" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">{{ t('common.more') }}</SelectItem>
            <SelectItem value="post">{{ t('moderation.reports.targetPost') }}</SelectItem>
            <SelectItem value="comment">{{ t('moderation.reports.targetComment') }}</SelectItem>
            <SelectItem value="user">{{ t('moderation.reports.targetUser') }}</SelectItem>
          </SelectContent>
        </Select>
        <Button variant="outline" @click="loadReports(true)">
          {{ t('moderation.actions.refresh') }}
        </Button>
      </CardContent>
    </Card>

    <div v-if="loading && reports.length === 0" class="space-y-3">
      <Card v-for="item in 4" :key="item">
        <CardContent class="p-0">
          <Skeleton class="h-24 rounded-lg" />
        </CardContent>
      </Card>
    </div>

    <Card v-else-if="reports.length === 0" class="gap-0 py-0">
      <CardContent class="p-10 text-center text-sm text-muted-foreground">
        {{ t('moderation.reports.empty') }}
      </CardContent>
    </Card>

    <template v-else>
      <Card v-for="report in reports" :key="report.id">
        <CardHeader class="flex flex-row items-start justify-between space-y-0">
        <div>
          <CardTitle class="flex items-center gap-2 text-base">
            <Flag class="h-4 w-4 text-destructive" />
            #{{ report.id }} · {{ t(`moderation.filters.reasons.${report.reason}`) }}
          </CardTitle>
          <div class="mt-1 text-sm text-muted-foreground">
            {{ report.reporterName || t('moderation.reports.anonymous') }}
            · {{ report.targetType }} #{{ report.targetId }}
          </div>
        </div>
        <div class="flex flex-wrap justify-end gap-2">
          <Badge variant="outline">{{ report.priority }}</Badge>
          <Badge>{{ report.status }}</Badge>
        </div>
        </CardHeader>
        <CardContent class="space-y-4">
        <p class="text-sm">
          {{ report.description || t('moderation.detail.reportFallback') }}
        </p>
        <Button
          v-if="report.evidenceUrl"
          as="a"
          :href="report.evidenceUrl"
          target="_blank"
          rel="noreferrer"
          variant="link"
          class="h-auto justify-start p-0"
        >
          <ExternalLink class="h-4 w-4" />
          {{ t('moderation.reports.evidence') }}
        </Button>
        <div class="flex flex-wrap gap-2">
          <Button size="sm" variant="outline" @click="setReportStatus(report, 'in_review')">
            {{ t('moderation.reportStatus.inReview') }}
          </Button>
          <Button size="sm" @click="setReportStatus(report, 'resolved')">
            {{ t('moderation.reportStatus.resolved') }}
          </Button>
          <Button size="sm" variant="secondary" @click="setReportStatus(report, 'dismissed')">
            {{ t('moderation.reportStatus.dismissed') }}
          </Button>
          <Button size="sm" variant="ghost" @click="setReportStatus(report, 'pending')">
            {{ t('moderation.reportStatus.pending') }}
          </Button>
        </div>
        </CardContent>
      </Card>
    </template>

    <div v-if="hasNext" class="flex justify-center">
      <Button variant="outline" :disabled="loading" @click="loadReports(false)">
        {{ loading ? t('common.loading') : t('common.loadMore') }}
      </Button>
    </div>

    <Card>
      <CardHeader>
        <CardTitle>{{ t('moderation.appeals.title') }}</CardTitle>
      </CardHeader>
      <CardContent class="space-y-3">
        <Card
          v-if="appeals.length === 0"
          class="gap-0 py-0"
        >
          <CardContent class="p-6 text-center text-sm text-muted-foreground">
            {{ t('moderation.appeals.empty') }}
          </CardContent>
        </Card>
        <template v-else>
          <div
            v-for="appeal in appeals"
            :key="appeal.id"
            class="rounded-lg border p-4"
          >
            <div class="flex items-start justify-between gap-3">
              <div>
                <div class="font-medium">
                  {{ appeal.userName }} · #{{ appeal.statementId }}
                </div>
                <div class="text-sm text-muted-foreground">
                  @{{ appeal.username }} · {{ appeal.status }}
                </div>
              </div>
              <Badge variant="outline">{{ appeal.status }}</Badge>
            </div>
            <p class="mt-3 text-sm">{{ appeal.message }}</p>
            <div class="mt-3 flex flex-wrap gap-2">
              <Button size="sm" @click="setAppealStatus(appeal, 'approved')">
                {{ t('moderation.appeals.approve') }}
              </Button>
              <Button
                size="sm"
                variant="destructive"
                @click="setAppealStatus(appeal, 'rejected')"
              >
                {{ t('moderation.appeals.reject') }}
              </Button>
            </div>
          </div>
        </template>
      </CardContent>
    </Card>
  </div>
</template>
