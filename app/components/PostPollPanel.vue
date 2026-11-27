<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, shallowRef, watch } from 'vue';
import { Button } from '@/components/ui/button';
import { usePreferenceStore } from '@/stores/user';
import { v2GetPostPoll, v2VotePostPoll } from '@/api/v2/post-polls';
import type { V2PostPoll } from '@/types/v2';
import policy from '../../specifications/requirements/post-polls.json';

const props = defineProps<{ poll: V2PostPoll; postId: number; groupId?: number; canVote: boolean }>();
const { t, locale } = useAppLocale();
const app = useNuxtApp();
const preferences = usePreferenceStore();
const poll = shallowRef<V2PostPoll | null>(props.poll);
const panel = ref<HTMLElement | null>(null);
const intersecting = ref(false);
const foreground = ref(false);
const selected = ref<number[]>([]);
const busy = ref(false);
const missing = ref(false);
const voteFailed = ref(false);
let request: AbortController | undefined;
let timer: ReturnType<typeof setInterval> | undefined;
let observer: IntersectionObserver | undefined;

const canChoose = computed(() => !!poll.value && !poll.value.closed && !poll.value.my_option_ids.length && props.canVote);
const shouldRefresh = computed(() => foreground.value && intersecting.value && !poll.value?.closed && !missing.value);
const formattedCutoff = computed(() => poll.value ? new Date(poll.value.closes_at).toLocaleString(locale.value, {
  dateStyle:'short',timeStyle:'short',
}) : '');

function updateForeground() { foreground.value = document.visibilityState === 'visible'; }

function select(id: number) {
  if (!canChoose.value || busy.value) return;
  selected.value = selected.value.includes(id) ? selected.value.filter(item=>item!==id) :
    poll.value?.multiple ? [...selected.value,id] : [id];
}

async function update(choices?: number[]) {
  if (request && (!choices || busy.value)) return;
  request?.abort();
  const controller = new AbortController();
  request = controller;
  const revision = preferences.authRevision();
  const postId = props.postId;
  const groupId = props.groupId;
  const expected = props.poll.poll_id;
  const current = () => request === controller && preferences.isAuthCurrent(revision) &&
    props.postId === postId && props.groupId === groupId && props.poll.poll_id === expected;
  if (choices) { busy.value = true; voteFailed.value = false; }
  try {
    const result = await app.runWithContext(() => choices
      ? v2VotePostPoll(postId,groupId,expected,choices,controller.signal)
      : v2GetPostPoll(postId,groupId,expected,controller.signal));
    if (current()) { poll.value = result; missing.value = false; }
  } catch (error) {
    if (!current()) return;
    if (choices) voteFailed.value = true;
    const status = error && typeof error === 'object' && 'statusCode' in error ? error.statusCode : null;
    if (status === 404 || (!choices && (status === 401 || status === 403))) {
      poll.value = null;
      missing.value = true;
    }
  } finally {
    if (request === controller) { request = undefined; busy.value = false; }
  }
}

function resetRequest() {
  request?.abort();
  request = undefined;
  busy.value = false;
  selected.value = [];
  missing.value = voteFailed.value = false;
}

watch([() => props.postId, () => props.groupId, () => props.poll.poll_id], () => { resetRequest(); poll.value = props.poll; });
watch(() => props.poll, latest => { if (!missing.value && !request) poll.value = latest; });
watch([() => preferences.preferences.user.id, () => preferences.preferences.authSession?.sessionId], () => {
  resetRequest();
  poll.value = null;
  if (shouldRefresh.value) void update();
}, {flush:'sync'});
watch(shouldRefresh, active => {
  clearInterval(timer);
  timer = active ? setInterval(() => { void update(); },policy.refresh_interval_ms) : undefined;
  if (active && poll.value === null) void update();
});

onMounted(() => {
  updateForeground();
  document.addEventListener('visibilitychange',updateForeground);
  if (typeof IntersectionObserver === 'undefined') return;
  observer = new IntersectionObserver(([entry])=>{ intersecting.value = !!entry?.isIntersecting; });
  if (panel.value) observer.observe(panel.value);
});
onBeforeUnmount(() => {
  observer?.disconnect();
  document.removeEventListener('visibilitychange',updateForeground);
  clearInterval(timer);
  resetRequest();
});
</script>

<template>
  <section ref="panel" v-show="!missing"
    :class="poll ? 'bento-tile space-y-2.5 p-3.5' : 'h-px'" @click.stop>
    <template v-if="poll">
      <div class="flex flex-wrap items-center justify-between gap-x-2 gap-y-1">
        <p class="text-sm font-semibold">{{ t(poll.multiple ? 'post.poll.multiple' : 'post.poll.single') }}</p>
        <p class="text-xs text-muted-foreground">
          {{ poll.closed ? t('post.poll.closed') : t('post.poll.until', {time:formattedCutoff}) }}
        </p>
      </div>
      <div v-for="option in poll.options" :key="option.option_id" class="space-y-1">
        <button v-if="canChoose" type="button" :aria-pressed="selected.includes(option.option_id)" :disabled="busy"
          class="flex w-full items-center justify-between gap-2 rounded-[12px] border border-transparent bg-card px-3 py-2 text-left text-sm transition-colors hover:bg-accent"
          :class="{ 'border-primary text-primary':selected.includes(option.option_id) }" @click="select(option.option_id)">
          <span class="break-words">{{ option.text }}</span><span class="shrink-0 text-xs tabular-nums">{{ option.percent }}%</span>
        </button>
        <div v-else class="flex items-center justify-between gap-2 text-sm" :class="{ 'font-medium text-primary':poll.my_option_ids.includes(option.option_id) }">
          <span class="break-words">{{ option.text }}</span><span class="shrink-0 text-xs tabular-nums">{{ option.percent }}%</span>
        </div>
        <div class="flex items-center gap-2">
          <progress :value="option.percent" max="100" :aria-label="option.text" class="h-1.5 min-w-0 flex-1 overflow-hidden rounded bg-muted accent-primary" />
          <span class="text-xs tabular-nums text-muted-foreground">{{ t('post.poll.votes', {count:option.votes_count}) }}</span>
        </div>
      </div>
      <div class="flex flex-wrap items-center justify-between gap-2 pt-1">
        <span class="text-xs text-muted-foreground">{{ t('post.poll.ballots', {count:poll.total_ballots}) }}<template v-if="poll.my_option_ids.length"> · {{ t('post.poll.voted') }}</template></span>
        <Button v-if="canChoose" type="button" size="sm" :disabled="busy || !selected.length" @click="update([...selected])">{{ t('post.poll.vote') }}</Button>
      </div>
      <p v-if="voteFailed" class="text-xs text-destructive" role="alert">{{ t('post.poll.voteFailed') }}</p>
    </template>
  </section>
</template>
