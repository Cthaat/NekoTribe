<script setup lang="ts">
import { ref } from 'vue';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import type { ChatMessageFilters } from '@/api/v2/chat';

defineProps<{ senders: { id: number; label: string }[] }>();
const emit = defineEmits<{ search: [filters: ChatMessageFilters | null] }>();
const { t } = useAppLocale();
const keyword = ref('');
const sender = ref<number | ''>('');
const start = ref('');
const end = ref('');
const error = ref<'rangeError' | 'keywordError' | null>(null);

function submit() {
  const q = keyword.value.trim();
  error.value = start.value && end.value && start.value > end.value ? 'rangeError'
    : new TextEncoder().encode(q).length > 400 ? 'keywordError' : null;
  if (error.value) return;
  const from = start.value ? new Date(`${start.value}T00:00:00`) : null;
  const through = end.value ? new Date(`${end.value}T00:00:00`) : null;
  if (through) through.setDate(through.getDate() + 1);
  const filters: ChatMessageFilters = {
    q: q || undefined,
    sender_id: sender.value || undefined,
    start_at: from?.toISOString(),
    end_at: through?.toISOString(),
  };
  emit('search', Object.values(filters).some(Boolean) ? filters : null);
}

function clear() {
  keyword.value = start.value = end.value = '';
  sender.value = '';
  error.value = null;
  emit('search', null);
}
</script>

<template>
  <form class="grid grid-cols-[repeat(auto-fit,minmax(8rem,1fr))] items-end gap-2 border-b bg-background px-4 py-3" @submit.prevent="submit">
    <label class="min-w-0 space-y-1 text-xs font-medium">
      {{ t('chat.messageSearch.keyword') }}
      <Input v-model="keyword" :placeholder="t('chat.searchPlaceholder')" maxlength="400" />
    </label>
    <label class="min-w-0 space-y-1 text-xs font-medium">
      {{ t('chat.messageSearch.sender') }}
      <select v-model="sender" class="h-9 w-full rounded-md border border-input bg-background px-2 text-sm">
        <option value="">{{ t('chat.messageSearch.allSenders') }}</option>
        <option v-for="option in senders" :key="option.id" :value="option.id">{{ option.label }}</option>
      </select>
    </label>
    <label class="min-w-0 space-y-1 text-xs font-medium">
      {{ t('chat.messageSearch.start') }}
      <Input v-model="start" type="date" />
    </label>
    <label class="min-w-0 space-y-1 text-xs font-medium">
      {{ t('chat.messageSearch.end') }}
      <Input v-model="end" type="date" />
    </label>
    <p v-if="error" class="col-span-full text-xs text-destructive" role="alert">{{ t(`chat.messageSearch.${error}`) }}</p>
    <div class="col-span-full flex justify-end gap-2">
      <Button type="button" size="sm" variant="ghost" @click="clear">{{ t('chat.messageSearch.clear') }}</Button>
      <Button type="submit" size="sm">{{ t('chat.messageSearch.submit') }}</Button>
    </div>
  </form>
</template>
