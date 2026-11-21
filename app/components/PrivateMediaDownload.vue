<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { Download, Loader2 } from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import { apiFetch } from '@/composables/useApi';
import { authQueueFor } from '@/services/auth-request-queue';
import { privateMediaContentPath } from '@/utils/private-media';
import { browserSaveFilePicker, savePrivateStream } from '@/utils/private-media-save';

const props = defineProps<{ mediaId: number; fileName: string }>();
const { t } = useAppLocale();
const app = useNuxtApp();
const auth = authQueueFor(app);
const busy = ref(false);
let active: AbortController | null = null;
let unsubscribe: (() => void) | undefined;

function cancelDownload() {
  active?.abort();
  active = null;
  busy.value = false;
}

async function download() {
  const path = privateMediaContentPath(props.mediaId);
  if (!path || busy.value || auth.isIdentityChanging) return;
  const job = new AbortController();
  const revision = auth.revision;
  const safeName = props.fileName.replace(/[<>:"\\/|?*\x00-\x1f\x7f]/g, '_').trim().replace(/[. ]+$/, '');
  const filename = safeName || `attachment-${props.mediaId}`;
  active = job;
  busy.value = true;
  try {
    const pick = browserSaveFilePicker();
    if (pick) {
      await savePrivateStream(pick, filename, () => app.runWithContext(() => apiFetch<unknown, 'stream'>(path, {
        responseType: 'stream',
        headers: { Accept: 'application/octet-stream, application/json' },
        cache: 'no-store',
        redirect: 'error',
        signal: job.signal,
        async onResponse({ response }) {
          const binary = response.headers.get('content-type')?.split(';', 1)[0]?.trim().toLowerCase() === 'application/octet-stream';
          if (response.status !== 200 || !binary || !response.body) {
            await response.body?.cancel();
            // Preserve the normal authentication retry on HTTP errors.
            if (response.ok) throw new Error('Unexpected attachment response');
          }
        },
      })), job.signal);
      return;
    }
    const file = await app.runWithContext(() => apiFetch<Blob, 'blob'>(path, {
      responseType: 'blob',
      headers: { Accept: 'application/octet-stream, application/json' },
      cache: 'no-store',
      redirect: 'error',
      signal: job.signal
    }));
    if (active !== job || auth.revision !== revision || job.signal.aborted) return;
    if (!(file instanceof Blob) || file.type !== 'application/octet-stream') {
      throw new Error('Unexpected attachment response');
    }
    const url = URL.createObjectURL(file);
    const link = document.createElement('a');
    link.href = url;
    link.download = filename;
    document.body.append(link);
    try { link.click(); }
    finally {
      link.remove();
      window.setTimeout(() => URL.revokeObjectURL(url), 1000);
    }
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError') return;
    if (active === job && auth.revision === revision && !job.signal.aborted) {
      toast.error(t('media.privateDownloadFailed'));
    }
  } finally {
    if (active === job) cancelDownload();
  }
}

onMounted(() => { unsubscribe = auth.subscribe(cancelDownload); });
watch(() => props.mediaId, cancelDownload, { flush: 'sync' });
onBeforeUnmount(() => {
  unsubscribe?.();
  cancelDownload();
});
</script>

<template>
  <button
    type="button"
    class="inline-flex min-w-0 items-center gap-2 rounded-md border border-border/60 bg-background px-3 py-2 text-sm hover:bg-accent disabled:opacity-60"
    @click.stop="busy ? cancelDownload() : download()"
  >
    <Loader2 v-if="busy" class="size-4 shrink-0 animate-spin" aria-hidden="true" />
    <Download v-else class="size-4 shrink-0" aria-hidden="true" />
    <span class="truncate">{{ busy ? t('media.cancelPrivateDownload') : fileName || t('media.privateDownload') }}</span>
    <span v-if="fileName && !busy" class="sr-only">{{ t('media.privateDownload') }}</span>
  </button>
</template>
