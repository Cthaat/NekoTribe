<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, shallowRef, watch } from 'vue';
import { ArrowUpRight } from 'lucide-vue-next';
import { v2GetLinkPreview } from '@/api/v2/link-preview';
import type { V2LinkPreview } from '@/api/v2/link-preview';
import { authQueueFor } from '@/services/auth-request-queue';
import { usePreferenceStore } from '@/stores/user';
import { firstPreviewUrl } from '@/utils/link-preview';
import { firstMarkdownPreviewUrl } from '@/utils/render-post-markdown';

const props = defineProps<{ text?: string; markdown?: string | null }>();
const url = computed(() => props.markdown ? firstMarkdownPreviewUrl(props.markdown) : firstPreviewUrl(props.text ?? ''));
const app = useNuxtApp();
const account = usePreferenceStore();
const auth = authQueueFor(app);
const target = ref<HTMLElement | null>(null);
const seen = ref<string | null>(null);
const revision = ref(auth.revision);
const contentRevision = ref(auth.revision);
const changing = ref(auth.isIdentityChanging);
const preview = shallowRef<V2LinkPreview | null>(null);

onMounted(() => {
  watch([target, url], ([element, current], _, onCleanup) => {
    if (!element || !current) return;
    if (typeof IntersectionObserver === 'undefined') { seen.value = current; return; }
    const observer = new IntersectionObserver(entries => {
      if (!entries.some(entry => entry.isIntersecting)) return;
      seen.value = current;
      observer.disconnect();
    });
    observer.observe(element);
    onCleanup(() => observer.disconnect());
  }, { immediate: true, flush: 'post' });
});

const unsubscribe = import.meta.client ? auth.subscribe(() => {
  changing.value = auth.isIdentityChanging;
  revision.value = auth.revision;
}) : undefined;
onBeforeUnmount(() => unsubscribe?.());

watch([() => props.text, () => props.markdown], () => { contentRevision.value = auth.revision; }, { flush: 'sync' });
watch([url, seen, () => account.isLoggedIn, revision, changing, contentRevision], ([current, visible, loggedIn], _, onCleanup) => {
  preview.value = null;
  if (!current || current !== visible || !loggedIn || auth.isIdentityChanging || contentRevision.value !== auth.revision) return;
  const request = new AbortController();
  const identity = auth.revision;
  onCleanup(() => request.abort());
  void app.runWithContext(() => v2GetLinkPreview(current, request.signal)).then(result => {
    if (!request.signal.aborted && auth.revision === identity) preview.value = result;
  }).catch(() => {});
}, { flush: 'sync' });
</script>

<template>
  <div v-if="url && account.isLoggedIn" ref="target" :class="preview ? 'mt-2' : 'h-px'">
    <a
      v-if="preview" :href="preview.url" target="_blank" rel="noopener noreferrer"
      class="bento-tile group/link-preview flex min-w-0 items-start gap-3 px-3.5 py-2.5 text-left transition-colors hover:bg-accent focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
      @click.stop>
      <span class="min-w-0 flex-1">
        <span class="block truncate text-xs text-muted-foreground">{{ preview.site_name }}</span>
        <span class="block break-words text-sm font-medium leading-snug text-foreground">{{ preview.title }}</span>
        <span v-if="preview.description" class="mt-0.5 block line-clamp-2 break-words text-xs text-muted-foreground">
          {{ preview.description }}
        </span>
      </span>
      <ArrowUpRight aria-hidden="true" class="mt-0.5 size-4 shrink-0 text-muted-foreground group-hover/link-preview:text-foreground" />
    </a>
  </div>
</template>
