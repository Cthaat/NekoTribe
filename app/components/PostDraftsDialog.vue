<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { v2DeletePostDraft, v2ListPostDrafts, v2SavePostDraft, v2SchedulePostDraft, v2UnschedulePostDraft } from '@/api/v2/post-drafts';
import type { V2PostDraft } from '@/types/v2';
import { markdownExcerpt, validMarkdownBody } from '@/utils/post-markdown';
import { usePreferenceStore } from '@/stores/user';

const props = defineProps<{ groupId: number }>();
const open = defineModel<boolean>('open', {required:true});
const emit = defineEmits<{ resume: [draft: V2PostDraft]; removed: [id: number] }>();
const { t, locale } = useAppLocale();
const app = useNuxtApp();
const preferences = usePreferenceStore();
const items = ref<V2PostDraft[]>([]);
const next = ref<number | null>(null);
const at = ref('');
const scheduling = ref<number | null>(null);
const includeGroups = ref(false);
const editing = ref<number | null>(null);
const editContent = ref('');
const busy = ref(false);
const failed = ref(false);
let request: AbortController | undefined;

const groupScope = computed(() => props.groupId === 0 && includeGroups.value ? null : props.groupId);
const timeToSchedule = computed(() => {
  const time = new Date(at.value);
  return Number.isFinite(time.getTime()) && time.getTime() > Date.now() ? time.toISOString() : null;
});

function dateLabel(value: string): string {
  return new Date(value).toLocaleString(locale.value,{dateStyle:'medium',timeStyle:'short'});
}

function reset() {
  request?.abort();
  request = undefined;
  items.value = [];
  next.value = scheduling.value = null;
  editing.value = null;
  editContent.value = '';
  at.value = '';
  failed.value = busy.value = false;
}

async function run(work: (signal: AbortSignal, current: () => boolean) => Promise<void>) {
  if (!open.value || busy.value || !preferences.isLoggedIn) return;
  const revision = preferences.authRevision();
  const group = groupScope.value;
  const controller = new AbortController();
  request = controller;
  busy.value = true;
  failed.value = false;
  const current = () => request === controller && open.value && group === groupScope.value && preferences.isAuthCurrent(revision);
  try { await app.runWithContext(() => work(controller.signal, current)); }
  catch { if (current()) failed.value = true; }
  finally { if (request === controller) { request = undefined; busy.value = false; } }
}

function load(more = false) {
  return run(async (signal,current) => {
    const group = groupScope.value;
    const page = await v2ListPostDrafts(group,more ? next.value : null,signal);
    if (!current()) return;
    if (group !== null && page.items.some(draft => (draft.payload.group_id ?? 0) !== group)) throw new Error('Invalid draft scope');
    items.value = more ? [...items.value,...page.items] : page.items;
    next.value = page.next_before_id;
  });
}

function restore(draft: V2PostDraft) {
  if (busy.value || draft.status === 'published') return;
  if ((draft.payload.group_id ?? 0) !== props.groupId) {
    editing.value = draft.draft_id;
    editContent.value = draft.payload.markdown ?? draft.payload.content;
    scheduling.value = null;
    return;
  }
  emit('resume',draft);
  open.value = false;
}

function saveOtherGroupDraft(draft: V2PostDraft) {
  return run(async (signal,current) => {
    const markdown = draft.payload.markdown === undefined ? undefined : editContent.value;
    const content = markdown === undefined ? editContent.value : markdownExcerpt(markdown);
    const result = await v2SavePostDraft({...draft.payload,content,markdown},draft.draft_id,signal);
    if (!current()) return;
    items.value = items.value.map(item => item.draft_id === draft.draft_id ? result : item);
    editing.value = null;
  });
}

function openSchedule(id: number) {
  editing.value = null;
  scheduling.value = id;
  at.value = '';
}

function updateSchedule(draft: V2PostDraft, date: string | null) {
  return run(async (signal,current) => {
    const result = date ? await v2SchedulePostDraft(draft.draft_id,date,signal) : await v2UnschedulePostDraft(draft.draft_id,signal);
    if (!current()) return;
    items.value = items.value.map(item => item.draft_id === draft.draft_id ? result : item);
    scheduling.value = null;
  });
}

function remove(draft: V2PostDraft) {
  if (!globalThis.confirm(t('post.drafts.confirmDelete'))) return;
  return run(async (signal,current) => {
    await v2DeletePostDraft(draft.draft_id,signal);
    if (!current()) return;
    items.value = items.value.filter(item => item.draft_id !== draft.draft_id);
    emit('removed',draft.draft_id);
  });
}

watch([open, groupScope], ([visible]) => {
  reset();
  if (visible) void load();
});
watch([() => preferences.preferences.user.id,() => preferences.preferences.authSession?.sessionId], () => {
  reset();
  includeGroups.value = false;
  open.value = false;
}, {flush:'sync'});
onBeforeUnmount(reset);
</script>

<template>
  <Dialog v-model:open="open">
    <DialogContent class="gap-4 sm:max-w-lg">
      <DialogHeader>
        <DialogTitle>{{ t('post.drafts.title') }}</DialogTitle>
        <DialogDescription>{{ t('post.drafts.description') }}</DialogDescription>
      </DialogHeader>
      <label v-if="groupId === 0" class="flex w-fit items-center gap-2 text-sm">
        <input v-model="includeGroups" type="checkbox" />{{ t('post.drafts.includeGroups') }}
      </label>
      <div class="max-h-[55vh] space-y-2 overflow-y-auto">
        <p v-if="busy && !items.length" class="text-sm text-muted-foreground" role="status">{{ t('common.loading') }}</p>
        <p v-else-if="!items.length && !failed" class="text-sm text-muted-foreground">{{ t('post.drafts.empty') }}</p>
        <article v-for="draft in items" :key="draft.draft_id" class="space-y-2 rounded-lg border p-3">
          <div class="flex flex-wrap items-center justify-between gap-1">
            <p class="text-sm font-medium">
              {{ t(`post.drafts.status.${draft.status}`) }}
              <span v-if="groupId === 0 && draft.payload.group_id" class="text-muted-foreground"> · {{ t('post.drafts.groupPost') }}</span>
            </p>
            <p class="text-xs text-muted-foreground">{{ dateLabel(draft.updated_at) }}</p>
          </div>
          <p class="line-clamp-2 whitespace-pre-wrap break-words text-sm">{{ draft.payload.content.trim() || t('post.drafts.emptyContent') }}</p>
          <p v-if="draft.scheduled_at && draft.status === 'scheduled'" class="text-xs text-muted-foreground">
            {{ t('post.drafts.publishAt', {time:dateLabel(draft.scheduled_at)}) }}
          </p>
          <p v-if="draft.last_error" role="status" class="text-xs text-destructive">{{ t(`post.drafts.error.${draft.last_error}`) }}</p>
          <div class="flex flex-wrap gap-1">
            <Button v-if="draft.status !== 'published'" type="button" size="sm" variant="outline" :disabled="busy" @click="restore(draft)">{{ t('post.drafts.resume') }}</Button>
            <Button v-if="draft.status !== 'published'" type="button" size="sm" variant="ghost" :disabled="busy" @click="openSchedule(draft.draft_id)">{{ t('post.drafts.schedule') }}</Button>
            <Button v-if="draft.status === 'scheduled'" type="button" size="sm" variant="ghost" :disabled="busy" @click="updateSchedule(draft,null)">{{ t('post.drafts.unschedule') }}</Button>
            <Button type="button" size="sm" variant="ghost" :disabled="busy" @click="remove(draft)">{{ t('common.delete') }}</Button>
          </div>
          <div v-if="scheduling === draft.draft_id" class="flex flex-wrap items-end gap-2">
            <label class="flex min-w-48 flex-1 flex-col gap-1 text-xs">
              {{ t('post.drafts.localDate') }}
              <Input v-model="at" type="datetime-local" :disabled="busy" />
            </label>
            <Button type="button" size="sm" :disabled="busy || !timeToSchedule" @click="timeToSchedule && updateSchedule(draft,timeToSchedule)">{{ t('post.drafts.confirmSchedule') }}</Button>
            <Button type="button" size="sm" variant="ghost" :disabled="busy" @click="scheduling = null">{{ t('common.cancel') }}</Button>
          </div>
          <div v-if="editing === draft.draft_id" class="space-y-2">
            <Textarea v-model="editContent" :aria-label="t('post.drafts.editing')" :disabled="busy" rows="4" />
            <Button type="button" size="sm" :disabled="busy || (draft.payload.markdown !== undefined && !validMarkdownBody(editContent))"
              @click="saveOtherGroupDraft(draft)">{{ t('post.drafts.save') }}</Button>
            <Button type="button" size="sm" variant="ghost" :disabled="busy" @click="editing = null">{{ t('common.cancel') }}</Button>
          </div>
        </article>
      </div>
      <p v-if="failed" class="text-sm text-destructive" role="alert">{{ t('post.drafts.retry') }}</p>
      <div class="flex flex-wrap justify-end gap-2">
        <Button v-if="next !== null" type="button" variant="outline" :disabled="busy" @click="load(true)">{{ t('post.drafts.more') }}</Button>
        <Button type="button" variant="outline" :disabled="busy" @click="load()">{{ t('common.refresh') }}</Button>
      </div>
    </DialogContent>
  </Dialog>
</template>
