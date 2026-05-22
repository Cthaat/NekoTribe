<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import { toast } from 'vue-sonner';
import {
  BrainCircuit,
  Loader2,
  Settings2,
  Sparkles,
  Timer
} from 'lucide-vue-next';
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle
} from '@/components/ui/dialog';
import {
  Alert,
  AlertDescription,
  AlertTitle
} from '@/components/ui/alert';
import { Button } from '@/components/ui/button';
import { Progress } from '@/components/ui/progress';
import {
  sentimentFlowConfig,
  sentimentFlowPredict,
  v2GetSettings
} from '@/services';
import type {
  AccountSettingsVM,
  SentimentFlowPredictData,
  SentimentFlowPredictionTopKItem
} from '@/services';

const props = defineProps<{
  open: boolean;
  text: string;
  postId?: number | string;
}>();

const emit = defineEmits<{
  'update:open': [value: boolean];
}>();

const { t } = useAppLocale();
const localePath = useLocalePath();

const localOpen = computed({
  get: () => props.open,
  set: value => emit('update:open', value)
});

const loading = ref(false);
const errorMessage = ref('');
const accountSettings = ref<AccountSettingsVM | null>(null);
const prediction = ref<SentimentFlowPredictData | null>(null);
const hasRequested = ref(false);

const trimmedText = computed(() => props.text.trim());
const predictionTopK = computed<SentimentFlowPredictionTopKItem[]>(
  () => {
    return prediction.value?.prediction.top_k ?? [];
  }
);
const probabilityItems = computed(() => {
  const probabilities =
    prediction.value?.prediction.probabilities ?? {};
  return Object.entries(probabilities)
    .map(([label, score]) => ({ label, score }))
    .sort((a, b) => b.score - a.score);
});

function formatPercent(value: number): string {
  return `${(value * 100).toFixed(1)}%`;
}

function sentimentLabel(label: string): string {
  const normalized = label.toLowerCase();
  const labelKeyMap: Record<string, string> = {
    extremely_negative: 'extremelyNegative',
    clearly_negative: 'clearlyNegative',
    slightly_negative: 'slightlyNegative',
    slightly_positive: 'slightlyPositive',
    extremely_positive: 'extremelyPositive'
  };
  const mappedKey = labelKeyMap[normalized];
  if (mappedKey) {
    return t(`sentiment.labels.${mappedKey}`);
  }
  if (normalized === 'positive') {
    return t('sentiment.labels.positive');
  }
  if (normalized === 'negative') {
    return t('sentiment.labels.negative');
  }
  if (normalized === 'neutral') {
    return t('sentiment.labels.neutral');
  }
  return label || t('sentiment.labels.unknown');
}

function sentimentPillClass(label: string): string {
  const normalized = label.toLowerCase();
  if (
    normalized.includes('positive') ||
    normalized === 'positive'
  ) {
    return 'border-emerald-200/60 bg-emerald-100/60 text-emerald-700 dark:border-emerald-900/40 dark:bg-emerald-950/40 dark:text-emerald-300';
  }
  if (
    normalized.includes('negative') ||
    normalized === 'negative'
  ) {
    return 'border-rose-200/60 bg-rose-100/60 text-rose-700 dark:border-rose-900/40 dark:bg-rose-950/40 dark:text-rose-300';
  }
  return 'border-sky-200/60 bg-sky-100/60 text-sky-700 dark:border-sky-900/40 dark:bg-sky-950/40 dark:text-sky-300';
}

async function runPrediction(): Promise<void> {
  if (loading.value) {
    return;
  }

  prediction.value = null;
  errorMessage.value = '';
  loading.value = true;

  try {
    const [settings, config] = await Promise.all([
      v2GetSettings(),
      sentimentFlowConfig()
    ]);
    accountSettings.value = settings;

    if (!settings.aiSentimentEnabled) {
      return;
    }
    if (!config.enabled || !config.baseUrlConfigured) {
      errorMessage.value = t(
        'sentiment.prediction.integrationDisabled'
      );
      return;
    }
    if (!trimmedText.value) {
      errorMessage.value = t('sentiment.prediction.emptyText');
      return;
    }

    prediction.value = await sentimentFlowPredict({
      text: trimmedText.value,
      model_id: settings.aiSentimentModelId || undefined,
      return_probabilities:
        settings.aiSentimentReturnProbabilities,
      include_metadata: settings.aiSentimentIncludeMetadata,
      top_k: settings.aiSentimentTopK
    });
  } catch (error) {
    const message =
      error instanceof Error
        ? error.message
        : t('sentiment.prediction.failed');
    errorMessage.value = message;
    toast.error(t('sentiment.prediction.failed'), {
      description: message
    });
  } finally {
    loading.value = false;
  }
}

watch(
  () => props.open,
  open => {
    if (!open) {
      hasRequested.value = false;
      return;
    }
    if (hasRequested.value) {
      return;
    }
    hasRequested.value = true;
    void runPrediction();
  }
);
</script>

<template>
  <Dialog v-model:open="localOpen">
    <DialogContent
      class="overflow-hidden rounded-xl border-border/60 p-0 sm:max-w-xl"
    >
      <DialogHeader
        class="border-b border-border/60 bg-background/60 px-5 py-3 backdrop-blur"
      >
        <DialogTitle
          class="flex items-center gap-2 text-base font-semibold tracking-tight"
        >
          <span
            class="flex h-7 w-7 items-center justify-center rounded-md bg-violet-500/10 text-violet-600 dark:text-violet-400"
          >
            <BrainCircuit class="h-4 w-4" />
          </span>
          {{ t('sentiment.prediction.title') }}
        </DialogTitle>
        <p class="pl-9 text-xs text-muted-foreground">
          {{ t('sentiment.prediction.description') }}
        </p>
      </DialogHeader>

      <div class="grid gap-4 px-5 py-4">
        <div
          v-if="loading"
          class="flex items-center gap-3 rounded-lg border border-border/60 bg-muted/20 p-4 text-sm text-muted-foreground"
        >
          <Loader2 class="h-4 w-4 animate-spin" />
          {{ t('sentiment.prediction.loading') }}
        </div>

        <Alert
          v-else-if="
            accountSettings && !accountSettings.aiSentimentEnabled
          "
          class="rounded-lg border-border/60"
        >
          <Settings2 class="h-4 w-4" />
          <AlertTitle>
            {{ t('sentiment.prediction.disabledTitle') }}
          </AlertTitle>
          <AlertDescription>
            {{ t('sentiment.prediction.disabledDescription') }}
          </AlertDescription>
        </Alert>

        <Alert
          v-else-if="errorMessage"
          variant="destructive"
          class="rounded-lg"
        >
          <AlertTitle>
            {{ t('sentiment.prediction.failed') }}
          </AlertTitle>
          <AlertDescription>{{ errorMessage }}</AlertDescription>
        </Alert>

        <div v-else-if="prediction" class="grid gap-3">
          <div
            class="rounded-lg border border-border/60 bg-card p-4"
          >
            <div
              class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"
            >
              <div class="grid gap-1.5">
                <div class="text-[11px] uppercase tracking-wider text-muted-foreground">
                  {{ t('sentiment.prediction.primaryLabel') }}
                </div>
                <span
                  class="inline-flex w-fit items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-xs font-medium"
                  :class="sentimentPillClass(prediction.prediction.label)"
                >
                  <Sparkles class="h-3 w-3" />
                  {{
                    sentimentLabel(prediction.prediction.label)
                  }}
                </span>
              </div>
              <div class="grid grid-cols-2 gap-4 text-sm">
                <div class="grid gap-1">
                  <div class="text-[11px] uppercase tracking-wider text-muted-foreground">
                    {{ t('sentiment.prediction.score') }}
                  </div>
                  <div class="font-semibold tabular-nums">
                    {{
                      formatPercent(prediction.prediction.score)
                    }}
                  </div>
                </div>
                <div class="grid gap-1">
                  <div class="text-[11px] uppercase tracking-wider text-muted-foreground">
                    {{ t('sentiment.prediction.confidence') }}
                  </div>
                  <div class="font-semibold tabular-nums">
                    {{
                      formatPercent(
                        prediction.prediction.confidence
                      )
                    }}
                  </div>
                </div>
              </div>
            </div>

            <div
              class="mt-4 grid gap-3 border-t border-border/60 pt-4 text-sm sm:grid-cols-2"
            >
              <div class="grid gap-1">
                <div class="text-[11px] uppercase tracking-wider text-muted-foreground">
                  {{ t('sentiment.prediction.model') }}
                </div>
                <div class="font-medium">
                  {{ prediction.model.name }}
                </div>
                <div class="text-[11px] text-muted-foreground">
                  {{ prediction.model.id }} · v{{
                    prediction.model.version
                  }}
                </div>
              </div>
              <div class="grid gap-1">
                <div class="text-[11px] uppercase tracking-wider text-muted-foreground">
                  {{ t('sentiment.prediction.timing') }}
                </div>
                <div class="flex items-center gap-1.5 font-medium tabular-nums">
                  <Timer class="h-3.5 w-3.5 text-muted-foreground" />
                  {{ prediction.timing_ms }} ms
                </div>
                <div class="text-[11px] text-muted-foreground">
                  {{ prediction.created_at }}
                </div>
              </div>
            </div>
          </div>

          <div
            v-if="probabilityItems.length > 0"
            class="rounded-lg border border-border/60 bg-card p-4"
          >
            <div class="mb-3 text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              {{ t('sentiment.prediction.probabilities') }}
            </div>
            <div class="grid gap-3">
              <div
                v-for="item in probabilityItems"
                :key="item.label"
                class="grid gap-1.5"
              >
                <div
                  class="flex items-center justify-between text-sm"
                >
                  <span>{{ sentimentLabel(item.label) }}</span>
                  <span class="font-medium tabular-nums">
                    {{ formatPercent(item.score) }}
                  </span>
                </div>
                <Progress
                  :model-value="Math.round(item.score * 100)"
                  class="h-1.5"
                />
              </div>
            </div>
          </div>

          <div
            v-if="predictionTopK.length > 0"
            class="rounded-lg border border-border/60 bg-card p-4"
          >
            <div class="mb-3 text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              {{ t('sentiment.prediction.topK') }}
            </div>
            <div class="flex flex-wrap gap-1.5">
              <span
                v-for="item in predictionTopK"
                :key="item.label"
                class="inline-flex items-center gap-1 rounded-full border border-border/60 bg-muted/40 px-2 py-0.5 text-[11px] font-medium tabular-nums text-foreground"
              >
                {{ sentimentLabel(item.label) }}
                {{ formatPercent(item.score) }}
              </span>
            </div>
          </div>

          <div
            v-if="prediction.input"
            class="rounded-lg border border-border/60 bg-muted/20 p-4 text-sm"
          >
            <div class="mb-3 text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              {{ t('sentiment.prediction.metadata') }}
            </div>
            <div class="grid gap-3 sm:grid-cols-3">
              <div class="grid gap-1">
                <div class="text-[11px] text-muted-foreground">
                  {{ t('sentiment.prediction.language') }}
                </div>
                <div class="font-medium">
                  {{ prediction.input.language }}
                </div>
              </div>
              <div class="grid gap-1">
                <div class="text-[11px] text-muted-foreground">
                  {{ t('sentiment.prediction.length') }}
                </div>
                <div class="font-medium tabular-nums">
                  {{ prediction.input.length }}
                </div>
              </div>
              <div class="grid gap-1">
                <div class="text-[11px] text-muted-foreground">
                  {{ t('sentiment.prediction.requestId') }}
                </div>
                <div class="truncate font-mono text-[11px]">
                  {{ prediction.request_id }}
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <DialogFooter
        class="flex flex-col-reverse gap-2 border-t border-border/60 bg-background/60 px-5 py-3 backdrop-blur sm:flex-row sm:justify-end"
      >
        <Button
          v-if="
            accountSettings && !accountSettings.aiSentimentEnabled
          "
          as-child
          variant="outline"
          class="h-9 rounded-md shadow-xs"
        >
          <NuxtLink :to="localePath('/account/settings')">
            <Settings2 class="h-3.5 w-3.5" />
            {{ t('sentiment.actions.openSettings') }}
          </NuxtLink>
        </Button>
        <Button
          v-else
          variant="outline"
          class="h-9 rounded-md shadow-xs"
          :disabled="loading"
          @click="runPrediction"
        >
          <Loader2
            v-if="loading"
            class="h-3.5 w-3.5 animate-spin"
          />
          <Sparkles v-else class="h-3.5 w-3.5" />
          {{ t('sentiment.actions.retryPredict') }}
        </Button>
        <Button
          class="h-9 rounded-md shadow-xs"
          @click="localOpen = false"
        >
          {{ t('common.close') }}
        </Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>
</template>
