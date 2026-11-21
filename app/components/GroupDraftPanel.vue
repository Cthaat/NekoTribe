<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { createGroupDraftApi, groupDraftKinds } from '@/api/v2/ai-group-draft';
import type { GroupDraftConversation, GroupDraftKind, GroupDraftMessage } from '@/api/v2/ai-group-draft';
import { createGroupPost, getGroup } from '@/services/groups';
import { authQueueFor } from '@/services/auth-request-queue';
import { aiQuotaRetry } from '@/services/ai-quota-notice';
import { getAiAvailability, aiWorkflowAvailability } from '@/api/v2/ai-availability';
import type { AiAvailabilityState, AiSkillSummary } from '@/services/ai-writing-controller';
import AiSkillStatus from '@/components/AiSkillStatus.vue';
import { usePreferenceStore } from '@/stores/user';
import { canUseGroupDrafts } from '@/utils/group-draft-access';

const props = defineProps<{ groupId: number }>();
const { t, locale } = useAppLocale();
const label = (key: string) => t(`aiGroupDraft.${key}`);
const localePath = useLocalePath();
const app = useNuxtApp();
const auth = authQueueFor(app);
const account = usePreferenceStore();
const api = createGroupDraftApi(request => app.runWithContext(request));

const history = ref<GroupDraftConversation[]>([]);
const next = ref<string | null>(null);
const selected = ref<string | null>(null);
const messages = ref<GroupDraftMessage[]>([]);
const kind = ref<GroupDraftKind>('weekly_report');
const skillId = ref<'' | 'group-brief'>('');
const search = ref('');
const searchTerm = computed(() => search.value.trim());
const invalidSearch = computed(() => !searchTerm.value.isWellFormed() ||
  new TextEncoder().encode(searchTerm.value).length > 256 || /[\u0000-\u001f\u007f]/.test(searchTerm.value));
const allowed = ref(false);
const availability = ref<AiAvailabilityState>('loading');
const skill = ref<AiSkillSummary>();
const modelConfigRevision = ref<number>();
const groupName = ref('');
const refreshRequired = ref(false);
const busy = ref<'load'|'page'|'generate'|'review'|'publish'|'delete'|null>(null);
const notice = ref<string | null>(null);
const quotaRetry = ref(0);
const review = ref<GroupDraftMessage | null>(null);
const edited = ref('');
const editedBytes = computed(() => new TextEncoder().encode(edited.value.trim()).length);
const announcement = ref(false);
const published = ref<number | null>(null);
const publicationUnconfirmed = ref(false);
const publicationRetryConfirmed = ref(false);
const publicationNeedsConfirmation = computed(() => publicationUnconfirmed.value && !publicationRetryConfirmed.value);
const closed = ref(false);
const deleteConfirm = ref(false);
let current: AbortController | null = null;
let unsubscribe: (() => void) | undefined;
let forwardOnly = false;
const oldestPageComplete = ref(false);
const hasOlderMessages = computed(() => !oldestPageComplete.value && (messages.value[0]?.sequence ?? 0) > 1);

function clearReview() {
  review.value = null;
  publicationUnconfirmed.value = false;
  publicationRetryConfirmed.value = false;
  deleteConfirm.value = false;
  edited.value = '';
  announcement.value = false;
}
function forgetConversation(id: string) {
  history.value = history.value.filter(item => item.id !== id);
  selected.value = null;
  messages.value = [];
  forwardOnly = false;
  refreshRequired.value = false;
  clearReview();
  notice.value = 'conversationMissing';
}
function invalidate() {
  current?.abort();
  current = null;
  busy.value = null;
  allowed.value = false;
  availability.value = 'loading';
  skill.value = undefined;
  modelConfigRevision.value = undefined;
  groupName.value = '';
  history.value = [];
  next.value = null;
  selected.value = null;
  messages.value = [];
  forwardOnly = false;
  skillId.value = '';
  search.value = '';
  refreshRequired.value = false;
  published.value = null;
  clearReview();
}
onMounted(() => {
  unsubscribe = auth.subscribe(() => {
    invalidate();
    closed.value = true;
  });
  void reload();
});
onBeforeUnmount(() => {
  unsubscribe?.();
  current?.abort();
});
watch(() => props.groupId, () => {
  invalidate();
  closed.value = false;
  void reload();
});

function statusCode(error: unknown): number | undefined {
  const value = error as { statusCode?: number; status?: number } | null;
  return value?.statusCode ?? value?.status;
}
async function work(
  phase: NonNullable<typeof busy.value>,
  action: (signal: AbortSignal, isCurrent: () => boolean) => Promise<void>,
  historyConversationId?: string
) {
  if (current || closed.value || !account.isLoggedIn || auth.isIdentityChanging) return;
  const request = new AbortController();
  const groupId = props.groupId, revision = auth.revision;
  const valid = () => current === request && !request.signal.aborted &&
    groupId === props.groupId && revision === auth.revision && !closed.value && account.isLoggedIn;
  current = request;
  busy.value = phase;
  notice.value = null;
  try {
    await action(request.signal, valid);
  } catch (error) {
    if (!valid()) return;
    const status = statusCode(error);
    if (status === 404 && historyConversationId && selected.value === historyConversationId) {
      forgetConversation(historyConversationId);
      return;
    }
    if (status === 401 || status === 403) {
      invalidate();
      notice.value = 'forbidden';
      return;
    }
    const retry = phase === 'generate' ? aiQuotaRetry(error) : null;
    if (retry !== null) {
      quotaRetry.value = retry;
      notice.value = quotaRetry.value ? 'quotaRetry' : 'quota';
      return;
    }
    if (phase !== 'page' && (phase !== 'load' || selected.value)) {
      refreshRequired.value = true;
      messages.value = [];
      if (phase !== 'publish' && phase !== 'load') clearReview();
    }
    notice.value = phase === 'publish' && publicationUnconfirmed.value ? 'publishFailed' : phase === 'delete' ? 'deleteFailed' :
      status === 409 ? 'conflict' : status === 503 ? 'unavailable' : 'requestFailed';
  } finally {
    if (current === request) {
      current = null;
      busy.value = null;
    }
  }
}

async function pageHistory(after: string | null, signal: AbortSignal, valid: () => boolean) {
  const page = await api.list(props.groupId, after, signal);
  if (!valid()) return;
  const byId = new Map((after ? history.value : []).map(item => [item.id, item]));
  for (const item of page.items) {
    if (item.purpose === 'group' && item.groupId === props.groupId) byId.set(item.id, item);
  }
  history.value = [...byId.values()];
  next.value = page.next;
}
async function readForwardPage(id: string, signal: AbortSignal, result: GroupDraftMessage[] = [], before = Infinity) {
  let after = result.at(-1)?.sequence ?? 0;
  while (!signal.aborted) {
    const page = await api.messages(id, after, 50, signal);
    result = [...result, ...page.filter(message => message.sequence < before)].slice(-50);
    const last = page.at(-1)?.sequence ?? after;
    if (page.length < 50 || last >= before) return result;
    after = last;
  }
  throw signal.reason;
}
async function readMessages(id: string, signal: AbortSignal) {
  const messages = await api.messages(id, 0, 50, signal, 10_000_000_000);
  // A server that ignores before_sequence returns its first full page.
  if (messages.length < 50 || messages[0]?.sequence !== 1) return {messages, forwardOnly:false};
  return {messages:await readForwardPage(id, signal, messages), forwardOnly:true};
}
function loadOlderMessages() {
  const id = selected.value;
  const first = messages.value[0]?.sequence;
  if (!allowed.value || refreshRequired.value || !id || !first || !hasOlderMessages.value) return;
  return work('page', async (signal, valid) => {
    const page = forwardOnly ? await readForwardPage(id, signal, [], first) : await api.messages(id, 0, 50, signal, first);
    if (valid()) {
      messages.value = [...page, ...messages.value];
      oldestPageComplete.value = page.length < 50;
    }
  }, id);
}
function reload() {
  return work('load', async (signal, valid) => {
    const previousReview = review.value;
    publicationRetryConfirmed.value = false;
    allowed.value = false;
    messages.value = [];
    deleteConfirm.value = false;
    const group = await app.runWithContext(() => getGroup(props.groupId));
    if (!valid()) return;
    if (group.id !== props.groupId || !canUseGroupDrafts(group)) {
      invalidate();
      notice.value = 'forbidden';
      return;
    }
    groupName.value = group.name;
    availability.value = 'loading';
    skill.value = undefined;
    modelConfigRevision.value = undefined;
    const status = app.runWithContext(() => getAiAvailability(signal)).then(
      flags => {
        if (!valid()) return;
        availability.value = aiWorkflowAvailability(flags, 'group');
        skill.value = flags.skills?.find(item => item.purpose === 'group');
        modelConfigRevision.value = flags.modelConfigRevision;
      },
      () => { if (valid()) availability.value = 'unknown'; }
    );
    await Promise.all([pageHistory(null, signal, valid), status]);
    let freshReview: GroupDraftMessage | undefined;
    if (selected.value && valid()) {
      const id = selected.value;
      try {
        const recent = await readMessages(id, signal);
        if (!valid()) return;
        const list = recent.messages;
        if (previousReview) {
          freshReview = list.find(message => message.id === previousReview.id);
          if (!freshReview && list[0] && previousReview.sequence < list[0].sequence) {
            [freshReview] = await api.messages(id, previousReview.sequence - 1, 1, signal);
          }
        }
        if (valid()) {
          messages.value = list;
          oldestPageComplete.value = list.length < 50;
          forwardOnly = recent.forwardOnly;
        }
      } catch (error) {
        if (statusCode(error) !== 404) throw error;
        if (valid()) forgetConversation(id);
      }
    }
    if (!valid()) return;
    allowed.value = true;
    refreshRequired.value = false;
    if (previousReview && selected.value) {
      if (freshReview && sameDraft(previousReview, freshReview)) {
        review.value = freshReview;
        notice.value = 'reviewRestored';
      } else {
        clearReview();
        notice.value = 'conflict';
      }
    }
  });
}
function openConversation(item: GroupDraftConversation) {
  if (!allowed.value || !history.value.some(value => value.id === item.id)) return;
  if (selected.value === item.id) return reload();
  return work('load', async (signal, valid) => {
    selected.value = item.id;
    messages.value = [];
    published.value = null;
    clearReview();
    const recent = await readMessages(item.id, signal);
    if (valid()) {
      messages.value = recent.messages;
      oldestPageComplete.value = recent.messages.length < 50;
      forwardOnly = recent.forwardOnly;
      refreshRequired.value = false;
    }
  }, item.id);
}
function newConversation() {
  if (busy.value || !allowed.value) return;
  selected.value = null;
  messages.value = [];
  refreshRequired.value = false;
  notice.value = null;
  published.value = null;
  clearReview();
}
function generate() {
  if (!allowed.value || availability.value !== 'enabled' || refreshRequired.value || review.value || deleteConfirm.value || invalidSearch.value) return;
  return work('generate', async (signal, valid) => {
    const mode = kind.value;
    const selectedSkill = skillId.value || undefined;
    const term = searchTerm.value || undefined;
    let id = selected.value;
    if (!id) {
      const item = await api.create(props.groupId, signal);
      if (!valid()) return;
      id = selected.value = item.id;
      history.value = [item, ...history.value.filter(row => row.id !== item.id)];
    }
    const generated = await api.generate(id, mode, messages.value.at(-1)?.sequence ?? 0, signal, selectedSkill, term);
    if (!valid()) return;
    busy.value = 'load';
    try {
      const recent = await readMessages(id, signal);
      if (!valid()) return;
      messages.value = recent.messages;
      oldestPageComplete.value = recent.messages.length < 50;
      forwardOnly = recent.forwardOnly;
      if (!generated) notice.value = 'insufficient';
    } catch (error) {
      if (!valid()) return;
      if (!generated || [401, 403, 404].includes(statusCode(error) ?? 0)) throw error;
      messages.value = [];
      refreshRequired.value = true;
      clearReview();
      notice.value = 'generationSaved';
    }
  });
}
function removeConversation() {
  const id = selected.value;
  if (!id || !allowed.value || !deleteConfirm.value || refreshRequired.value) return;
  return work('delete', async (signal, valid) => {
    await api.remove(id, signal);
    if (!valid()) return;
    history.value = history.value.filter(item => item.id !== id);
    selected.value = null;
    messages.value = [];
    clearReview();
    notice.value = 'deleted';
  });
}
function cancelGeneration() {
  if (busy.value !== 'generate') return;
  current?.abort();
  current = null;
  busy.value = null;
  messages.value = [];
  refreshRequired.value = true;
  notice.value = 'cancelled';
}

async function confirmSource(message: GroupDraftMessage, id: string, signal: AbortSignal) {
  const [fresh] = await api.messages(id, message.sequence - 1, 1, signal);
  return sameDraft(message, fresh);
}
function sameDraft(message: GroupDraftMessage, fresh?: GroupDraftMessage) {
  return fresh?.id === message.id && fresh.sequence === message.sequence && fresh.role === 'assistant' &&
    fresh.content === message.content && fresh.sources.length > 0 &&
    JSON.stringify(fresh.sources) === JSON.stringify(message.sources);
}
function markStale() {
  messages.value = [];
  refreshRequired.value = true;
  clearReview();
  notice.value = 'conflict';
}
function startReview(message: GroupDraftMessage) {
  const id = selected.value;
  if (!id || !allowed.value || refreshRequired.value || deleteConfirm.value || !message.sources.length) return;
  return work('review', async (signal, valid) => {
    const available = await confirmSource(message, id, signal);
    if (!valid()) return;
    if (!available) return markStale();
    review.value = message;
    edited.value = message.content;
    announcement.value = false;
    published.value = null;
  });
}
function publish() {
  const id = selected.value, draft = review.value, content = edited.value.trim();
  if (!id || !draft || !allowed.value || refreshRequired.value || publicationNeedsConfirmation.value || !content || editedBytes.value > 4000) return;
  const isAnnouncement = announcement.value, groupId = props.groupId;
  return work('publish', async (signal, valid) => {
    const available = await confirmSource(draft, id, signal);
    if (!valid()) return;
    if (!available) return markStale();
    publicationUnconfirmed.value = true;
    publicationRetryConfirmed.value = false;
    const post = await app.runWithContext(() => createGroupPost(groupId, {content, is_announcement:isAnnouncement}, signal));
    if (!valid()) return;
    clearReview();
    published.value = post.id;
    notice.value = 'published';
  });
}
const postHref = (postId: number, commentId?: number) => localePath({
  path:'/groups/posts',
  query:{group:props.groupId, post:postId, comments:'1', ...(commentId === undefined ? {} : {comment:commentId})}
});
</script>

<template>
  <section :aria-label="label('title')" class="grid min-w-0 gap-4">
    <div class="flex flex-wrap items-center justify-between gap-2">
      <div class="min-w-0">
        <h3 class="text-base font-semibold">{{ label('title') }}</h3>
        <p v-if="allowed && groupName" class="break-words text-sm text-muted-foreground">{{ groupName }}</p>
      </div>
      <Button type="button" size="sm" variant="outline" :disabled="!!busy || closed" @click="reload">{{ t('common.refresh') }}</Button>
    </div>
    <p v-if="closed" role="status" class="text-sm text-muted-foreground">{{ label('sessionChanged') }}</p>
    <p v-else-if="busy" role="status" class="text-sm text-muted-foreground">{{ label(busy === 'generate' ? 'generating' : 'working') }}</p>
    <p v-if="notice" role="status" class="text-sm text-muted-foreground">
      {{ t(`aiGroupDraft.${notice}`, {seconds: quotaRetry}) }}
    </p>
    <NuxtLink v-if="published" :to="postHref(published)" class="text-sm underline">{{ label('openPost') }}</NuxtLink>
    <NuxtLink v-if="publicationUnconfirmed && !busy" :to="localePath({path:'/groups/posts',query:{group:groupId}})" target="_blank" rel="noopener noreferrer" class="text-sm underline">
      {{ label('checkGroupPostsNewTab') }}
    </NuxtLink>
    <template v-if="allowed">
      <div class="grid gap-2 rounded-lg border p-3">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h4 class="text-sm font-medium">{{ label('history') }}</h4>
          <div class="flex flex-wrap gap-2">
            <Button type="button" size="sm" variant="outline" :disabled="!!busy" @click="newConversation">{{ label('new') }}</Button>
            <Button v-if="selected && !review" type="button" size="sm" variant="outline" :disabled="!!busy || refreshRequired" @click="deleteConfirm = true">{{ label('delete') }}</Button>
          </div>
        </div>
        <ul v-if="history.length" class="max-h-40 space-y-1 overflow-y-auto">
          <li v-for="item in history" :key="item.id">
            <button type="button" class="w-full rounded-md px-2 py-1.5 text-left text-sm hover:bg-muted aria-[current=true]:bg-muted" :aria-current="selected === item.id" :disabled="!!busy" @click="openConversation(item)">
              {{ item.title || label('untitled') }}
              <span class="block truncate text-xs text-muted-foreground">{{ item.updatedAt }}</span>
            </button>
          </li>
        </ul>
        <p v-else-if="!busy" class="text-sm text-muted-foreground">{{ label('noHistory') }}</p>
        <Button v-if="next" type="button" size="sm" variant="ghost" :disabled="!!busy" @click="work('page', (signal, valid) => pageHistory(next, signal, valid))">{{ label('more') }}</Button>
      </div>
      <section v-if="deleteConfirm" class="grid gap-2 rounded-lg border p-3">
        <p class="text-sm">{{ label('deleteQuestion') }}</p>
        <div class="flex flex-wrap gap-2">
          <Button type="button" size="sm" variant="destructive" :disabled="!!busy" @click="removeConversation">{{ label('confirmDelete') }}</Button>
          <Button type="button" size="sm" variant="outline" :disabled="!!busy" @click="deleteConfirm = false">{{ t('common.cancel') }}</Button>
        </div>
      </section>

      <div class="flex flex-wrap items-end gap-2">
        <label class="grid gap-1 text-sm">
          {{ label('kind') }}
          <select v-model="kind" :disabled="!!busy || !!review" class="h-9 rounded-md border bg-background px-2">
            <option v-for="mode in groupDraftKinds" :key="mode" :value="mode">{{ label(mode) }}</option>
          </select>
        </label>
        <label class="grid gap-1 text-sm">
          {{ label('skill') }}
          <select v-model="skillId" :disabled="!!busy || !!review" class="h-9 rounded-md border bg-background px-2">
            <option value="">{{ label('automaticSkill') }}</option>
            <option value="group-brief">{{ label('groupBriefSkill') }}</option>
          </select>
        </label>
        <label v-if="!review" class="grid gap-1 text-sm">
          {{ label('searchTerm') }}
          <input v-model="search" type="text" :disabled="!!busy" :aria-invalid="invalidSearch" class="h-9 rounded-md border bg-background px-2" />
        </label>
        <Button type="button" :disabled="!!busy || availability !== 'enabled' || refreshRequired || !!review || deleteConfirm || invalidSearch" @click="generate">{{ label('generate') }}</Button>
        <Button v-if="busy === 'generate'" type="button" variant="outline" @click="cancelGeneration">{{ t('common.cancel') }}</Button>
      </div>
      <p v-if="invalidSearch && !review" role="alert" class="text-sm text-destructive">{{ label('searchInvalid') }}</p>
      <AiSkillStatus v-if="skill || modelConfigRevision !== undefined || availability !== 'enabled'" :availability="availability" :skill="skill" :model-config-revision="modelConfigRevision" />
      <section v-if="review" class="grid gap-3 rounded-lg border p-3">
        <h4 class="text-sm font-semibold">{{ label('reviewTitle') }}</h4>
        <Textarea v-model="edited" :aria-label="label('draftText')" rows="6" :disabled="!!busy"
          :aria-invalid="editedBytes > 4000" />
        <p class="text-xs" :class="editedBytes > 4000 ? 'text-destructive' : 'text-muted-foreground'">
          {{ t('aiGroupDraft.draftBytes', { bytes: editedBytes }) }}
        </p>
        <p v-if="editedBytes > 4000" role="alert" class="text-sm text-destructive">{{ label('tooLong') }}</p>
        <label class="flex items-center gap-2 text-sm"><input v-model="announcement" type="checkbox" :disabled="!!busy" />{{ label('publishAsAnnouncement') }}</label>
        <label v-if="publicationUnconfirmed && !refreshRequired" class="flex items-center gap-2 text-sm">
          <input v-model="publicationRetryConfirmed" type="checkbox" :disabled="!!busy" />{{ label('confirmPublicationRetry') }}
        </label>
        <div class="flex flex-wrap gap-2">
          <Button type="button" :disabled="!!busy || refreshRequired || publicationNeedsConfirmation || !editedBytes || editedBytes > 4000" @click="publish">{{ label('confirmPublish') }}</Button>
          <Button type="button" variant="outline" :disabled="!!busy" @click="clearReview">{{ t('common.cancel') }}</Button>
        </div>
      </section>
      <article v-for="message in messages.filter(entry => entry.role === 'assistant').reverse()" :key="message.id" class="grid gap-2 rounded-lg border p-3">
        <p class="whitespace-pre-wrap break-words text-sm">{{ message.sources.length ? message.content : label('staleDraft') }}</p>
        <p v-if="message.sources.length && message.modelVersion" class="break-all text-xs text-muted-foreground">
          {{ t('aiModelVersion') }} · {{ message.modelVersion }}
        </p>
        <p v-if="message.sources.length && message.configRevision !== null" class="text-xs text-muted-foreground">
          {{ t('aiReplyConfigRevision', { revision: message.configRevision }) }}
        </p>
        <p v-if="message.tools?.length" class="text-xs text-muted-foreground">
          {{ t('aiGroupDraft.usedTools', { tools: message.tools.map(tool => label(tool)).join(locale === 'en' ? ', ' : '、') }) }}
        </p>
        <ul v-if="message.sources.length" :aria-label="label('sources')" class="flex flex-wrap gap-x-3 gap-y-1 text-xs">
          <li v-for="source in message.sources" :key="`${source.kind}-${source.source_id}`">
            <NuxtLink :to="postHref(source.post_id, source.kind === 'comment' ? source.source_id : undefined)" class="underline underline-offset-2">{{ label(source.kind) }} #{{ source.source_id }}</NuxtLink>
          </li>
        </ul>
        <Button v-if="message.sources.length" type="button" size="sm" variant="outline" class="justify-self-start" :disabled="!!busy || !!review || refreshRequired || deleteConfirm" @click="startReview(message)">{{ label('review') }}</Button>
      </article>
      <Button v-if="selected && hasOlderMessages" type="button" variant="ghost" size="sm" :disabled="!!busy || refreshRequired" @click="loadOlderMessages">{{ t('chat.directMessage.loadOlder') }}</Button>
    </template>
  </section>
</template>
