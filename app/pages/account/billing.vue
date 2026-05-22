<script setup lang="ts">
import {
  CalendarClock,
  CheckCircle2,
  CreditCard,
  Download,
  FileText,
  Gauge,
  ReceiptText,
  ShieldCheck,
  WalletCards
} from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import { Progress } from '@/components/ui/progress';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow
} from '@/components/ui/table';

const { t } = useAppLocale();

interface InvoiceRow {
  id: string;
  date: string;
  amount: string;
  statusKey: 'paid' | 'pending' | 'failed';
  status: string;
}

const PILL_BASE =
  'inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-medium';

function invoiceStatusClass(status: InvoiceRow['statusKey']): string {
  switch (status) {
    case 'paid':
      return `${PILL_BASE} border-emerald-200/60 bg-emerald-100/60 text-emerald-700 dark:border-emerald-900/40 dark:bg-emerald-950/40 dark:text-emerald-300`;
    case 'failed':
      return `${PILL_BASE} border-rose-200/60 bg-rose-100/60 text-rose-700 dark:border-rose-900/40 dark:bg-rose-950/40 dark:text-rose-300`;
    case 'pending':
    default:
      return `${PILL_BASE} border-amber-200/60 bg-amber-100/60 text-amber-700 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-300`;
  }
}

const invoices = computed<InvoiceRow[]>(() => [
  {
    id: 'NT-2026-005',
    date: '2026-05-18',
    amount: '0.00',
    statusKey: 'pending',
    status: t('account.billing.invoiceStatus.pending')
  },
  {
    id: 'NT-2026-004',
    date: '2026-04-18',
    amount: '0.00',
    statusKey: 'paid',
    status: t('account.billing.invoiceStatus.paid')
  },
  {
    id: 'NT-2026-003',
    date: '2026-03-18',
    amount: '0.00',
    statusKey: 'paid',
    status: t('account.billing.invoiceStatus.paid')
  }
]);
</script>

<template>
  <div class="grid gap-6">
    <section
      class="grid gap-4 lg:grid-cols-[minmax(0,1.25fr)_minmax(320px,0.75fr)]"
    >
      <div
        class="grid gap-5 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
      >
        <header class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div class="flex items-start gap-3">
            <span
              class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-primary/10 text-primary"
            >
              <ReceiptText class="h-4 w-4" />
            </span>
            <div class="min-w-0 grid gap-0.5">
              <span
                :class="[
                  PILL_BASE,
                  'w-fit border-primary/30 bg-primary/10 text-primary'
                ]"
              >
                {{ t('account.billing.badge') }}
              </span>
              <h2 class="mt-1 text-lg font-semibold tracking-tight">
                {{ t('account.billing.title') }}
              </h2>
              <p class="max-w-2xl text-xs leading-relaxed text-muted-foreground">
                {{ t('account.billing.description') }}
              </p>
            </div>
          </div>
          <Button variant="outline" class="h-9 rounded-md shadow-xs">
            <Download class="h-3.5 w-3.5" />
            {{ t('account.billing.actions.export') }}
          </Button>
        </header>

        <div class="grid gap-3 sm:grid-cols-3">
          <div
            class="rounded-lg border border-border/60 bg-muted/20 p-3"
          >
            <div class="flex items-center gap-1.5 text-[11px] uppercase tracking-wider text-muted-foreground">
              <WalletCards class="h-3.5 w-3.5" />
              {{ t('account.billing.summary.plan') }}
            </div>
            <div class="mt-1.5 text-base font-semibold tracking-tight">
              {{ t('account.billing.summary.free') }}
            </div>
          </div>
          <div
            class="rounded-lg border border-border/60 bg-muted/20 p-3"
          >
            <div class="flex items-center gap-1.5 text-[11px] uppercase tracking-wider text-muted-foreground">
              <CalendarClock class="h-3.5 w-3.5" />
              {{ t('account.billing.summary.nextDate') }}
            </div>
            <div class="mt-1.5 font-mono text-base font-semibold tabular-nums">
              2026-06-18
            </div>
          </div>
          <div
            class="rounded-lg border border-border/60 bg-muted/20 p-3"
          >
            <div class="flex items-center gap-1.5 text-[11px] uppercase tracking-wider text-muted-foreground">
              <ShieldCheck class="h-3.5 w-3.5" />
              {{ t('account.billing.summary.status') }}
            </div>
            <div class="mt-1.5 flex items-center gap-1.5 text-base font-semibold tracking-tight">
              <CheckCircle2 class="h-4 w-4 text-emerald-500 dark:text-emerald-400" />
              {{ t('account.billing.summary.normal') }}
            </div>
          </div>
        </div>
      </div>

      <div
        class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
      >
        <header class="flex items-start gap-3">
          <span
            class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-violet-500/10 text-violet-600 dark:text-violet-400"
          >
            <CreditCard class="h-4 w-4" />
          </span>
          <div class="min-w-0 grid gap-0.5">
            <h3 class="text-base font-semibold tracking-tight">
              {{ t('account.billing.payment.title') }}
            </h3>
            <p class="text-xs text-muted-foreground">
              {{ t('account.billing.payment.description') }}
            </p>
          </div>
        </header>

        <div
          class="flex items-center justify-between gap-3 rounded-lg border border-border/60 bg-muted/20 p-3"
        >
          <div class="min-w-0">
            <p class="text-sm font-medium">
              {{ t('account.billing.payment.method') }}
            </p>
            <p class="mt-0.5 text-xs text-muted-foreground">
              {{ t('account.billing.payment.empty') }}
            </p>
          </div>
          <span
            :class="[
              PILL_BASE,
              'border-border/60 bg-muted/40 text-muted-foreground'
            ]"
          >
            {{ t('account.billing.payment.notSet') }}
          </span>
        </div>
        <Button class="h-9 w-full rounded-md shadow-xs">
          {{ t('account.billing.actions.addPayment') }}
        </Button>
      </div>
    </section>

    <section
      class="grid gap-4 lg:grid-cols-[minmax(320px,0.8fr)_minmax(0,1.2fr)]"
    >
      <div
        class="grid gap-5 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
      >
        <header class="flex items-start gap-3">
          <span
            class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-sky-500/10 text-sky-600 dark:text-sky-400"
          >
            <Gauge class="h-4 w-4" />
          </span>
          <div class="min-w-0 grid gap-0.5">
            <h3 class="text-base font-semibold tracking-tight">
              {{ t('account.billing.usage.title') }}
            </h3>
            <p class="text-xs text-muted-foreground">
              {{ t('account.billing.usage.description') }}
            </p>
          </div>
        </header>

        <div class="grid gap-4">
          <div class="grid gap-1.5">
            <div class="flex items-center justify-between text-xs">
              <span class="font-medium">
                {{ t('account.billing.usage.ai') }}
              </span>
              <span class="font-mono tabular-nums text-muted-foreground">
                68 / 100
              </span>
            </div>
            <Progress :model-value="68" class="h-1.5" />
          </div>
          <div class="grid gap-1.5">
            <div class="flex items-center justify-between text-xs">
              <span class="font-medium">
                {{ t('account.billing.usage.storage') }}
              </span>
              <span class="font-mono tabular-nums text-muted-foreground">
                4.2 / 10 GB
              </span>
            </div>
            <Progress :model-value="42" class="h-1.5" />
          </div>
        </div>

        <div class="h-px w-full bg-border/60" />
        <p class="text-xs leading-relaxed text-muted-foreground">
          {{ t('account.billing.usage.note') }}
        </p>
      </div>

      <div
        class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
      >
        <header class="flex items-start gap-3">
          <span
            class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-emerald-500/10 text-emerald-600 dark:text-emerald-400"
          >
            <FileText class="h-4 w-4" />
          </span>
          <div class="min-w-0 grid gap-0.5">
            <h3 class="text-base font-semibold tracking-tight">
              {{ t('account.billing.invoices.title') }}
            </h3>
            <p class="text-xs text-muted-foreground">
              {{ t('account.billing.invoices.description') }}
            </p>
          </div>
        </header>

        <div class="overflow-hidden rounded-lg border border-border/60">
          <Table>
            <TableHeader>
              <TableRow class="border-border/60 bg-muted/20 hover:bg-muted/30">
                <TableHead class="h-9 text-[11px] uppercase tracking-wider text-muted-foreground">
                  {{ t('account.billing.invoices.id') }}
                </TableHead>
                <TableHead class="h-9 text-[11px] uppercase tracking-wider text-muted-foreground">
                  {{ t('account.billing.invoices.date') }}
                </TableHead>
                <TableHead class="h-9 text-[11px] uppercase tracking-wider text-muted-foreground">
                  {{ t('account.billing.invoices.amount') }}
                </TableHead>
                <TableHead class="h-9 text-[11px] uppercase tracking-wider text-muted-foreground">
                  {{ t('account.billing.invoices.status') }}
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              <TableRow
                v-for="invoice in invoices"
                :key="invoice.id"
                class="border-border/60"
              >
                <TableCell class="font-mono text-xs font-medium">
                  {{ invoice.id }}
                </TableCell>
                <TableCell class="font-mono text-xs tabular-nums text-muted-foreground">
                  {{ invoice.date }}
                </TableCell>
                <TableCell class="font-mono text-xs tabular-nums">
                  {{ invoice.amount }}
                </TableCell>
                <TableCell>
                  <span :class="invoiceStatusClass(invoice.statusKey)">
                    {{ invoice.status }}
                  </span>
                </TableCell>
              </TableRow>
            </TableBody>
          </Table>
        </div>
      </div>
    </section>
  </div>
</template>
