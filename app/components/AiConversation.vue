<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue';
import { Bot, History, Loader2, Plus, Send, Trash2 } from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { writingApi } from '@/api/v2/ai-writing';
import { knowledgeApi } from '@/api/v2/ai-knowledge';
import { createWritingController, initialWritingState } from '@/services/ai-writing-controller';

const props = defineProps<{ purpose: 'writing' | 'knowledge' }>();
const { t } = useAppLocale();
const localePath = useLocalePath();
const label = (key: string) => t(`${props.purpose === 'knowledge' ? 'aiKnowledge' : 'aiWriting'}.${key}`);
const state = reactive(initialWritingState());
const controller = createWritingController(props.purpose === 'knowledge' ? knowledgeApi : writingApi, state, props.purpose);
const deleteOpen = ref(false);
const lastUser = computed(() => state.messages.at(-1)?.role === 'user');
const errorText = computed(() => state.error ? label(`errors.${state.error}`) : '');
onMounted(() => { void controller.loadHistory(); });
async function confirmDelete() {
  deleteOpen.value = false;
  await controller.remove();
  if (!state.id) await controller.loadHistory();
}
async function submit() {
  await controller.send();
  if (!state.error) await controller.loadHistory();
}
</script>

<template>
  <div class="mx-auto flex max-w-7xl flex-col gap-5 px-3 py-5 sm:px-6 sm:py-8">
    <header class="flex flex-wrap items-start justify-between gap-3">
      <div>
        <div class="flex items-center gap-2 text-primary"><Bot class="h-5 w-5" /><span class="text-sm font-medium">{{ label('eyebrow') }}</span></div>
        <h1 class="mt-1 text-2xl font-semibold tracking-tight">{{ label('title') }}</h1>
        <p class="mt-1 text-sm text-muted-foreground">{{ label('description') }}</p>
      </div>
      <div class="flex gap-2">
        <Button variant="outline" :disabled="state.busy" @click="controller.reset()"><Plus class="mr-2 h-4 w-4" />{{ label('new') }}</Button>
        <Button v-if="state.id" variant="outline" :disabled="state.busy" @click="deleteOpen = true"><Trash2 class="mr-2 h-4 w-4" />{{ t('common.delete') }}</Button>
      </div>
    </header>
    <div class="grid min-w-0 gap-4 lg:grid-cols-[260px_minmax(0,1fr)]">
      <aside class="min-w-0 rounded-xl border bg-card p-4">
        <div class="flex items-center justify-between gap-2"><h2 class="flex items-center gap-2 text-sm font-semibold"><History class="h-4 w-4" />{{ label('history') }}</h2><Button variant="ghost" size="sm" :disabled="state.historyBusy" @click="controller.loadHistory()">{{ t('common.refresh') }}</Button></div>
        <p v-if="!state.history.length && !state.historyBusy" class="py-5 text-sm text-muted-foreground">{{ label('historyEmpty') }}</p>
        <ul class="mt-3 max-h-64 space-y-1 overflow-y-auto lg:max-h-[55vh]">
          <li v-for="item in state.history" :key="item.conversation_id">
            <button type="button" :disabled="state.busy" :aria-current="state.id === item.conversation_id ? 'true' : undefined" class="w-full rounded-lg px-3 py-2 text-left text-sm hover:bg-muted aria-[current=true]:bg-primary/10" @click="controller.select(item.conversation_id)">
              <span class="block truncate font-medium">{{ item.title || label('untitled') }}</span>
              <span class="block truncate text-xs text-muted-foreground">{{ item.updated_at || item.conversation_id }}</span>
            </button>
          </li>
        </ul>
        <Button v-if="state.historyCursor" variant="ghost" size="sm" class="mt-2 w-full" :disabled="state.historyBusy" @click="controller.loadHistory(false)">{{ t('common.loadMore') }}</Button>
      </aside>
      <section class="flex min-h-[32rem] min-w-0 flex-col rounded-xl border bg-card" :aria-label="label('title')">
        <div class="flex-1 space-y-4 overflow-y-auto p-4 sm:p-6" aria-live="polite">
          <div v-if="!state.messages.length" class="flex min-h-48 items-center justify-center text-center text-sm text-muted-foreground">{{ label('empty') }}</div>
          <div v-for="message in state.messages" :key="message.message_id" class="flex" :class="message.role === 'user' ? 'justify-end' : 'justify-start'">
            <div class="max-w-[90%] rounded-2xl px-4 py-3 sm:max-w-[80%]" :class="message.role === 'user' ? 'bg-primary text-primary-foreground' : 'bg-muted'">
              <div class="mb-1 text-xs font-medium opacity-70">{{ message.role === 'user' ? label('you') : label('assistant') }}</div>
              <p class="whitespace-pre-wrap break-words text-sm leading-relaxed">{{ message.content }}</p>
              <div v-if="message.citations?.length" class="mt-3 border-t pt-2 text-xs">
                <p class="mb-1 font-medium">{{ label('sources') }}</p>
                <ul class="space-y-1">
                  <li v-for="source in message.citations" :key="`${source.kind}-${source.id}`">
                    <NuxtLink v-if="source.kind === 'post'" class="underline underline-offset-2" :to="localePath(`/tweet/${source.id}`)">{{ label(source.kind) }} #{{ source.id }}</NuxtLink>
                    <span v-else>{{ label(source.kind) }} #{{ source.id }}</span>
                  </li>
                </ul>
              </div>
            </div>
          </div>
        </div>
        <div class="border-t p-4 sm:p-6">
          <p v-if="state.insufficientEvidence" role="status" class="mb-3 text-sm text-muted-foreground">{{ label('insufficientEvidence') }}</p>
          <p v-if="state.error" role="alert" class="mb-3 text-sm text-destructive">{{ errorText }}</p>
          <div v-if="state.refreshRequired || lastUser" class="mb-3 flex flex-wrap gap-2">
            <Button v-if="state.refreshRequired" variant="outline" size="sm" :disabled="state.busy" @click="controller.retry(false)">{{ label('refreshState') }}</Button>
            <Button v-if="lastUser" variant="outline" size="sm" :disabled="state.busy" @click="controller.retry()">{{ label('retry') }}</Button>
          </div>
          <form class="flex items-end gap-2" @submit.prevent="submit">
            <Textarea v-model="state.draft" :disabled="state.busy || state.refreshRequired" :placeholder="label('placeholder')" :aria-label="label('placeholder')" rows="2" />
            <Button type="submit" :disabled="state.busy || state.refreshRequired || !state.draft.trim()"><Loader2 v-if="state.busy" class="h-4 w-4 animate-spin" /><Send v-else class="h-4 w-4" /><span class="sr-only">{{ label('send') }}</span></Button>
          </form>
        </div>
      </section>
    </div>
    <Dialog v-model:open="deleteOpen">
      <DialogContent><DialogHeader><DialogTitle>{{ label('deleteTitle') }}</DialogTitle><DialogDescription>{{ label('deleteDescription') }}</DialogDescription></DialogHeader><DialogFooter><Button variant="outline" @click="deleteOpen = false">{{ t('common.cancel') }}</Button><Button variant="destructive" @click="confirmDelete">{{ t('common.delete') }}</Button></DialogFooter></DialogContent>
    </Dialog>
  </div>
</template>
