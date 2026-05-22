<script setup lang="ts">
import { ref, onMounted } from 'vue';
import {
  Inbox,
  Loader2,
  Monitor,
  RefreshCw,
  ShieldOff,
  Smartphone
} from 'lucide-vue-next';
import {
  v2ListSessions,
  v2RevokeOtherSessions,
  v2RevokeSession,
  type SessionVM
} from '@/services';
import { Button } from '@/components/ui/button';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow
} from '@/components/ui/table';
import { toast } from 'vue-sonner';

const { t } = useAppLocale();

const PILL_BASE =
  'inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-medium';

const loading = ref(false);
const sessions = ref<SessionVM[]>([]);

async function load(): Promise<void> {
  loading.value = true;
  try {
    const result = await v2ListSessions();
    sessions.value = result.items;
  } catch {
    toast.error(t('account.active.feedback.loadFailed'));
  } finally {
    loading.value = false;
  }
}

async function revoke(id: string): Promise<void> {
  try {
    await v2RevokeSession(id);
    toast.success(t('account.active.feedback.revoked'));
    await load();
  } catch {
    toast.error(t('account.active.feedback.operationFailed'));
  }
}

async function revokeOthers(): Promise<void> {
  try {
    await v2RevokeOtherSessions();
    toast.success(t('account.active.feedback.othersRevoked'));
    await load();
  } catch {
    toast.error(t('account.active.feedback.operationFailed'));
  }
}

function isMobileDevice(info: string): boolean {
  const lower = (info || '').toLowerCase();
  return (
    lower.includes('mobile') ||
    lower.includes('android') ||
    lower.includes('iphone') ||
    lower.includes('ipad')
  );
}

onMounted(load);
</script>

<template>
  <div class="grid gap-4">
    <section
      class="grid gap-4 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
    >
      <header
        class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"
      >
        <div class="flex items-start gap-3">
          <span
            class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-sky-500/10 text-sky-600 dark:text-sky-400"
          >
            <Monitor class="h-4 w-4" />
          </span>
          <div class="min-w-0 grid gap-0.5">
            <h2 class="text-lg font-semibold tracking-tight">
              {{ t('account.active.title') }}
            </h2>
            <p class="text-xs text-muted-foreground">
              {{ t('account.active.description') }}
            </p>
          </div>
        </div>
        <div class="flex flex-col gap-2 sm:flex-row">
          <Button
            variant="outline"
            class="h-9 rounded-md shadow-xs"
            :disabled="loading"
            @click="load()"
          >
            <Loader2 v-if="loading" class="h-3.5 w-3.5 animate-spin" />
            <RefreshCw v-else class="h-3.5 w-3.5" />
            {{ t('common.refresh') }}
          </Button>
          <Button
            variant="destructive"
            class="h-9 rounded-md shadow-xs"
            :disabled="loading || !sessions.length"
            @click="revokeOthers()"
          >
            <ShieldOff class="h-3.5 w-3.5" />
            {{ t('account.active.revokeOthers') }}
          </Button>
        </div>
      </header>
    </section>

    <div
      v-if="!sessions.length"
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

    <section
      v-else
      class="mobile-scroll-safe rounded-xl border border-border/60 bg-card shadow-none"
    >
      <Table class="min-w-[760px]">
        <TableHeader>
          <TableRow class="border-border/60 bg-muted/20 hover:bg-muted/30">
            <TableHead class="h-9 text-[11px] uppercase tracking-wider text-muted-foreground">
              {{ t('account.active.thisDevice') }}
            </TableHead>
            <TableHead class="h-9 text-[11px] uppercase tracking-wider text-muted-foreground">
              {{ t('account.active.description') }}
            </TableHead>
            <TableHead class="h-9 text-[11px] uppercase tracking-wider text-muted-foreground">
              Session
            </TableHead>
            <TableHead class="h-9 text-right text-[11px] uppercase tracking-wider text-muted-foreground">
              {{ t('account.active.revoke') }}
            </TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          <TableRow
            v-for="s in sessions"
            :key="s.id"
            class="border-border/60 align-top"
            :class="s.current ? 'bg-primary/5' : ''"
          >
            <TableCell>
              <span
                :class="
                  s.current
                    ? `${PILL_BASE} border-emerald-200/60 bg-emerald-100/60 text-emerald-700 dark:border-emerald-900/40 dark:bg-emerald-950/40 dark:text-emerald-300`
                    : `${PILL_BASE} border-border/60 bg-muted/40 text-muted-foreground`
                "
              >
                {{
                  s.current
                    ? t('account.active.thisDevice')
                    : t('account.active.otherDevice')
                }}
              </span>
            </TableCell>
            <TableCell>
              <div class="flex items-start gap-3">
                <span
                  class="mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-md bg-muted/50 text-muted-foreground"
                >
                  <Smartphone
                    v-if="isMobileDevice(s.deviceInfo)"
                    class="h-3.5 w-3.5"
                  />
                  <Monitor v-else class="h-3.5 w-3.5" />
                </span>
                <div class="grid gap-0.5">
                  <div class="text-sm font-medium">
                    {{ s.deviceInfo }}
                  </div>
                  <div class="font-mono text-[11px] text-muted-foreground">
                    {{ s.ipAddress }}
                  </div>
                  <div class="font-mono text-[11px] tabular-nums text-muted-foreground">
                    {{ new Date(s.lastAccessedAt).toLocaleString() }}
                  </div>
                </div>
              </div>
            </TableCell>
            <TableCell
              class="max-w-[18rem] truncate font-mono text-xs text-muted-foreground"
            >
              {{ s.id }}
            </TableCell>
            <TableCell class="text-right">
              <Button
                size="sm"
                variant="outline"
                class="h-8 rounded-md shadow-xs"
                :disabled="s.current || loading"
                @click="revoke(s.id)"
              >
                {{ t('account.active.revoke') }}
              </Button>
            </TableCell>
          </TableRow>
        </TableBody>
      </Table>
    </section>
  </div>
</template>
