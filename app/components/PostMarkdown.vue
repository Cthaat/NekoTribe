<script setup lang="ts">
import { computed } from 'vue';
import { renderPostMarkdown } from '@/utils/render-post-markdown';

const props = defineProps<{ source: string }>();
const html = computed(() => renderPostMarkdown(props.source));
</script>

<template>
  <div class="post-markdown min-w-0 break-words text-sm leading-relaxed text-foreground" @click.stop v-html="html" />
</template>

<style scoped>
.post-markdown :deep(p), .post-markdown :deep(blockquote), .post-markdown :deep(ul), .post-markdown :deep(ol) { margin-block: .55rem; }
.post-markdown :deep(h1), .post-markdown :deep(h2), .post-markdown :deep(h3), .post-markdown :deep(h4),
.post-markdown :deep(h5), .post-markdown :deep(h6) { margin-block: .8rem .25rem; font-weight: 700; }
.post-markdown :deep(h1) { font-size: 1.3em; }
.post-markdown :deep(h2) { font-size: 1.18em; }
.post-markdown :deep(ul) { list-style: disc; padding-inline-start: 1.4rem; }
.post-markdown :deep(ol) { list-style: decimal; padding-inline-start: 1.4rem; }
.post-markdown :deep(a) { text-decoration: underline; color: var(--primary); }
.post-markdown :deep(blockquote) { border-inline-start: 3px solid var(--border); padding-inline-start: .8rem; color: var(--muted-foreground); }
.post-markdown :deep(pre) { background: var(--muted); border-radius: .5rem; padding: .75rem; overflow-x: auto; }
.post-markdown :deep(:not(pre) > code) { background: var(--muted); border-radius: .25rem; padding-inline: .2rem; }
.post-markdown :deep(th), .post-markdown :deep(td) { border: 1px solid var(--border); padding: .3rem .55rem; }
.post-markdown :deep(table) { display: block; max-width: 100%; overflow-x: auto; border-collapse: collapse; }
.post-markdown :deep(.hljs-keyword), .post-markdown :deep(.hljs-literal) { color: var(--primary); font-weight: 650; }
.post-markdown :deep(.hljs-string), .post-markdown :deep(.hljs-number) { color: var(--chart-2); }
.post-markdown :deep(.hljs-comment) { color: var(--muted-foreground); }
.post-markdown :deep(.hljs-title), .post-markdown :deep(.hljs-type) { color: var(--chart-1); }
</style>
