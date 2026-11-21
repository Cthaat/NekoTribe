<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, reactive, ref, useId, watch } from 'vue';
import { Bot, Copy, History, Loader2, Plus, Send, Trash2 } from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { writingApi } from '@/api/v2/ai-writing';
import { knowledgeApi } from '@/api/v2/ai-knowledge';
import { aiMessageBytes, aiMessageContent, aiMessageMaxBytes, citationTarget, createWritingController, initialWritingState } from '@/services/ai-writing-controller';
import type { KnowledgeCitation } from '@/services/ai-writing-controller';
import { aiModelVersion, isAiReplyConfigRevision } from '@/utils/ai-model-version';
import { authQueueFor } from '@/services/auth-request-queue';
import { stageAiPostDraft } from '@/utils/ai-post-draft';
import { takeDiscussionDraft } from '@/utils/ai-discussion-draft';
import AiSkillStatus from '@/components/AiSkillStatus.vue';

const props = defineProps<{ purpose: 'writing' | 'knowledge'; composerDraft?: string }>();
const emit = defineEmits<{ applyDraft: [text: string] }>();
const embedded = computed(() => props.composerDraft !== undefined);
const { t } = useAppLocale();
const localePath = useLocalePath();
const route = useRoute();
const router = useRouter();
const label = (key: string) => t(`${props.purpose === 'knowledge' ? 'aiKnowledge' : 'aiWriting'}.${key}`);
const state = reactive(initialWritingState());
const controller = createWritingController(
  props.purpose === 'knowledge' ? knowledgeApi : writingApi, state, props.purpose,
  id => {
    if (routeConversation(route.query.conversation) === id) void updateLocation(null).catch(() => {});
  }
);
const writingModes = ['draft', 'polish', 'tags', 'summary'] as const;
const writingMode = ref<typeof writingModes[number]>('draft');
const instruction = computed(() => props.purpose === 'writing' && writingMode.value !== 'draft'
  ? label(`instructions.${writingMode.value}`)
  : undefined);
const messageBytes = computed(() => aiMessageBytes(aiMessageContent(state.draft, instruction.value)));
const messageTooLong = computed(() => messageBytes.value > aiMessageMaxBytes);
const messageCounterId = useId();
const inputLabel = computed(() => props.purpose === 'writing' && writingMode.value !== 'draft'
  ? label('sourcePlaceholder')
  : label('placeholder'));
const deleteOpen = ref(false);
const closed = ref(false);
const app = useNuxtApp();
const auth = authQueueFor(app);
const discussionPrefilled = ref(false);
const openingComposer = ref(false);
const messageList = ref<HTMLElement | null>(null);
let unsubscribe: (() => void) | undefined;
let pendingRestore = false;
const lastUser = computed(() => state.messages.at(-1)?.role === 'user');
const errorText = computed(() => state.error === 'quota'
  ? t(state.quotaRetry ? 'aiGroupDraft.quotaRetry' : 'aiGroupDraft.quota', {seconds: state.quotaRetry})
  : state.error === 'title-too-long' ? t('aiWriting.conversationTitleTooLong')
  : state.error ? label(`errors.${state.error}`) : '');
function citationHref(source: KnowledgeCitation): string | null {
  const target = citationTarget(source);
  if (!target) return null;
  if (target.kind === 'terms') return target.href;
  if (target.kind === 'group') {
    return localePath({
      path: '/groups/posts',
      query: {
        group: target.groupId,
        post: target.postId,
        source: 'knowledge',
        ...(target.commentId === undefined ? {} : {comments:'1',comment:target.commentId}),
      },
    });
  }
  return localePath({
    path: `/tweet/${target.id}`,
    ...(source.kind === 'comment' ? {query:{comment:source.id}} : {}),
  });
}
function closeSession() {
  controller.close();
  deleteOpen.value = false;
  closed.value = true;
}

async function copyReply(text: string): Promise<void> {
  if (closed.value || auth.isIdentityChanging) return;
  const revision = auth.revision;
  try {
    await navigator.clipboard.writeText(text);
    if (revision === auth.revision && !closed.value) toast.success(t('aiWriting.replyCopied'));
  } catch {
    if (revision === auth.revision && !closed.value) toast.error(t('aiWriting.copyFailed'));
  }
}

async function useAsPost(text: string): Promise<void> {
  if (closed.value || auth.isIdentityChanging || openingComposer.value || !text.trim() || text.length > 280) return;
  if (embedded.value) {
    emit('applyDraft', text);
    return;
  }
  openingComposer.value = true;
  const cancel = stageAiPostDraft(app, auth.revision, text);
  try {
    if (await router.push(localePath('/meow'))) cancel();
    if (router.currentRoute.value.path !== localePath('/meow')) cancel();
  } catch {
    cancel();
    if (!closed.value) toast.error(t('aiWriting.composerFailed'));
  } finally {
    openingComposer.value = false;
  }
}
function routeConversation(value: unknown): string | null {
  return typeof value === 'string' && value.trim() === value &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
    ? value.toLowerCase() : null;
}
async function updateLocation(id: string | null) {
  if (embedded.value || closed.value || route.query.conversation === (id ?? undefined)) return;
  if (id !== null && !routeConversation(id)) return;
  const query = {...route.query};
  if (id) query.conversation = id;
  else delete query.conversation;
  await router.replace({path: route.path, query, hash: route.hash});
}
async function restoreLocation() {
  if (embedded.value || closed.value) return;
  const raw = route.query.conversation;
  const id = routeConversation(raw);
  if (state.busy && state.id !== id) { pendingRestore = true; return; }
  pendingRestore = false;
  if (state.id === id) return;
  if (state.id) controller.reset();
  if (id) await controller.select(id, () => route.query.conversation === raw);
}
async function selectHistory(id: string) {
  const path = route.fullPath;
  await controller.select(id, () => path === route.fullPath);
  if (state.id === id && path === route.fullPath) await updateLocation(id);
}
async function startNew() {
  controller.reset();
  if (!state.id) await updateLocation(null);
}
onMounted(() => {
  unsubscribe = auth.subscribe(closeSession);
  if (auth.isIdentityChanging) closeSession();
  else {
    if (embedded.value) {
      state.draft = props.composerDraft ?? '';
      if (state.draft.trim()) writingMode.value = 'polish';
    } else if (props.purpose === 'writing' && !routeConversation(route.query.conversation)) {
      const draft = takeDiscussionDraft(app, auth.revision);
      if (draft) {
        state.draft = draft;
        writingMode.value = 'summary';
        discussionPrefilled.value = true;
      }
    }
    void controller.loadHistory();
    void controller.loadAvailability();
    void restoreLocation();
  }
});
watch(() => route.query.conversation, () => { void restoreLocation(); });
watch(() => state.busy, busy => { if (!busy && pendingRestore) void restoreLocation(); });
watch([() => state.id, () => state.messages.at(-1)?.message_id], () => {
  if (messageList.value) messageList.value.scrollTop = messageList.value.scrollHeight;
}, { flush: 'post' });
onBeforeUnmount(() => {
  unsubscribe?.();
  controller.close();
});
async function confirmDelete() {
  deleteOpen.value = false;
  const path = route.fullPath;
  await controller.remove();
  if (!state.id && !state.error) {
    if (path === route.fullPath) await updateLocation(null);
    await controller.loadHistory();
  }
}
async function submit() {
  const path = route.fullPath;
  let attemptedId = state.id;
  let locationUpdate: Promise<void> | undefined;
  await controller.send(instruction.value, id => {
    attemptedId = id;
    if (path === route.fullPath) locationUpdate = updateLocation(id).catch(() => {});
  });
  await locationUpdate;
  if (!state.id && state.error === 'conversation-missing' &&
      attemptedId && routeConversation(route.query.conversation) === attemptedId) {
    await updateLocation(null);
  }
  if (!state.error) await controller.loadHistory();
}
</script>

<template>
  <p v-if="closed" role="status" class="mx-auto max-w-7xl px-4 py-5 text-muted-foreground">{{ t('visibility.sessionChanged') }}</p>
  <div v-else class="mx-auto flex max-w-7xl flex-col gap-5 px-3 py-5 sm:px-6 sm:py-8">
    <header class="flex flex-wrap items-start justify-between gap-3" :class="{ 'pr-7': embedded }">
      <div>
        <div class="flex items-center gap-2 text-primary"><Bot class="h-5 w-5" /><span class="text-sm font-medium">{{ label('eyebrow') }}</span></div>
        <h1 class="mt-1 text-2xl font-semibold tracking-tight">{{ label('title') }}</h1>
        <p class="mt-1 text-sm text-muted-foreground">{{ label('description') }}</p>
        <p v-if="embedded" class="mt-1 text-sm text-muted-foreground">{{ t('aiWriting.composerSource') }}</p>
      </div>
      <div class="flex gap-2">
        <Button variant="outline" :disabled="state.busy" @click="startNew"><Plus class="mr-2 h-4 w-4" />{{ label('new') }}</Button>
        <Button v-if="state.id" variant="outline" :disabled="state.busy" @click="deleteOpen = true"><Trash2 class="mr-2 h-4 w-4" />{{ t('common.delete') }}</Button>
      </div>
    </header>
    <div class="flex flex-wrap items-center justify-between gap-3 rounded-lg border bg-muted/40 px-4 py-3">
      <AiSkillStatus :availability="state.availability" :skill="state.skill" :model-config-revision="state.modelConfigRevision" />
      <label v-if="state.skill?.explicitSelection && state.skill.enabled" class="flex items-center gap-2 text-sm">
        <input v-model="state.explicitSkill" type="checkbox" :disabled="state.busy || state.availability !== 'enabled'" />
        {{ t('aiAvailability.selectExplicitly') }}
      </label>
      <Button variant="outline" size="sm" :disabled="state.busy || state.availability === 'loading'" @click="controller.loadAvailability()">{{ t('aiAvailability.refresh') }}</Button>
    </div>
    <div class="grid min-w-0 gap-4 lg:grid-cols-[260px_minmax(0,1fr)]">
      <aside class="min-w-0 rounded-xl border bg-card p-4">
        <div class="flex items-center justify-between gap-2"><h2 class="flex items-center gap-2 text-sm font-semibold"><History class="h-4 w-4" />{{ label('history') }}</h2><Button variant="ghost" size="sm" :disabled="state.historyBusy" @click="controller.loadHistory()">{{ t('common.refresh') }}</Button></div>
        <p v-if="!state.history.length && !state.historyBusy" class="py-5 text-sm text-muted-foreground">{{ label('historyEmpty') }}</p>
        <ul class="mt-3 max-h-64 space-y-1 overflow-y-auto lg:max-h-[55vh]">
          <li v-for="item in state.history" :key="item.conversation_id">
            <button type="button" :disabled="state.busy" :aria-current="state.id === item.conversation_id ? 'true' : undefined" class="w-full rounded-lg px-3 py-2 text-left text-sm hover:bg-muted aria-[current=true]:bg-primary/10" @click="selectHistory(item.conversation_id)">
              <span class="block truncate font-medium">{{ item.title || label('untitled') }}</span>
              <span class="block truncate text-xs text-muted-foreground">{{ item.updated_at || item.conversation_id }}</span>
            </button>
          </li>
        </ul>
        <Button v-if="state.historyCursor" variant="ghost" size="sm" class="mt-2 w-full" :disabled="state.historyBusy" @click="controller.loadHistory(false)">{{ t('common.loadMore') }}</Button>
      </aside>
      <section class="flex min-h-[32rem] min-w-0 flex-col rounded-xl border bg-card" :aria-label="label('title')">
        <div ref="messageList" class="max-h-[65vh] flex-1 space-y-4 overflow-y-auto p-4 sm:p-6" aria-live="polite">
          <Button v-if="state.hasOlderMessages" variant="ghost" size="sm" class="w-full" :disabled="state.busy || state.savedReplyPending" @click="controller.loadOlderMessages()">
            {{ t('chat.directMessage.loadOlder') }}
          </Button>
          <div v-if="!state.messages.length" class="flex min-h-48 items-center justify-center text-center text-sm text-muted-foreground">{{ label('empty') }}</div>
          <div v-for="message in state.messages" :key="message.message_id" class="flex" :class="message.role === 'user' ? 'justify-end' : 'justify-start'">
            <div class="max-w-[90%] rounded-2xl px-4 py-3 sm:max-w-[80%]" :class="message.role === 'user' ? 'bg-primary text-primary-foreground' : 'bg-muted'">
              <div class="mb-1 text-xs font-medium opacity-70">{{ message.role === 'user' ? label('you') : label('assistant') }}</div>
              <p class="whitespace-pre-wrap break-words text-sm leading-relaxed">{{ message.content }}</p>
              <div v-if="message.role === 'assistant' && message.content.trim()" class="mt-2 flex flex-wrap gap-2">
                <Button variant="ghost" size="sm" @click="copyReply(message.content)">
                  <Copy class="h-3.5 w-3.5" />{{ t('aiWriting.copyReply') }}
                </Button>
                <Button v-if="purpose === 'writing' && message.content.length <= 280" variant="outline" size="sm"
                  :disabled="openingComposer" @click="useAsPost(message.content)">{{ t(embedded ? 'aiWriting.applyToComposer' : 'aiWriting.useAsPost') }}</Button>
                <span v-if="purpose === 'writing' && message.content.length > 280" class="self-center text-xs text-muted-foreground">
                  {{ t('aiWriting.postTooLong') }}
                </span>
              </div>
              <p v-if="aiModelVersion(message.role, message.model_version)" class="mt-2 break-all text-xs text-muted-foreground">
                {{ t('aiModelVersion') }} · {{ message.model_version }}
              </p>
              <p v-if="isAiReplyConfigRevision(message.role, message.config_revision)" class="text-xs text-muted-foreground">
                {{ t('aiReplyConfigRevision', { revision: message.config_revision }) }}
              </p>
              <div v-if="message.citations?.length" class="mt-3 border-t pt-2 text-xs">
                <p class="mb-1 font-medium">{{ label('sources') }}</p>
                <ul class="space-y-1">
                  <li v-for="source in message.citations" :key="`${source.kind}-${source.id}`">
                    <NuxtLink v-if="citationHref(source)" class="underline underline-offset-2" :to="citationHref(source) || ''">{{ label(source.kind) }} #{{ source.id }}</NuxtLink>
                    <span v-else>{{ label(source.kind) }} #{{ source.id }}</span>
                  </li>
                </ul>
              </div>
            </div>
          </div>
        </div>
        <div class="border-t p-4 sm:p-6">
          <p v-if="state.insufficientEvidence" role="status" class="mb-3 text-sm text-muted-foreground">{{ label('insufficientEvidence') }}</p>
          <p v-if="state.error === 'generation-stopped'" role="status" class="mb-3 text-sm text-muted-foreground">{{ errorText }}</p>
          <p v-else-if="state.error" role="alert" class="mb-3 text-sm text-destructive">{{ errorText }}</p>
          <div v-if="state.refreshRequired || lastUser || (purpose === 'knowledge' && state.id)" class="mb-3 flex flex-wrap gap-2">
            <Button v-if="state.refreshRequired || (purpose === 'knowledge' && state.id)" variant="outline" size="sm" :disabled="state.busy" @click="controller.retry(false)">{{ label(purpose === 'knowledge' ? 'recheckSources' : 'refreshState') }}</Button>
            <Button v-if="lastUser && !state.savedReplyPending" variant="outline" size="sm" :disabled="state.busy || state.availability !== 'enabled'" @click="controller.retry()">{{ label('retry') }}</Button>
          </div>
          <form class="space-y-3" @submit.prevent="submit">
            <label v-if="!state.id" class="grid gap-1 text-sm font-medium">
              {{ t('aiWriting.conversationTitle') }}
              <input v-model="state.titleDraft" type="text" maxlength="200" :disabled="state.busy"
                class="h-9 rounded-md border bg-background px-3 font-normal" />
            </label>
            <div v-if="purpose === 'knowledge'" class="space-y-1">
              <label for="knowledge-search-phrase" class="text-sm font-medium">{{ label('searchLabel') }}</label>
              <Textarea id="knowledge-search-phrase" v-model="state.searchPhrase" :disabled="state.busy" :placeholder="label('searchPlaceholder')" :aria-describedby="'knowledge-search-hint'" rows="1" />
              <p id="knowledge-search-hint" class="text-xs text-muted-foreground">{{ label('searchHint') }}</p>
            </div>
            <label v-else class="flex flex-wrap items-center gap-2 text-sm font-medium">
              {{ label('modeLabel') }}
              <select v-model="writingMode" :disabled="state.busy" class="rounded-md border bg-background px-2 py-1">
                <option v-for="mode in writingModes" :key="mode" :value="mode">{{ label(`modes.${mode}`) }}</option>
              </select>
            </label>
            <p v-if="discussionPrefilled && !state.id && state.draft && writingMode === 'summary'" class="text-xs text-muted-foreground">
              {{ t('aiWriting.discussionPrefilled') }}
            </p>
            <div class="flex items-end gap-2">
              <Textarea v-model="state.draft" :disabled="state.busy" :placeholder="inputLabel" :aria-label="inputLabel" :aria-invalid="messageTooLong" :aria-describedby="messageCounterId" rows="2" />
              <Button type="submit" :disabled="state.busy || state.refreshRequired || state.availability !== 'enabled' || messageBytes === 0 || messageTooLong"><Loader2 v-if="state.busy" class="h-4 w-4 animate-spin" /><Send v-else class="h-4 w-4" /><span class="sr-only">{{ label('send') }}</span></Button>
              <Button v-if="state.generating" type="button" variant="outline" @click="controller.stopGeneration()">{{ label('stopGeneration') }}</Button>
            </div>
            <p :id="messageCounterId" class="text-xs tabular-nums" :class="messageTooLong ? 'text-destructive' : 'text-muted-foreground'">
              {{ t('aiWriting.messageBytes', { bytes: messageBytes, limit: aiMessageMaxBytes }) }}
            </p>
          </form>
        </div>
      </section>
    </div>
    <Dialog v-model:open="deleteOpen">
      <DialogContent><DialogHeader><DialogTitle>{{ label('deleteTitle') }}</DialogTitle><DialogDescription>{{ label('deleteDescription') }}</DialogDescription></DialogHeader><DialogFooter><Button variant="outline" @click="deleteOpen = false">{{ t('common.cancel') }}</Button><Button variant="destructive" @click="confirmDelete">{{ t('common.delete') }}</Button></DialogFooter></DialogContent>
    </Dialog>
  </div>
</template>
