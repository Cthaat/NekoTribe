<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, reactive, ref, useId, watch } from 'vue';
import { Bot, Copy, Hash, History, Loader2, Plus, Send, Trash2 } from 'lucide-vue-next';
import { toast } from 'vue-sonner';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import { Textarea } from '@/components/ui/textarea';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Checkbox } from '@/components/ui/checkbox';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { writingApi } from '@/api/v2/ai-writing';
import { knowledgeApi, scopedKnowledgeApi, type KnowledgeScope } from '@/api/v2/ai-knowledge';
import { aiMessageBytes, aiMessageContent, aiMessageMaxBytes, citationTarget, createWritingController, initialWritingState } from '@/services/ai-writing-controller';
import type { KnowledgeCitation } from '@/services/ai-writing-controller';
import { aiModelVersion, isAiReplyConfigRevision } from '@/utils/ai-model-version';
import { authQueueFor } from '@/services/auth-request-queue';
import { stageAiPostDraft } from '@/utils/ai-post-draft';
import { takeDiscussionDraft } from '@/utils/ai-discussion-draft';
import AiSkillStatus from '@/components/AiSkillStatus.vue';
import AppEmptyState from '@/components/app/AppEmptyState.vue';

const props = defineProps<{ purpose: 'writing' | 'knowledge'; composerDraft?: string; knowledgeScope?: KnowledgeScope; knowledgeGroupId?: number }>();
const emit = defineEmits<{ applyDraft: [text: string] }>();
const embedded = computed(() => props.composerDraft !== undefined);
const { t } = useAppLocale();
const localePath = useLocalePath();
const route = useRoute();
const router = useRouter();
const label = (key: string) => t(`${props.purpose === 'knowledge' ? 'aiKnowledge' : 'aiWriting'}.${key}`);
const state = reactive(initialWritingState());
const controller = createWritingController(
  props.purpose === 'knowledge'
    ? (props.knowledgeScope ? scopedKnowledgeApi(props.knowledgeScope, props.knowledgeGroupId) : knowledgeApi)
    : writingApi, state, props.purpose,
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
const historyOpen = ref(false);
const titleExpanded = ref(false);
const searchExpanded = ref(false);
const showTitleField = computed(() => !state.id && (titleExpanded.value || state.titleDraft.trim().length > 0));
const showSearchField = computed(() => props.purpose === 'knowledge' && (searchExpanded.value || state.searchPhrase.trim().length > 0));
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
        ...(props.knowledgeScope === 'group' ? {} : { source: 'knowledge' }),
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
  <p v-if="closed" role="status" class="mx-auto max-w-[760px] px-4 py-5 text-muted-foreground">{{ t('visibility.sessionChanged') }}</p>
  <div v-else class="mx-auto flex max-w-[760px] flex-col gap-4 px-3 py-4 sm:px-6 sm:py-6">
    <header class="flex flex-wrap items-start justify-between gap-3" :class="{ 'pr-7': embedded }">
      <div>
        <span class="inline-flex items-center gap-1.5 rounded-full bg-primary/10 px-2.5 py-0.5 text-xs font-medium text-primary"><Bot class="size-3.5" />{{ label('eyebrow') }}</span>
        <h1 class="mt-2 text-2xl font-semibold tracking-tight">{{ label('title') }}</h1>
        <p class="mt-1 text-sm text-muted-foreground">{{ label('description') }}</p>
        <p v-if="embedded" class="mt-1 text-sm text-muted-foreground">{{ t('aiWriting.composerSource') }}</p>
      </div>
      <div class="flex flex-wrap items-center gap-2">
        <Button variant="secondary" size="icon" class="size-9 rounded-full" :aria-label="label('history')" :title="label('history')" :disabled="state.busy" @click="historyOpen = true">
          <History class="size-4" aria-hidden="true" />
        </Button>
        <Button variant="secondary" size="icon" class="size-9 rounded-full" :aria-label="label('new')" :title="label('new')" :disabled="state.busy" @click="startNew">
          <Plus class="size-4" aria-hidden="true" />
        </Button>
        <Button v-if="state.id" variant="secondary" size="icon" class="size-9 rounded-full text-muted-foreground hover:text-destructive" :aria-label="t('common.delete')" :title="t('common.delete')" :disabled="state.busy" @click="deleteOpen = true">
          <Trash2 class="size-4" aria-hidden="true" />
        </Button>
      </div>
    </header>
    <div class="bento-tile flex flex-wrap items-center justify-between gap-3 px-4 py-3">
      <AiSkillStatus :availability="state.availability" :skill="state.skill" :model-config-revision="state.modelConfigRevision" />
      <Button variant="secondary" size="sm" class="rounded-full border-0 bg-card/85 hover:bg-card" :disabled="state.busy || state.availability === 'loading'" @click="controller.loadAvailability()">{{ t('aiAvailability.refresh') }}</Button>
    </div>
    <section class="bento-card flex min-h-[19rem] min-w-0 flex-col overflow-hidden max-sm:max-h-[max(19rem,calc(100dvh-30rem))] sm:min-h-[28rem]" :aria-label="label('title')">
      <div ref="messageList" class="min-h-0 max-h-[40dvh] flex-1 space-y-5 overflow-y-auto p-3 sm:max-h-[60vh] sm:p-6" aria-live="polite">
        <Button v-if="state.hasOlderMessages" variant="ghost" size="sm" class="w-full rounded-full text-xs text-muted-foreground" :disabled="state.busy || state.savedReplyPending" @click="controller.loadOlderMessages()">
          {{ t('chat.directMessage.loadOlder') }}
        </Button>
        <MotionSkeletonSwap v-if="!state.messages.length && !state.preview">
          <div v-if="purpose === 'knowledge' && (state.availability === 'loading' || state.busy)" aria-busy="true" class="grid justify-items-center gap-3 py-6 md:py-10">
            <Skeleton class="size-12 rounded-full sm:size-16" />
            <Skeleton class="h-4 w-44 rounded-full" />
          </div>
        <div v-else class="py-2 md:py-6">
          <AppEmptyState
            :title="label('empty')"
            class="bg-transparent! shadow-none! max-sm:py-2 max-sm:[&>div:first-child]:mb-2 max-sm:[&>div:first-child]:size-12 max-sm:[&_svg]:size-8"
          />
        </div>
        </MotionSkeletonSwap>
        <div v-for="message in state.messages" :key="message.message_id" class="flex gap-3" :class="message.role === 'user' ? 'justify-end' : 'justify-start'">
          <div v-if="message.role !== 'user'" class="flex size-7 shrink-0 items-center justify-center rounded-full bg-primary/10 text-primary">
            <Bot class="size-4" />
          </div>
          <div
            class="max-w-[85%] px-4 py-3 sm:max-w-[75%]"
            :class="message.role === 'user'
              ? 'rounded-2xl rounded-br-md bg-primary text-primary-foreground dark:bg-primary/20 dark:text-foreground'
              : 'rounded-2xl rounded-bl-md bg-secondary/65'"
          >
            <div class="mb-1 text-xs font-medium opacity-70">{{ message.role === 'user' ? label('you') : label('assistant') }}</div>
            <p class="whitespace-pre-wrap break-words text-sm leading-relaxed">{{ message.content }}</p>
            <div v-if="message.role === 'assistant' && message.content.trim()" class="mt-2.5 flex flex-wrap items-center gap-1.5">
              <Button variant="ghost" size="icon" class="size-8 text-muted-foreground hover:text-foreground" :aria-label="t('aiWriting.copyReply')" :title="t('aiWriting.copyReply')" @click="copyReply(message.content)">
                <Copy class="size-4" aria-hidden="true" />
              </Button>
              <Button
                v-if="purpose === 'writing' && message.content.length <= 280"
                variant="secondary"
                size="sm"
                class="h-7 rounded-full border-0 px-2.5 text-xs"
                :disabled="openingComposer"
                @click="useAsPost(message.content)"
              >{{ t(embedded ? 'aiWriting.applyToComposer' : 'aiWriting.useAsPost') }}</Button>
              <span v-if="purpose === 'writing' && message.content.length > 280" class="self-center text-xs text-muted-foreground">
                {{ t('aiWriting.postTooLong') }}
              </span>
            </div>
            <p v-if="aiModelVersion(message.role, message.model_version)" class="mt-2 break-all text-[11px] text-muted-foreground">
              {{ t('aiModelVersion') }} · {{ message.model_version }}
            </p>
            <p v-if="isAiReplyConfigRevision(message.role, message.config_revision)" class="text-[11px] text-muted-foreground">
              {{ t('aiReplyConfigRevision', { revision: message.config_revision }) }}
            </p>
            <div v-if="message.citations?.length" class="mt-3 pt-2 text-xs">
              <p class="mb-1.5 font-medium text-muted-foreground">{{ label('sources') }}</p>
              <ul class="flex flex-wrap gap-1.5">
                <li v-for="source in message.citations" :key="`${source.kind}-${source.id}`">
                  <NuxtLink v-if="citationHref(source)" class="inline-flex rounded-full bg-card px-2.5 py-0.5 text-xs transition-colors hover:bg-accent" :to="citationHref(source) || ''">{{ label(source.kind) }} #{{ source.id }}</NuxtLink>
                  <span v-else class="inline-flex rounded-full bg-card px-2.5 py-0.5 text-xs text-muted-foreground">{{ label(source.kind) }} #{{ source.id }}</span>
                </li>
              </ul>
            </div>
          </div>
        </div>
      </div>
      <p v-if="state.preview" class="max-h-40 overflow-y-auto whitespace-pre-wrap break-words bg-secondary/40 px-4 py-3 text-sm leading-relaxed sm:px-6">{{ state.preview }}<span aria-hidden="true" class="w3-cursor" /></p>
      <div class="shrink-0 p-4 sm:p-5">
        <p v-if="state.insufficientEvidence" role="status" class="mb-3 text-sm text-muted-foreground">{{ label('insufficientEvidence') }}</p>
        <p v-if="state.error === 'generation-stopped'" role="status" class="mb-3 text-sm text-muted-foreground">{{ errorText }}</p>
        <p v-else-if="state.error && !(state.error === 'history' && state.availability !== 'enabled' && state.availability !== 'loading')" role="alert" class="mb-3 text-sm text-destructive">{{ errorText }}</p>
        <div v-if="state.refreshRequired || lastUser || (purpose === 'knowledge' && state.id)" class="mb-3 flex flex-wrap gap-2">
          <Button v-if="state.refreshRequired || (purpose === 'knowledge' && state.id)" variant="secondary" size="sm" class="rounded-full border-0" :disabled="state.busy" @click="controller.retry(false)">{{ label(purpose === 'knowledge' ? 'recheckSources' : 'refreshState') }}</Button>
          <Button v-if="lastUser && !state.savedReplyPending" variant="secondary" size="sm" class="rounded-full border-0" :disabled="state.busy || state.availability !== 'enabled'" @click="controller.retry()">{{ label('retry') }}</Button>
        </div>
        <div class="liquid-glass-island rounded-[26px] p-3.5">
          <form class="space-y-2.5" @submit.prevent="submit">
            <div v-if="showTitleField" class="grid gap-1.5">
              <Label :for="`${messageCounterId}-title`" class="text-xs text-muted-foreground">
                {{ t('aiWriting.conversationTitle') }}
              </Label>
              <Input
                :id="`${messageCounterId}-title`"
                v-model="state.titleDraft"
                type="text"
                maxlength="200"
                :disabled="state.busy"
                class="h-9 rounded-xl border-0 bg-card/80 shadow-none"
              />
            </div>
            <div v-if="showSearchField" class="space-y-1.5">
              <label for="knowledge-search-phrase" class="text-xs font-medium text-muted-foreground">{{ label('searchLabel') }}</label>
              <Textarea id="knowledge-search-phrase" v-model="state.searchPhrase" :disabled="state.busy" :placeholder="label('searchPlaceholder')" :aria-describedby="'knowledge-search-hint'" rows="1" class="min-h-9 rounded-xl border-0 bg-card/80 shadow-none" />
              <p id="knowledge-search-hint" class="text-xs text-muted-foreground">{{ label('searchHint') }}</p>
            </div>
            <p v-if="discussionPrefilled && !state.id && state.draft && writingMode === 'summary'" class="text-xs text-muted-foreground">
              {{ t('aiWriting.discussionPrefilled') }}
            </p>
            <Textarea
              v-model="state.draft"
              :disabled="state.busy"
              :placeholder="inputLabel"
              :aria-label="inputLabel"
              :aria-invalid="messageTooLong"
              :aria-describedby="messageCounterId"
              rows="2"
              class="min-h-[48px] resize-none border-0 bg-transparent px-1 py-1 shadow-none focus-visible:ring-0 dark:bg-transparent"
            />
            <div class="flex flex-wrap items-center justify-between gap-2 pt-0.5">
              <div class="flex flex-wrap items-center gap-1.5">
                <Select v-if="purpose !== 'knowledge'" v-model="writingMode" :disabled="state.busy">
                  <SelectTrigger :id="`${messageCounterId}-writing-mode`" class="h-8 w-auto gap-1.5 rounded-full border-0 bg-card/85 px-3 text-xs shadow-none">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent class="rounded-2xl">
                    <SelectItem v-for="mode in writingModes" :key="mode" :value="mode" class="rounded-xl">
                      {{ label(`modes.${mode}`) }}
                    </SelectItem>
                  </SelectContent>
                </Select>
                <button
                  v-if="purpose === 'knowledge'"
                  type="button"
                  :disabled="state.busy"
                  :aria-expanded="showSearchField"
                  class="inline-flex h-8 items-center gap-1.5 rounded-full px-3 text-xs font-medium transition-colors"
                  :class="showSearchField ? 'bg-primary/15 text-primary' : 'bg-card/85 text-muted-foreground hover:text-foreground'"
                  @click="searchExpanded = !searchExpanded"
                >
                  <Hash class="h-3.5 w-3.5" />{{ label('searchLabel') }}
                </button>
                <button
                  v-if="!state.id"
                  type="button"
                  :disabled="state.busy"
                  :aria-expanded="showTitleField"
                  class="inline-flex h-8 items-center gap-1.5 rounded-full px-3 text-xs font-medium transition-colors"
                  :class="showTitleField ? 'bg-primary/15 text-primary' : 'bg-card/85 text-muted-foreground hover:text-foreground'"
                  @click="titleExpanded = !titleExpanded"
                >
                  <Plus class="h-3.5 w-3.5" />{{ t('aiWriting.conversationTitle') }}
                </button>
                <label
                  v-if="state.skill?.explicitSelection && state.skill.enabled"
                  :for="`${messageCounterId}-explicit-skill`"
                  class="inline-flex h-8 cursor-pointer items-center gap-1.5 rounded-full px-3 text-xs font-medium transition-colors"
                  :class="state.explicitSkill ? 'bg-primary/15 text-primary' : 'bg-card/85 text-muted-foreground hover:text-foreground'"
                >
                  <Checkbox
                    :id="`${messageCounterId}-explicit-skill`"
                    :model-value="state.explicitSkill"
                    :disabled="state.busy || state.availability !== 'enabled'"
                    @update:model-value="v => state.explicitSkill = v === true"
                  />
                  <span>{{ t('aiAvailability.selectExplicitly') }}</span>
                </label>
              </div>
              <div class="flex items-center gap-2">
                <p :id="messageCounterId" class="text-xs tabular-nums" :class="messageTooLong ? 'text-destructive' : 'text-muted-foreground'">
                  {{ t('aiWriting.messageBytes', { bytes: messageBytes, limit: aiMessageMaxBytes }) }}
                </p>
                <Button v-if="state.generating" type="button" variant="secondary" size="sm" class="h-9 rounded-full border-0 px-3" @click="controller.stopGeneration()">{{ label('stopGeneration') }}</Button>
                <Button type="submit" size="icon" class="size-9 rounded-full" :disabled="state.busy || state.refreshRequired || state.availability !== 'enabled' || messageBytes === 0 || messageTooLong"><Loader2 v-if="state.busy" class="h-4 w-4 animate-spin" /><Send v-else class="h-4 w-4" /><span class="sr-only">{{ label('send') }}</span></Button>
              </div>
            </div>
          </form>
        </div>
      </div>
    </section>

    <Dialog v-model:open="historyOpen">
      <DialogContent class="max-w-md">
        <DialogHeader>
          <div class="flex items-center justify-between gap-2 pr-6">
            <DialogTitle class="flex items-center gap-2 text-base font-semibold">
              <History class="h-4 w-4 text-muted-foreground" />{{ label('history') }}
            </DialogTitle>
            <Button variant="ghost" size="sm" class="h-7 rounded-full px-2.5 text-xs" :disabled="state.historyBusy" @click="controller.loadHistory()">{{ t('common.refresh') }}</Button>
          </div>
        </DialogHeader>
        <div v-if="!state.history.length && !state.historyBusy" class="py-4">
          <AppEmptyState :title="label('historyEmpty')" compact />
        </div>
        <ul v-else class="max-h-[55vh] space-y-1 overflow-y-auto pr-1">
          <li v-for="item in state.history" :key="item.conversation_id">
            <button
              type="button"
              :disabled="state.busy"
              :aria-current="state.id === item.conversation_id ? 'true' : undefined"
              class="w-full rounded-2xl px-3.5 py-2.5 text-left text-sm transition-colors hover:bg-secondary aria-[current=true]:bg-primary/10 aria-[current=true]:font-medium"
              @click="selectHistory(item.conversation_id); historyOpen = false"
            >
              <span class="block truncate font-medium">{{ item.title || label('untitled') }}</span>
              <span class="block truncate text-xs text-muted-foreground">{{ item.updated_at || item.conversation_id }}</span>
            </button>
          </li>
        </ul>
        <Button v-if="state.historyCursor" variant="secondary" size="sm" class="w-full rounded-full border-0 text-xs" :disabled="state.historyBusy" @click="controller.loadHistory(false)">{{ t('common.loadMore') }}</Button>
      </DialogContent>
    </Dialog>

    <Dialog v-model:open="deleteOpen">
      <DialogContent><DialogHeader><DialogTitle>{{ label('deleteTitle') }}</DialogTitle><DialogDescription>{{ label('deleteDescription') }}</DialogDescription></DialogHeader><DialogFooter><Button variant="secondary" class="rounded-full border-0" @click="deleteOpen = false">{{ t('common.cancel') }}</Button><Button variant="destructive" class="rounded-full" @click="confirmDelete">{{ t('common.delete') }}</Button></DialogFooter></DialogContent>
    </Dialog>
  </div>
</template>
