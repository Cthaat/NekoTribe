<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, shallowRef, watch } from 'vue';
import { Button } from '@/components/ui/button';
import { createModerationAdviceApi, moderationAdviceTarget, moderationRatings } from '@/api/v2/ai-moderation-advice';
import type { ModerationAdviceHistory, ModerationAdviceMessage, ModerationAdviceSource, ModerationRating } from '@/api/v2/ai-moderation-advice';
import { authQueueFor } from '@/services/auth-request-queue';
import { aiQuotaRetry } from '@/services/ai-quota-notice';
import { getAiAvailability, aiWorkflowAvailability } from '@/api/v2/ai-availability';
import type { AiAvailabilityState, AiSkillSummary } from '@/services/ai-writing-controller';
import AiSkillStatus from '@/components/AiSkillStatus.vue';

const props = defineProps<{ kind: string; targetId: number }>();
const { t, locale } = useAppLocale();
const localePath = useLocalePath();
const label = (key: string) => t(`moderationAdvice.${key}`);
const app = useNuxtApp();
const auth = authQueueFor(app);
const owner = auth.revision;
const api = createModerationAdviceApi(request => app.runWithContext(request));
const target = computed(() => moderationAdviceTarget(props.kind, props.targetId));
function sourceHref(source: ModerationAdviceSource): string {
  const { postId, groupId, commentId } = source;
  if (groupId !== null) {
    return localePath({
      path: '/groups/posts',
      query: { group: groupId, post: postId, ...(commentId === null ? {} : { comment: commentId }) }
    });
  }
  return localePath({
    path: `/tweet/${postId}`,
    query: commentId === null ? {} : { comment: commentId }
  });
}
const open = ref(false);
type AdviceTarget = NonNullable<typeof target.value>;
type Request = 'history' | 'older' | 'generate' | 'remove' | {message: ModerationAdviceMessage; rating: ModerationRating};
const busy = ref<'history' | 'older' | 'generate' | 'feedback' | 'remove' | null>(null);
const generating = ref(false);
const history = ref<ModerationAdviceHistory | null>(null);
const deleteConfirm = shallowRef<{
  history: ModerationAdviceHistory; target: AdviceTarget; id: string; message?: ModerationAdviceMessage;
} | null>(null);
const latestHistoricalMessageIds = computed(() => {
  const current = history.value;
  const ids = new Map<string, string>();
  for (const message of current?.messages ?? []) {
    if (message.conversationId !== current?.conversationId && !ids.has(message.conversationId)) {
      ids.set(message.conversationId, message.id);
    }
  }
  return ids;
});
const availability = ref<AiAvailabilityState>('loading');
const skill = ref<AiSkillSummary>();
const modelConfigRevision = ref<number>();
const explicitSkill = ref(false);
const notice = ref<string | null>(null);
const quotaRetry = ref(0);
const statusLabel = computed(() =>
  busy.value === 'generate' ? 'generating' : busy.value === 'history' || busy.value === 'older' ? 'loading' :
    busy.value === 'feedback' ? 'feedbackSaving' : busy.value === 'remove' ? 'deleting' : notice.value
);
const expired = ref(auth.isIdentityChanging);
let active: AbortController | null = null;

function clear() {
  active?.abort();
  active = null;
  busy.value = null;
  generating.value = false;
  history.value = null;
  deleteConfirm.value = null;
  availability.value = 'loading';
  skill.value = undefined;
  modelConfigRevision.value = undefined;
  explicitSkill.value = false;
  notice.value = null;
}
function checkOwner() {
  if (auth.revision === owner && !auth.isIdentityChanging) return;
  expired.value = true;
  clear();
}
let stop: (() => void) | undefined;
onMounted(() => {
  stop = auth.subscribe(checkOwner);
  checkOwner();
});
onBeforeUnmount(() => {
  stop?.();
  active?.abort();
  active = null;
});
watch(target, () => {
  clear();
  if (open.value) void load('history');
});

function formattedDate(value: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '';
  return new Intl.DateTimeFormat(locale.value === 'en' ? 'en' : 'zh', {
    dateStyle: 'medium', timeStyle: 'short',
  }).format(date);
}

async function load(request: Request) {
  const currentTarget = target.value;
  if (!currentTarget || active || !open.value || expired.value || auth.isIdentityChanging || auth.revision !== owner) return;
  const previous = history.value;
  const feedback = typeof request === 'object' ? request : null;
  const deleteId = request === 'remove' && previous === deleteConfirm.value?.history &&
    currentTarget === deleteConfirm.value?.target ? deleteConfirm.value.id : null;
  if (request === 'remove' && !deleteId) return;
  if (request === 'generate' && (!previous || availability.value !== 'enabled')) return;
  if (request === 'older' && !previous?.older.size) return;
  if (feedback && (!feedback.message.advice || feedback.message.rating === feedback.rating ||
      !previous?.messages.includes(feedback.message))) return;
  const controller = new AbortController();
  const { signal } = controller;
  const valid = () => active === controller && !expired.value && open.value &&
    !signal.aborted && !auth.isIdentityChanging && auth.revision === owner && target.value === currentTarget;
  active = controller;
  busy.value = typeof request === 'string' ? request : 'feedback';
  deleteConfirm.value = null;
  if (!feedback && request !== 'older') history.value = null;
  notice.value = null;
  let generationSaved = false;
  try {
    let insufficient = false;
    if (request === 'generate' && previous) {
      const id = previous.conversationId ?? await api.create(currentTarget, signal);
      if (!valid()) return;
      generating.value = true;
      const skillId = explicitSkill.value && skill.value?.explicitSelection && skill.value.enabled ? 'moderation-advice' : undefined;
      insufficient = !await api.generate(id, currentTarget, locale.value === 'en' ? 'en' : 'zh', previous.sequence, signal, skillId);
      if (!valid()) return;
      generationSaved = !insufficient;
      generating.value = false;
    }
    if (feedback && previous) {
      const confirmed = await api.rate(feedback.message, feedback.rating, currentTarget, signal);
      if (!valid()) return;
      history.value = confirmed ? {
        ...previous,
        messages: previous.messages.map(message => message === feedback.message ? confirmed : message)
      } : null;
      notice.value = confirmed ? 'feedbackSaved' : 'conflict';
      return;
    }
    if (deleteId) {
      await api.remove(deleteId, signal);
      if (!valid()) return;
    }
    const status = request === 'history' ? app.runWithContext(() => getAiAvailability(signal)).then(
      flags => {
        if (!valid()) return;
        availability.value = aiWorkflowAvailability(flags, 'moderation');
        skill.value = flags.skills?.find(item => item.purpose === 'moderation');
        modelConfigRevision.value = flags.modelConfigRevision;
      },
      () => { if (valid()) availability.value = 'unknown'; }
    ) : Promise.resolve();
    if (request === 'history') {
      availability.value = 'loading';
      skill.value = undefined;
      modelConfigRevision.value = undefined;
      explicitSkill.value = false;
    }
    const pending = request === 'older' && previous
      ? api.older(previous, currentTarget, signal)
      : api.history(currentTarget, signal);
    const [result] = await Promise.all([pending, status]);
    if (!valid()) return;
    history.value = result;
    if (insufficient) notice.value = 'insufficient';
    else if (deleteId) notice.value = 'deleted';
  } catch (error) {
    if (!valid()) return;
    const retry = request === 'generate' ? aiQuotaRetry(error) : null;
    if (retry !== null) {
      quotaRetry.value = retry;
      history.value = previous;
      notice.value = 'quota';
      return;
    }
    const status = (error as {statusCode?: number; status?: number})?.statusCode ??
      (error as {status?: number})?.status;
    history.value = null;
    notice.value = deleteId ? 'deleteUnknown' :
      generationSaved && status !== 401 && status !== 403 && status !== 404 ? 'generationSaved' :
      status === 409 || (feedback && status === 404) ? 'conflict' :
      status === 503 ? (feedback ? 'feedbackUnavailable' : 'unavailable') :
      status === 401 || status === 403 ? 'forbidden' : (feedback ? 'feedbackFailed' : 'failed');
  } finally {
    if (active === controller) {
      active = null;
      busy.value = null;
      generating.value = false;
    }
  }
}

function stopGeneration() {
  if (!generating.value || !active) return;
  const controller = active;
  active = null;
  controller.abort();
  busy.value = null;
  generating.value = false;
  notice.value = 'generationStopped';
}

function toggle() {
  open.value = !open.value;
  clear();
  if (open.value) void load('history');
}

function askDelete(message?: ModerationAdviceMessage) {
  const current = history.value, currentTarget = target.value;
  if (!current || !currentTarget || busy.value || expired.value) return;
  if (message && !current.messages.includes(message)) return;
  const id = message?.conversationId ?? current.conversationId;
  if (id) deleteConfirm.value = {history: current, target: currentTarget, id, message};
}
</script>

<template>
  <section v-if="target" class="grid min-w-0 gap-3">
    <Button type="button" size="sm" variant="outline" class="w-fit" :aria-expanded="open" @click="toggle">
      {{ label(open ? 'hide' : 'title') }}
    </Button>
    <div v-if="open" class="grid gap-3 rounded-md border border-border/60 p-3 text-sm" :aria-busy="busy !== null">
      <p v-if="expired" role="status">{{ label('sessionChanged') }}</p>
      <template v-else>
        <p class="text-muted-foreground">{{ label('description') }}</p>
        <div class="flex flex-wrap gap-2">
          <Button type="button" size="sm" variant="secondary" :disabled="!history || busy !== null || availability !== 'enabled'" @click="load('generate')">
            {{ label('generate') }}
          </Button>
          <Button v-if="generating" type="button" size="sm" variant="outline" @click="stopGeneration">
            {{ label('stopGeneration') }}
          </Button>
          <Button type="button" size="sm" variant="ghost" :disabled="busy !== null" @click="load('history')">
            {{ label('refresh') }}
          </Button>
          <Button v-if="history?.conversationId && !deleteConfirm" type="button" size="sm" variant="outline" :disabled="busy !== null" @click="askDelete()">
            {{ label('deleteConversation') }}
          </Button>
        </div>
        <div v-if="deleteConfirm" class="grid gap-2 rounded-md border p-3" :aria-label="label('deleteConversation')" role="group">
          <p>{{ label(deleteConfirm.message ? 'deleteHistoricalPrompt' : 'deletePrompt') }}</p>
          <time v-if="deleteConfirm.message" :datetime="deleteConfirm.message.createdAt">
            {{ formattedDate(deleteConfirm.message.createdAt) }}
          </time>
          <div class="flex flex-wrap gap-2">
            <Button type="button" size="sm" variant="outline" @click="deleteConfirm = null">{{ t('common.cancel') }}</Button>
            <Button type="button" size="sm" variant="destructive" @click="load('remove')">{{ label('confirmDelete') }}</Button>
          </div>
        </div>
        <AiSkillStatus v-if="skill || modelConfigRevision !== undefined || availability !== 'enabled'" :availability="availability" :skill="skill" :model-config-revision="modelConfigRevision" />
        <label v-if="skill?.explicitSelection && skill.enabled" class="flex items-center gap-2 text-sm">
          <input v-model="explicitSkill" type="checkbox" :disabled="busy !== null || availability !== 'enabled'" />
          {{ t('aiAvailability.selectExplicitly') }}
        </label>
        <p v-if="statusLabel" role="status">
          {{ statusLabel === 'quota' ? t(quotaRetry ? 'aiGroupDraft.quotaRetry' : 'aiGroupDraft.quota', {seconds: quotaRetry}) : label(statusLabel) }}
        </p>
        <template v-if="history">
          <p v-if="!notice && !history.messages.length" class="text-muted-foreground">{{ label('empty') }}</p>
          <article v-for="message in history.messages" :key="`${message.conversationId}:${message.id}`" class="grid gap-2 border-t border-border/60 pt-3">
            <time :datetime="message.createdAt" class="text-xs text-muted-foreground">{{ formattedDate(message.createdAt) }}</time>
            <Button v-if="!deleteConfirm && latestHistoricalMessageIds.get(message.conversationId) === message.id" type="button" size="sm" variant="outline" class="w-fit" :disabled="busy !== null" @click="askDelete(message)">
              {{ label('deleteHistoricalConversation') }}
            </Button>
            <p v-if="!message.advice" class="text-muted-foreground">{{ label('expired') }}</p>
            <template v-else>
              <p class="font-medium">{{ label(`risk.${message.advice.risk}`) }} · {{ label(`recommendation.${message.advice.recommendation}`) }}</p>
              <p class="whitespace-pre-wrap break-words">{{ message.advice.reason }}</p>
              <a v-if="message.advice.source" :href="sourceHref(message.advice.source)"
                target="_blank" rel="noopener noreferrer" class="w-fit text-primary underline underline-offset-4">
                {{ label('openSource') }}
              </a>
              <p v-if="message.modelVersion" class="break-all text-xs text-muted-foreground">
                {{ t('aiModelVersion') }} · {{ message.modelVersion }}
              </p>
              <p v-if="message.configRevision !== null" class="text-xs text-muted-foreground">
                {{ t('aiReplyConfigRevision', { revision: message.configRevision }) }}
              </p>
              <ul class="space-y-1">
                <li v-for="rule in message.advice.rules" :key="rule.id">
                  <a :href="rule.href" target="_blank" rel="noopener noreferrer" :title="rule.version" class="break-words text-primary underline underline-offset-4">
                    {{ t('moderationAdvice.rule', { id: rule.id, version: rule.version.slice(0, 8) }) }}
                  </a>
                </li>
              </ul>
              <div role="group" :aria-label="label('feedbackLabel')" class="flex flex-wrap gap-2">
                <Button
                  v-for="rating in moderationRatings"
                  :key="rating"
                  type="button"
                  size="sm"
                  :variant="message.rating === rating ? 'secondary' : 'outline'"
                  :aria-pressed="message.rating === rating"
                  :disabled="busy !== null"
                  @click="load({message, rating})"
                >
                  {{ label(`feedback.${rating}`) }}
                </Button>
              </div>
            </template>
          </article>
          <Button v-if="history.older.size && !deleteConfirm" type="button" size="sm" variant="ghost" :disabled="busy !== null" @click="load('older')">
            {{ t('chat.directMessage.loadOlder') }}
          </Button>
        </template>
      </template>
    </div>
  </section>
</template>
