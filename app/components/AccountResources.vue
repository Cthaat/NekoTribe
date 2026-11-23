<script setup lang="ts">
import { Bot, Download, HardDrive, MessageSquare } from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import { authQueueFor } from '@/services/auth-request-queue';
import { usePreferenceStore } from '@/stores/user';
import {
  v2DownloadAccountExport, v2GetAccountUsage, type AccountExportFormat, type AccountUsage
} from '@/api/v2/users';

const props = defineProps<{ quotaFirst?: boolean }>();
const { t } = useAppLocale();
const app = useNuxtApp();
const auth = authQueueFor(app);
const preferences = usePreferenceStore();
const usage = ref<AccountUsage | null>(null);
const loading = ref(false);
const failed = ref(false);
const downloadFailed = ref(false);
let read: AbortController | undefined;
const activeDownload = shallowRef<AbortController>();
let unsubscribe: (() => void) | undefined;

async function load() {
  read?.abort();
  const job = new AbortController();
  read = job;
  loading.value = true;
  failed.value = false;
  try {
    const result = await app.runWithContext(() => v2GetAccountUsage(job.signal));
    if (!job.signal.aborted) usage.value = result;
  } catch {
    if (!job.signal.aborted) failed.value = true;
  } finally {
    if (read === job) loading.value = false;
  }
}

function reset() {
  read?.abort();
  activeDownload.value?.abort();
  activeDownload.value = undefined;
  usage.value = null;
  failed.value = false;
  downloadFailed.value = false;
  loading.value = false;
}

async function download(format: AccountExportFormat) {
  if (activeDownload.value || auth.isIdentityChanging) return;
  const job = new AbortController();
  activeDownload.value = job;
  downloadFailed.value = false;
  try {
    const file = await app.runWithContext(() => v2DownloadAccountExport(format, job.signal));
    if (job.signal.aborted) return;
    const url = URL.createObjectURL(file);
    const link = document.createElement('a');
    link.href = url;
    link.download = `nekotribe-account.${format === 'json' ? 'json' : 'md'}`;
    link.click();
    window.setTimeout(() => URL.revokeObjectURL(url), 1000);
  } catch {
    if (!job.signal.aborted) downloadFailed.value = true;
  } finally {
    if (activeDownload.value === job) activeDownload.value = undefined;
  }
}

function reloadForSession() {
  reset();
  if (preferences.isLoggedIn && !auth.isIdentityChanging) void load();
}

onMounted(() => {
  unsubscribe = auth.subscribe(reloadForSession);
  reloadForSession();
});
watch(() => preferences.isLoggedIn, reloadForSession);
onBeforeUnmount(() => {
  unsubscribe?.();
  reset();
});

const quota = computed(() => {
  const value = usage.value?.ai_quota;
  if (!value) return '';
  if (value.used_units === null || value.limit_units === null) return t('account.resources.unavailable');
  return t('account.resources.quotaValue', { used: value.used_units, limit: value.limit_units, seconds: value.window_seconds });
});
</script>

<template>
  <section class="space-y-5">
    <h2 class="text-2xl font-semibold">{{ t(props.quotaFirst ? 'account.resources.aiTitle' : 'account.resources.title') }}</h2>
    <p v-if="loading" role="status">{{ t('common.loading') }}</p>
    <div v-else-if="failed" role="alert" class="flex flex-wrap items-center gap-3">
      <p>{{ t('account.resources.loadFailed') }}</p>
      <Button variant="outline" @click="load">{{ t('common.retry') }}</Button>
    </div>
    <dl v-else-if="usage" class="grid gap-3 sm:grid-cols-3">
      <div class="rounded-lg border p-4 space-y-2">
        <Bot class="size-5 text-muted-foreground" aria-hidden="true" />
        <dt class="text-sm text-muted-foreground">{{ t('account.resources.quota') }}</dt>
        <dd class="font-semibold">{{ quota }}</dd>
      </div>
      <div class="rounded-lg border p-4 space-y-2">
        <HardDrive class="size-5 text-muted-foreground" aria-hidden="true" />
        <dt class="text-sm text-muted-foreground">{{ t('account.resources.media') }}</dt>
        <dd class="font-semibold">{{ t('account.resources.mediaValue', usage.media) }}</dd>
      </div>
      <div class="rounded-lg border p-4 space-y-2">
        <MessageSquare class="size-5 text-muted-foreground" aria-hidden="true" />
        <dt class="text-sm text-muted-foreground">{{ t('account.resources.history') }}</dt>
        <dd class="font-semibold">{{ usage.ai_history.conversations }}</dd>
      </div>
    </dl>
    <div v-if="preferences.isLoggedIn" class="rounded-lg border p-4 space-y-3">
      <h3 class="font-semibold">{{ t('account.resources.export') }}</h3>
      <p class="text-sm text-muted-foreground">{{ t('account.resources.exportDescription') }}</p>
      <div class="flex flex-wrap gap-2">
        <Button v-for="format in (['json', 'markdown'] as const)" :key="format" variant="outline"
          :disabled="!!activeDownload" @click="download(format)">
          <Download class="size-4" aria-hidden="true" />{{ format === 'json' ? 'JSON' : 'Markdown' }}
        </Button>
      </div>
      <p v-if="downloadFailed" role="alert" class="text-sm text-destructive">{{ t('account.resources.exportFailed') }}</p>
    </div>
  </section>
</template>
