<script setup lang="ts">
import {
  CalendarClock,
  CheckCircle2,
  CreditCard,
  Download,
  FileText,
  ReceiptText,
  ShieldCheck,
  WalletCards
} from 'lucide-vue-next';
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle
} from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Progress } from '@/components/ui/progress';
import { Separator } from '@/components/ui/separator';
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
  status: string;
}

const invoices = computed<InvoiceRow[]>(() => [
  {
    id: 'NT-2026-005',
    date: '2026-05-18',
    amount: '0.00',
    status: t('account.billing.invoiceStatus.pending')
  },
  {
    id: 'NT-2026-004',
    date: '2026-04-18',
    amount: '0.00',
    status: t('account.billing.invoiceStatus.paid')
  },
  {
    id: 'NT-2026-003',
    date: '2026-03-18',
    amount: '0.00',
    status: t('account.billing.invoiceStatus.paid')
  }
]);
</script>

<template>
  <div class="space-y-6">
    <section class="grid gap-4 lg:grid-cols-[minmax(0,1.25fr)_minmax(320px,0.75fr)]">
      <Card>
        <CardHeader>
          <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <Badge variant="secondary" class="mb-3 gap-1.5">
                <ReceiptText class="h-3.5 w-3.5" />
                {{ t('account.billing.badge') }}
              </Badge>
              <CardTitle class="text-2xl">
                {{ t('account.billing.title') }}
              </CardTitle>
              <CardDescription class="mt-2 max-w-2xl leading-6">
                {{ t('account.billing.description') }}
              </CardDescription>
            </div>
            <Button variant="outline" class="gap-2">
              <Download class="h-4 w-4" />
              {{ t('account.billing.actions.export') }}
            </Button>
          </div>
        </CardHeader>
        <CardContent>
          <div class="grid gap-3 sm:grid-cols-3">
            <div class="rounded-lg border bg-muted/30 p-4">
              <div class="flex items-center gap-2 text-sm text-muted-foreground">
                <WalletCards class="h-4 w-4" />
                {{ t('account.billing.summary.plan') }}
              </div>
              <div class="mt-3 text-xl font-semibold">
                {{ t('account.billing.summary.free') }}
              </div>
            </div>
            <div class="rounded-lg border bg-muted/30 p-4">
              <div class="flex items-center gap-2 text-sm text-muted-foreground">
                <CalendarClock class="h-4 w-4" />
                {{ t('account.billing.summary.nextDate') }}
              </div>
              <div class="mt-3 text-xl font-semibold">
                2026-06-18
              </div>
            </div>
            <div class="rounded-lg border bg-muted/30 p-4">
              <div class="flex items-center gap-2 text-sm text-muted-foreground">
                <ShieldCheck class="h-4 w-4" />
                {{ t('account.billing.summary.status') }}
              </div>
              <div class="mt-3 flex items-center gap-2 text-xl font-semibold">
                <CheckCircle2 class="h-5 w-5 text-primary" />
                {{ t('account.billing.summary.normal') }}
              </div>
            </div>
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle class="flex items-center gap-2">
            <CreditCard class="h-5 w-5 text-primary" />
            {{ t('account.billing.payment.title') }}
          </CardTitle>
          <CardDescription>
            {{ t('account.billing.payment.description') }}
          </CardDescription>
        </CardHeader>
        <CardContent class="space-y-4">
          <div class="rounded-lg border bg-muted/30 p-4">
            <div class="flex items-center justify-between gap-3">
              <div>
                <p class="font-medium">
                  {{ t('account.billing.payment.method') }}
                </p>
                <p class="mt-1 text-sm text-muted-foreground">
                  {{ t('account.billing.payment.empty') }}
                </p>
              </div>
              <Badge variant="outline">
                {{ t('account.billing.payment.notSet') }}
              </Badge>
            </div>
          </div>
          <Button class="w-full">
            {{ t('account.billing.actions.addPayment') }}
          </Button>
        </CardContent>
      </Card>
    </section>

    <section class="grid gap-4 lg:grid-cols-[minmax(320px,0.8fr)_minmax(0,1.2fr)]">
      <Card>
        <CardHeader>
          <CardTitle>{{ t('account.billing.usage.title') }}</CardTitle>
          <CardDescription>
            {{ t('account.billing.usage.description') }}
          </CardDescription>
        </CardHeader>
        <CardContent class="space-y-5">
          <div class="space-y-2">
            <div class="flex items-center justify-between text-sm">
              <span>{{ t('account.billing.usage.ai') }}</span>
              <span class="text-muted-foreground">68 / 100</span>
            </div>
            <Progress :model-value="68" />
          </div>
          <div class="space-y-2">
            <div class="flex items-center justify-between text-sm">
              <span>{{ t('account.billing.usage.storage') }}</span>
              <span class="text-muted-foreground">4.2 / 10 GB</span>
            </div>
            <Progress :model-value="42" />
          </div>
          <Separator />
          <p class="text-sm leading-6 text-muted-foreground">
            {{ t('account.billing.usage.note') }}
          </p>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle class="flex items-center gap-2">
            <FileText class="h-5 w-5 text-primary" />
            {{ t('account.billing.invoices.title') }}
          </CardTitle>
          <CardDescription>
            {{ t('account.billing.invoices.description') }}
          </CardDescription>
        </CardHeader>
        <CardContent>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>{{ t('account.billing.invoices.id') }}</TableHead>
                <TableHead>{{ t('account.billing.invoices.date') }}</TableHead>
                <TableHead>{{ t('account.billing.invoices.amount') }}</TableHead>
                <TableHead>{{ t('account.billing.invoices.status') }}</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              <TableRow v-for="invoice in invoices" :key="invoice.id">
                <TableCell class="font-medium">
                  {{ invoice.id }}
                </TableCell>
                <TableCell>{{ invoice.date }}</TableCell>
                <TableCell>{{ invoice.amount }}</TableCell>
                <TableCell>
                  <Badge variant="secondary">
                    {{ invoice.status }}
                  </Badge>
                </TableCell>
              </TableRow>
            </TableBody>
          </Table>
        </CardContent>
      </Card>
    </section>
  </div>
</template>
