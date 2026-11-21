<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref, shallowRef } from 'vue';
import { v2ListGroupAuditLogs } from '@/api/v2/groups';
import { Button } from '@/components/ui/button';
import { authQueueFor } from '@/services/auth-request-queue';
import type { V2GroupAuditEntry } from '@/types/v2';

const props = defineProps<{ groupId: number }>();
const { t } = useAppLocale();
const app = useNuxtApp();
const auth = authQueueFor(app);
const items = shallowRef<V2GroupAuditEntry[]>([]);
const page = ref(1);
const hasNext = ref(false);
const loading = ref(false);
const notice = ref<'failed' | 'expired' | null>(null);
let current: AbortController | undefined;
let stopListening: (() => void) | undefined;

function clear() {
  current?.abort();
  current = undefined;
  items.value = [];
  hasNext.value = false;
  loading.value = false;
}

async function load(nextPage: number) {
  if (loading.value || notice.value === 'expired' || auth.isIdentityChanging) return;
  clear();
  const request = new AbortController();
  const revision = auth.revision;
  const stillCurrent = () => current === request && revision === auth.revision;
  current = request;
  loading.value = true;
  notice.value = null;
  page.value = nextPage;
  try {
    const result = await app.runWithContext(() => v2ListGroupAuditLogs(props.groupId, nextPage, request.signal));
    if (!stillCurrent()) return;
    if (result.items.some(item => item.group_id !== props.groupId)) throw Error('Invalid audit scope');
    items.value = result.items;
    hasNext.value = result.meta?.has_next === true;
  } catch {
    if (stillCurrent()) notice.value = 'failed';
  } finally {
    if (stillCurrent()) loading.value = false;
  }
}

onMounted(() => {
  stopListening = auth.subscribe(() => {
    clear();
    notice.value = 'expired';
  });
  void load(1);
});
onBeforeUnmount(() => {
  stopListening?.();
  clear();
});
</script>

<template>
  <div class="grid gap-3">
    <p v-if="loading" role="status">{{ t('groups.audit.loading') }}</p>
    <p v-else-if="notice" role="status">{{ t(`groups.audit.${notice}`) }}</p>
    <p v-else-if="!items.length">{{ t('groups.audit.empty') }}</p>
    <ul v-else class="grid gap-2">
      <li v-for="entry in items" :key="entry.log_id" class="grid gap-1 rounded-md border p-3 text-sm">
        <strong class="break-all">{{ entry.action }}</strong>
        <span>{{ t('groups.audit.actor', { id: entry.actor_id }) }}</span>
        <time :datetime="entry.created_at">{{ entry.created_at }}</time>
        <span v-if="entry.target_user_id != null">{{ t('groups.audit.user', { id: entry.target_user_id }) }}</span>
        <span v-if="entry.target_post_id != null">{{ t('groups.audit.post', { id: entry.target_post_id }) }}</span>
        <span v-if="entry.target_comment_id != null">{{ t('groups.audit.comment', { id: entry.target_comment_id }) }}</span>
        <details v-if="entry.details != null">
          <summary>{{ t('groups.audit.details') }}</summary>
          <pre class="mt-2 whitespace-pre-wrap break-all">{{ typeof entry.details === 'string' ? entry.details : JSON.stringify(entry.details, null, 2) }}</pre>
        </details>
      </li>
    </ul>
    <div v-if="notice !== 'expired'" class="flex flex-wrap gap-2">
      <Button v-if="notice === 'failed'" variant="outline" @click="load(page)">{{ t('groups.audit.retry') }}</Button>
      <Button v-if="page > 1" variant="outline" :disabled="loading" @click="load(page - 1)">{{ t('groups.audit.previous') }}</Button>
      <Button v-if="hasNext" variant="outline" :disabled="loading" @click="load(page + 1)">{{ t('groups.audit.next') }}</Button>
    </div>
  </div>
</template>
