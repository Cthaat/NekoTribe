<script setup lang="ts">
import { v2ListMyGroups } from '@/api/v2/groups';
import type { KnowledgeScope } from '@/api/v2/ai-knowledge';
import type { V2Group } from '@/types/v2';
import { authQueueFor } from '@/services/auth-request-queue';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@/components/ui/select';

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
    <div class="mx-auto flex max-w-[760px] flex-wrap items-center justify-between gap-3 px-3 pt-4 sm:px-6">
      <div
        role="tablist"
        :aria-label="t('aiKnowledge.scope.label')"
        class="inline-flex items-center gap-1 rounded-full bg-secondary p-1"
      >
        <button
          v-for="item in (['public', 'group', 'personal'] as const)"
          :key="item"
          type="button"
          role="tab"
          :aria-selected="scope === item"
          class="rounded-full px-3.5 py-1.5 text-[13px] transition-all duration-200"
          :class="scope === item ? 'bg-card font-semibold text-foreground shadow-xs dark:shadow-none' : 'font-medium text-muted-foreground hover:text-foreground'"
          @click="changeScope(item)"
        >
          {{ t(`aiKnowledge.scope.${item}`) }}
        </button>
      </div>
      <div v-if="scope === 'group'" class="min-w-[180px]">
        <Select
          :model-value="groupId ? String(groupId) : undefined"
          @update:model-value="v => changeScope('group', Number(v) || undefined)"
        >
          <SelectTrigger class="h-9 w-full rounded-full border-0 bg-secondary px-3.5 text-sm shadow-none">
            <SelectValue :placeholder="t('aiKnowledge.scope.chooseGroup')" />
          </SelectTrigger>
          <SelectContent class="rounded-2xl">
            <SelectItem
              v-for="group in groups"
              :key="group.group_id"
              :value="String(group.group_id)"
              class="rounded-xl"
            >
              {{ group.name }}
            </SelectItem>
          </SelectContent>
        </Select>
      </div>
    </div>
    <AiConversation v-if="groupReady" :key="`${scope}:${groupId ?? ''}`" purpose="knowledge"
      :knowledge-scope="scope" :knowledge-group-id="groupId" />
    <p v-else class="mx-auto max-w-[760px] px-4 text-sm text-muted-foreground sm:px-6">{{ t('aiKnowledge.scope.groupRequired') }}</p>
  </div>
</template>
