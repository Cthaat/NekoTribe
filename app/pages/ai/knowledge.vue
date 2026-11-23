<script setup lang="ts">
import { v2ListMyGroups } from '@/api/v2/groups';
import type { KnowledgeScope } from '@/api/v2/ai-knowledge';
import type { V2Group } from '@/types/v2';
import { authQueueFor } from '@/services/auth-request-queue';

definePageMeta({ layout: 'default' });
const { t } = useAppLocale();
const route = useRoute();
const app = useNuxtApp();
const auth = authQueueFor(app);
const groups = ref<V2Group[]>([]);
let unsubscribe: (() => void) | undefined;
let groupRequest: AbortController | undefined;
const scope = computed<KnowledgeScope>(() =>
  route.query.knowledge_scope === 'personal' || route.query.knowledge_scope === 'group'
    ? route.query.knowledge_scope : 'public'
);
const groupId = computed(() => {
  const raw = route.query.group_id;
  const id = typeof raw === 'string' && /^[1-9]\d*$/.test(raw) ? Number(raw) : 0;
  return Number.isSafeInteger(id) && id > 0 ? id : undefined;
});
const groupReady = computed(() => scope.value !== 'group' || groups.value.some(group => group.group_id === groupId.value));

async function loadGroups() {
  groupRequest?.abort();
  groups.value = [];
  if (scope.value !== 'group' || auth.isIdentityChanging) return;
  const current = new AbortController();
  groupRequest = current;
  try {
    const result: V2Group[] = [];
    for (let page = 1; ; page++) {
      const groupPage = await app.runWithContext(() => v2ListMyGroups({page,page_size:50}, current.signal));
      if (current.signal.aborted) return;
      result.push(...groupPage.items.filter(group => group.is_active === 1 && group.membership?.status === 'active'));
      if (!groupPage.meta?.has_next || !groupPage.items.length) break;
    }
    groups.value = result;
  } catch { /* Empty selection is retained when membership is unavailable. */ }
}

function changeScope(next: KnowledgeScope, group?: number) {
  const query = { ...route.query };
  delete query.conversation;
  delete query.group_id;
  if (next === 'public') delete query.knowledge_scope;
  else query.knowledge_scope = next;
  if (next === 'group' && group !== undefined) query.group_id = String(group);
  return navigateTo({ path: route.path, query }, { replace: true });
}

onMounted(() => {
  unsubscribe = auth.subscribe(() => void loadGroups());
  void loadGroups();
});
watch(scope, () => void loadGroups());
onBeforeUnmount(() => {
  unsubscribe?.();
  groupRequest?.abort();
});
</script>

<template>
  <div class="space-y-3">
    <div class="flex flex-wrap gap-3 px-3 pt-3">
      <label class="grid gap-1 text-sm">
        {{ t('aiKnowledge.scope.label') }}
        <select :value="scope" class="rounded-md border bg-background px-3 py-2"
          @change="changeScope(($event.target as HTMLSelectElement).value as KnowledgeScope)">
          <option value="public">{{ t('aiKnowledge.scope.public') }}</option>
          <option value="group">{{ t('aiKnowledge.scope.group') }}</option>
          <option value="personal">{{ t('aiKnowledge.scope.personal') }}</option>
        </select>
      </label>
      <label v-if="scope === 'group'" class="grid gap-1 text-sm">
        {{ t('aiKnowledge.scope.chooseGroup') }}
        <select :value="groupId ?? ''" class="rounded-md border bg-background px-3 py-2"
          @change="changeScope('group', Number(($event.target as HTMLSelectElement).value) || undefined)">
          <option value="">{{ t('aiKnowledge.scope.chooseGroup') }}</option>
          <option v-for="group in groups" :key="group.group_id" :value="group.group_id">{{ group.name }}</option>
        </select>
      </label>
    </div>
    <AiConversation v-if="groupReady" :key="`${scope}:${groupId ?? ''}`" purpose="knowledge"
      :knowledge-scope="scope" :knowledge-group-id="groupId" />
    <p v-else class="px-3 text-sm text-muted-foreground">{{ t('aiKnowledge.scope.groupRequired') }}</p>
  </div>
</template>
