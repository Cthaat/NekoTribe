<script setup lang="ts">
import { Activity, Database, Gauge, RefreshCw } from 'lucide-vue-next';
import { Button } from '@/components/ui/button';
import { getAiOperations, type AiOperations, type AiFeedback } from '@/api/v2/ai-operations';
import { authQueueFor } from '@/services/auth-request-queue';

const { t, locale } = useAppLocale();
const app = useNuxtApp();
const auth = authQueueFor(app);
const summary = ref<AiOperations | null>(null);
const loading = ref(false);
const failed = ref(false);
let request: AbortController | undefined;
let unsubscribe: (() => void) | undefined;
const label = (key: string) => t(`moderation.aiOps.${key}`);
const ratings = ['helpful', 'incorrect', 'insufficient'] as const;
const tone = { helpful: 'bg-emerald-500', incorrect: 'bg-red-500', insufficient: 'bg-amber-500' };

function clear() {
  request?.abort();
  summary.value = null;
  loading.value = false;
  failed.value = false;
}

async function load() {
  clear();
  if (auth.isIdentityChanging) return;
  const current = new AbortController();
  request = current;
  loading.value = true;
  try {
    const data = await app.runWithContext(() => getAiOperations(current.signal));
    if (!current.signal.aborted) summary.value = data;
  } catch {
    if (!current.signal.aborted) failed.value = true;
  } finally {
    if (request === current) loading.value = false;
  }
}

onMounted(() => {
  unsubscribe = auth.subscribe(clear);
  void load();
});
onBeforeUnmount(() => {
  unsubscribe?.();
  clear();
});

function time(value: number | null) {
  return value == null ? label('unavailable') : new Date(value).toLocaleString(locale.value);
}

function ratingPercent(row: AiFeedback, rating: typeof ratings[number]) {
  const total = row.helpful + row.incorrect + row.insufficient;
  return total ? 100 * row[rating] / total : 0;
}
</script>

<template>
  <section class="space-y-5 pb-8">
    <header class="flex items-center justify-between gap-3">
      <div>
        <h2 class="text-xl font-semibold">{{ label('title') }}</h2>
        <p v-if="summary" class="text-sm text-muted-foreground">
          {{ label('backend') }} {{ summary.backend }} · {{ label('revision') }} {{ summary.model_config_revision ?? label('unavailable') }}
        </p>
      </div>
      <Button variant="outline" size="sm" :disabled="loading" @click="load">
        <RefreshCw class="size-4" aria-hidden="true" />{{ t('common.refresh') }}
      </Button>
    </header>
    <p v-if="loading" role="status">{{ t('common.loading') }}</p>
    <p v-else-if="failed" role="alert" class="text-sm text-destructive">{{ label('loadFailed') }}</p>
    <template v-if="summary">
      <div class="grid gap-3 lg:grid-cols-3">
        <section class="space-y-3 rounded-xl border bg-card p-4">
          <h3 class="flex items-center gap-2 font-medium"><Activity class="size-4" aria-hidden="true" />{{ label('models') }}</h3>
          <ul class="space-y-2 text-sm">
            <li v-for="model in summary.models" :key="model.purpose" class="flex flex-wrap justify-between gap-x-2 gap-y-1">
              <span>{{ label(model.purpose) }}</span>
              <span :class="model.state === 'ready' ? 'text-emerald-600 dark:text-emerald-400' : 'text-muted-foreground'">{{ label(model.state) }}</span>
              <span v-if="model.model_id" class="w-full break-all text-xs text-muted-foreground">{{ model.provider_id }} / {{ model.model_id }} {{ model.model_version }}</span>
            </li>
          </ul>
          <p v-if="summary.nodes.length" class="break-all text-xs text-muted-foreground">{{ label('nodes') }} {{ summary.nodes.join(', ') }}</p>
        </section>
        <section class="space-y-3 rounded-xl border bg-card p-4">
          <h3 class="flex items-center gap-2 font-medium"><Gauge class="size-4" aria-hidden="true" />{{ label('quota') }}</h3>
          <template v-if="summary.global_quota.used_units != null && summary.global_quota.limit_units != null">
            <p class="text-2xl font-semibold tabular-nums">{{ summary.global_quota.used_units }} / {{ summary.global_quota.limit_units }}</p>
            <progress class="w-full" :aria-label="label('quota')" :value="summary.global_quota.used_units" :max="summary.global_quota.limit_units" />
            <p class="text-sm text-muted-foreground">{{ t('moderation.aiOps.window', { seconds: summary.global_quota.window_seconds }) }}</p>
          </template>
          <p v-else class="text-sm text-muted-foreground">{{ label('unavailable') }}</p>
        </section>
        <section class="space-y-3 rounded-xl border bg-card p-4">
          <h3 class="flex items-center gap-2 font-medium"><Database class="size-4" aria-hidden="true" />{{ label('index') }}</h3>
          <dl v-if="summary.index" class="grid grid-cols-[auto_1fr] gap-2 text-sm">
            <dt class="text-muted-foreground">{{ label('points') }}</dt><dd>{{ summary.index.point_count }}</dd>
            <dt class="text-muted-foreground">{{ label('phase') }}</dt><dd>{{ label(summary.index.phase ?? 'unavailable') }}</dd>
            <dt class="text-muted-foreground">{{ label('lastSuccess') }}</dt><dd>{{ time(summary.index.last_success_at) }}</dd>
            <dt class="text-muted-foreground">{{ label('nextSync') }}</dt><dd>{{ time(summary.index.next_at) }}</dd>
          </dl>
          <p v-else class="text-sm text-muted-foreground">{{ label('unavailable') }}</p>
        </section>
      </div>
      <section class="space-y-3 rounded-xl border bg-card p-4">
        <h3 class="font-medium">{{ label('feedback') }}</h3>
        <p class="text-sm text-muted-foreground">{{ label('feedbackBasis') }}</p>
        <p v-if="!summary.feedback.length" class="text-sm text-muted-foreground">{{ label('noFeedback') }}</p>
        <ul v-else class="divide-y">
          <li v-for="row in summary.feedback" :key="JSON.stringify([row.model_id, row.model_version, row.config_revision])" class="grid gap-2 py-3 sm:grid-cols-[1fr_1fr_auto] sm:items-center">
            <div class="break-all text-sm">
              {{ row.model_id ?? label('unavailable') }} {{ row.model_version }}
              <p class="text-xs text-muted-foreground">{{ label('revision') }} {{ row.config_revision ?? label('unavailable') }}</p>
            </div>
            <div>
              <div class="flex h-2 overflow-hidden rounded-full bg-muted" aria-hidden="true">
                <span v-for="rating in ratings" :key="rating" :class="tone[rating]" :style="{width: `${ratingPercent(row, rating)}%`}" />
              </div>
              <p class="mt-1 flex flex-wrap gap-x-3 text-xs text-muted-foreground">
                <span v-for="rating in ratings" :key="rating">{{ label(rating) }} {{ row[rating] }}</span>
              </p>
            </div>
            <p class="min-w-24 text-sm font-medium tabular-nums">{{ row.accuracy == null ? label('unavailable') : new Intl.NumberFormat(locale, {style:'percent', maximumFractionDigits:1}).format(row.accuracy) }}</p>
          </li>
        </ul>
      </section>
      <section class="space-y-3 rounded-xl border bg-card p-4">
        <h3 class="font-medium">{{ label('skills') }}</h3>
        <template v-if="summary.skills">
          <p class="text-sm text-muted-foreground">{{ label('generation') }} {{ summary.skills.generation }}</p>
          <ul class="grid gap-2 text-sm sm:grid-cols-2">
            <li v-for="skill in summary.skills.items" :key="skill.id">{{ skill.id }} v{{ skill.version }} · {{ label(skill.enabled ? 'enabled' : 'disabled') }}</li>
          </ul>
        </template>
        <p v-else class="text-sm text-muted-foreground">{{ label('unavailable') }}</p>
      </section>
    </template>
  </section>
</template>
