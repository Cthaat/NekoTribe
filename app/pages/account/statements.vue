<script setup lang="ts">
import { ref, onMounted, computed } from 'vue';
import {
  AlertTriangle,
  FileWarning,
  Filter,
  Inbox,
  Loader2,
  MessageSquareWarning,
  RefreshCw
} from 'lucide-vue-next';
import {
  v2CreateStatementAppeal,
  v2ListAccountStatements,
  v2PatchAccountStatement,
  type AccountStatementVM
} from '@/services';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import { Textarea } from '@/components/ui/textarea';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow
} from '@/components/ui/table';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle
} from '@/components/ui/dialog';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@/components/ui/select';
import { toast } from 'vue-sonner';

type StatementType =
  | 'info'
  | 'warning'
  | 'strike'
  | 'suspension';
type StatementStatus =
  | 'unread'
  | 'read'
  | 'resolved'
  | 'dismissed'
  | 'appealed';

const { t } = useAppLocale();

const loading = ref(false);
const page = ref(1);
const pageSize = ref(10);
const total = ref(0);
const statusFilter = ref<'all' | StatementStatus>('all');
const typeFilter = ref<'all' | StatementType>('all');
const items = ref<AccountStatementVM[]>([]);

const PILL_BASE =
  'inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-medium';

const statementTypeLabelKeys: Record<StatementType, string> = {
  info: 'account.statements.types.info',
  warning: 'account.statements.types.warning',
  strike: 'account.statements.types.strike',
  suspension: 'account.statements.types.suspension'
};

function getStatementTypeLabel(type: StatementType): string {
  return t(statementTypeLabelKeys[type]);
}

function isStatementType(type: string): type is StatementType {
  return type in statementTypeLabelKeys;
}

function getStatementLabel(type: string): string {
  return isStatementType(type)
    ? getStatementTypeLabel(type)
    : type;
}

function typePillClass(type: string): string {
  switch (type) {
    case 'info':
      return `${PILL_BASE} border-sky-200/60 bg-sky-100/60 text-sky-700 dark:border-sky-900/40 dark:bg-sky-950/40 dark:text-sky-300`;
    case 'warning':
      return `${PILL_BASE} border-amber-200/60 bg-amber-100/60 text-amber-700 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-300`;
    case 'strike':
      return `${PILL_BASE} border-rose-200/60 bg-rose-100/60 text-rose-700 dark:border-rose-900/40 dark:bg-rose-950/40 dark:text-rose-300`;
    case 'suspension':
      return `${PILL_BASE} border-red-200/60 bg-red-100/60 text-red-700 dark:border-red-900/40 dark:bg-red-950/40 dark:text-red-300`;
    default:
      return `${PILL_BASE} border-border/60 bg-muted/40 text-muted-foreground`;
  }
}

function statusPillClass(status: string): string {
  switch (status) {
    case 'unread':
      return `${PILL_BASE} border-primary/30 bg-primary/10 text-primary`;
    case 'read':
      return `${PILL_BASE} border-border/60 bg-muted/40 text-muted-foreground`;
    case 'resolved':
      return `${PILL_BASE} border-emerald-200/60 bg-emerald-100/60 text-emerald-700 dark:border-emerald-900/40 dark:bg-emerald-950/40 dark:text-emerald-300`;
    case 'dismissed':
      return `${PILL_BASE} border-border/60 bg-muted/40 text-muted-foreground`;
    case 'appealed':
      return `${PILL_BASE} border-violet-200/60 bg-violet-100/60 text-violet-700 dark:border-violet-900/40 dark:bg-violet-950/40 dark:text-violet-300`;
    default:
      return `${PILL_BASE} border-border/60 bg-muted/40 text-muted-foreground`;
  }
}

const totalPages = computed(() =>
  Math.max(1, Math.ceil(total.value / pageSize.value))
);

async function load(): Promise<void> {
  loading.value = true;
  try {
    const result = await v2ListAccountStatements({
      page: page.value,
      pageSize: pageSize.value,
      status:
        statusFilter.value === 'all'
          ? undefined
          : statusFilter.value,
      type:
        typeFilter.value === 'all'
          ? undefined
          : typeFilter.value
    });
    items.value = result.items;
    total.value = result.total;
  } catch {
    toast.error(t('common.networkError'));
  } finally {
    loading.value = false;
  }
}

async function actMark(
  id: string,
  action:
    | 'mark_read'
    | 'mark_unread'
    | 'resolve'
    | 'dismiss'
): Promise<void> {
  try {
    await v2PatchAccountStatement(Number(id), {
      action
    });
    toast.success(t('account.statements.actionSuccess'));
    await load();
  } catch {
    toast.error(t('account.statements.actionFailed'));
  }
}

const showAppeal = ref<null | string>(null);
const appealMsg = ref('');
const submitting = ref(false);

const appealDialogOpen = computed({
  get: () => showAppeal.value !== null,
  set: (open: boolean) => {
    if (!open) {
      closeAppealDialog();
    }
  }
});

function reloadFromFirstPage(): void {
  page.value = 1;
  load();
}

function closeAppealDialog(): void {
  showAppeal.value = null;
  appealMsg.value = '';
}

async function submitAppeal(id: string): Promise<void> {
  if (
    !appealMsg.value ||
    appealMsg.value.trim().length < 10
  ) {
    toast.error(t('account.statements.appealTooShort'));
    return;
  }
  submitting.value = true;
  try {
    await v2CreateStatementAppeal(Number(id), {
      appealMessage: appealMsg.value.trim()
    });
    toast.success(t('account.statements.appealSubmitted'));
    closeAppealDialog();
    await load();
  } catch {
    toast.error(t('account.statements.appealFailed'));
  } finally {
    submitting.value = false;
  }
}

async function submitCurrentAppeal(): Promise<void> {
  if (!showAppeal.value) return;
  await submitAppeal(showAppeal.value);
}

onMounted(load);
</script>

<template>
  <div class="grid gap-4">
    <section
      class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <header class="flex items-start gap-3">
        <span
          class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-amber-500/10 text-amber-600 dark:text-amber-400"
        >
          <FileWarning class="h-4 w-4" />
        </span>
        <div class="min-w-0 grid gap-0.5">
          <h2 class="text-lg font-semibold tracking-tight">
            {{ t('account.statements.title') }}
          </h2>
          <p class="text-xs text-muted-foreground">
            {{ t('account.statements.description') }}
          </p>
        </div>
      </header>
    </section>

    <section
      class="grid gap-3 rounded-xl border border-border/60 bg-card p-4 shadow-none sm:flex sm:flex-wrap sm:items-center"
    >
      <div class="flex items-center gap-2 text-xs font-medium text-muted-foreground sm:mr-2">
        <Filter class="h-3.5 w-3.5" />
        <span class="uppercase tracking-wider">
          {{ t('moderation.filters.title') }}
        </span>
      </div>
      <Select
        v-model="typeFilter"
        @update:model-value="reloadFromFirstPage"
      >
        <SelectTrigger class="h-9 w-full rounded-md shadow-xs sm:w-[160px]">
          <SelectValue :placeholder="t('account.statements.filters.type')" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">
            {{ t('account.statements.types.all') }}
          </SelectItem>
          <SelectItem value="info">
            {{ t('account.statements.types.info') }}
          </SelectItem>
          <SelectItem value="warning">
            {{ t('account.statements.types.warning') }}
          </SelectItem>
          <SelectItem value="strike">
            {{ t('account.statements.types.strike') }}
          </SelectItem>
          <SelectItem value="suspension">
            {{ t('account.statements.types.suspension') }}
          </SelectItem>
        </SelectContent>
      </Select>
      <Select
        v-model="statusFilter"
        @update:model-value="reloadFromFirstPage"
      >
        <SelectTrigger class="h-9 w-full rounded-md shadow-xs sm:w-[160px]">
          <SelectValue :placeholder="t('account.statements.filters.status')" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">
            {{ t('account.statements.status.all') }}
          </SelectItem>
          <SelectItem value="unread">
            {{ t('account.statements.status.unread') }}
          </SelectItem>
          <SelectItem value="read">
            {{ t('account.statements.status.read') }}
          </SelectItem>
          <SelectItem value="appealed">
            {{ t('account.statements.status.appealed') }}
          </SelectItem>
          <SelectItem value="resolved">
            {{ t('account.statements.status.resolved') }}
          </SelectItem>
          <SelectItem value="dismissed">
            {{ t('account.statements.status.dismissed') }}
          </SelectItem>
        </SelectContent>
      </Select>
      <Button
        variant="outline"
        class="h-9 w-full rounded-md shadow-xs sm:ml-auto sm:w-auto"
        :disabled="loading"
        @click="load()"
      >
        <Loader2 v-if="loading" class="h-3.5 w-3.5 animate-spin" />
        <RefreshCw v-else class="h-3.5 w-3.5" />
        {{ t('common.refresh') }}
      </Button>
    </section>

    <div
      v-if="loading && items.length === 0"
      class="grid gap-3"
    >
      <div
        v-for="item in 3"
        :key="item"
        class="rounded-xl border border-border/60 bg-card p-5 shadow-none"
      >
        <Skeleton class="h-24 rounded-lg" />
      </div>
    </div>

    <div
      v-else-if="items.length === 0"
      class="flex flex-col items-center justify-center gap-2 rounded-xl border border-dashed border-border/60 bg-muted/10 py-12 text-center"
    >
      <span
        class="flex h-12 w-12 items-center justify-center rounded-full bg-muted/60 ring-1 ring-border/60"
      >
        <Inbox class="h-5 w-5 text-muted-foreground" />
      </span>
      <p class="text-sm text-muted-foreground">
        {{ t('common.empty') }}
      </p>
    </div>

    <template v-else>
      <article
        v-for="it in items"
        :key="it.id"
        class="grid gap-3 rounded-xl border border-border/60 bg-card p-5 shadow-none transition-all hover:border-border hover:shadow-md"
      >
        <header class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div class="flex min-w-0 items-start gap-3">
            <span
              :class="[
                'flex h-9 w-9 shrink-0 items-center justify-center rounded-md',
                it.type === 'strike' || it.type === 'suspension'
                  ? 'bg-rose-500/10 text-rose-600 dark:text-rose-400'
                  : it.type === 'warning'
                    ? 'bg-amber-500/10 text-amber-600 dark:text-amber-400'
                    : 'bg-sky-500/10 text-sky-600 dark:text-sky-400'
              ]"
            >
              <AlertTriangle class="h-4 w-4" />
            </span>
            <div class="min-w-0 grid gap-0.5">
              <h3 class="text-base font-semibold tracking-tight">
                {{ it.title }}
              </h3>
              <p class="text-[11px] text-muted-foreground">
                <span class="font-mono tabular-nums">
                  {{ new Date(it.createdAt).toLocaleString() }}
                </span>
                <span v-if="it.policy" class="mx-1">·</span>
                <span v-if="it.policy">{{ it.policy }}</span>
              </p>
            </div>
          </div>
          <div class="flex flex-wrap gap-2 sm:justify-end">
            <span :class="typePillClass(it.type)">
              {{ getStatementLabel(it.type) }}
            </span>
            <span :class="statusPillClass(it.status)">
              {{ t(`account.statements.status.${it.status}`) }}
            </span>
          </div>
        </header>

        <p class="text-sm leading-relaxed text-muted-foreground">
          {{ it.message }}
        </p>

        <div
          v-if="it.appeal"
          class="flex items-center gap-2 rounded-lg border border-amber-200/60 bg-amber-50/60 px-3 py-2 text-xs text-amber-700 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-300"
        >
          <MessageSquareWarning class="h-3.5 w-3.5 shrink-0" />
          <span>
            {{ t('account.statements.appealStatus') }}:
            <span class="font-medium">{{ it.appeal.status }}</span>
          </span>
        </div>

        <div class="flex flex-wrap gap-2 border-t border-border/60 pt-3">
          <Button
            size="sm"
            variant="ghost"
            class="h-8 rounded-md"
            :disabled="loading"
            @click="
              actMark(
                it.id,
                it.status === 'unread'
                  ? 'mark_read'
                  : 'mark_unread'
              )
            "
          >
            {{
              it.status === 'unread'
                ? t('account.statements.actions.markRead')
                : t('account.statements.actions.markUnread')
            }}
          </Button>
          <Button
            size="sm"
            variant="outline"
            class="h-8 rounded-md shadow-xs"
            :disabled="loading"
            @click="actMark(it.id, 'resolve')"
          >
            {{ t('account.statements.actions.resolve') }}
          </Button>
          <Button
            size="sm"
            variant="outline"
            class="h-8 rounded-md shadow-xs"
            :disabled="loading"
            @click="actMark(it.id, 'dismiss')"
          >
            {{ t('account.statements.actions.dismiss') }}
          </Button>
          <Button
            size="sm"
            class="h-8 rounded-md shadow-xs"
            :disabled="loading"
            @click="showAppeal = it.id"
          >
            {{ t('account.statements.actions.appeal') }}
          </Button>
        </div>
      </article>
    </template>

    <div
      v-if="items.length > 0"
      class="flex flex-col gap-3 rounded-xl border border-border/60 bg-card p-4 shadow-none sm:flex-row sm:items-center sm:justify-between"
    >
      <div class="text-xs text-muted-foreground">
        {{
          t('common.pagination', {
            page,
            totalPages,
            total
          })
        }}
      </div>
      <div class="grid grid-cols-2 gap-2 sm:flex sm:items-center">
        <Button
          size="sm"
          variant="outline"
          class="h-8 rounded-md shadow-xs"
          :disabled="loading || page <= 1"
          @click="
            page = Math.max(1, page - 1);
            load();
          "
        >
          {{ t('common.prev') }}
        </Button>
        <Button
          size="sm"
          variant="outline"
          class="h-8 rounded-md shadow-xs"
          :disabled="loading || page >= totalPages"
          @click="
            page = Math.min(totalPages, page + 1);
            load();
          "
        >
          {{ t('common.next') }}
        </Button>
      </div>
    </div>

    <Dialog
      v-if="showAppeal !== null"
      v-model:open="appealDialogOpen"
    >
      <DialogContent
        class="flex max-h-[88vh] max-w-lg flex-col overflow-hidden rounded-xl border-border/60 p-0"
      >
        <DialogHeader
          class="border-b border-border/60 bg-background/60 px-5 py-4 backdrop-blur"
        >
          <DialogTitle class="flex items-center gap-2 text-base font-semibold tracking-tight">
            <span
              class="flex h-7 w-7 items-center justify-center rounded-md bg-violet-500/10 text-violet-600 dark:text-violet-400"
            >
              <MessageSquareWarning class="h-3.5 w-3.5" />
            </span>
            {{ t('account.statements.appealTitle') }}
          </DialogTitle>
          <DialogDescription class="text-xs">
            {{ t('account.statements.appealPlaceholder') }}
          </DialogDescription>
        </DialogHeader>

        <div class="grid gap-2 px-5 py-4">
          <label class="text-xs font-medium">
            {{ t('account.statements.appealTitle') }}
          </label>
          <Textarea
            v-model="appealMsg"
            rows="5"
            class="resize-none shadow-xs"
            :placeholder="t('account.statements.appealPlaceholder')"
          />
        </div>

        <DialogFooter
          class="flex-col gap-2 border-t border-border/60 bg-muted/20 px-5 py-3 sm:flex-row"
        >
          <Button
            variant="ghost"
            class="h-9 w-full rounded-md sm:w-auto"
            @click="closeAppealDialog"
          >
            {{ t('common.cancel') }}
          </Button>
          <Button
            class="h-9 w-full rounded-md shadow-xs sm:w-auto"
            :disabled="submitting"
            @click="submitCurrentAppeal"
          >
            <Loader2 v-if="submitting" class="h-3.5 w-3.5 animate-spin" />
            {{ submitting ? t('common.processing') : t('common.submit') }}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  </div>
</template>
