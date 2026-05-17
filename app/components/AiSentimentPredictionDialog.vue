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
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle
} from '@/components/ui/dialog';
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Progress } from '@/components/ui/progress';
import { Separator } from '@/components/ui/separator';
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
const predictionTopK = computed<SentimentFlowPredictionTopKItem[]>(() => {
  return prediction.value?.prediction.top_k ?? [];
});
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

function sentimentClass(label: string): string {
  const normalized = label.toLowerCase();
  if (normalized === 'positive') {
    return 'border-emerald-500/30 bg-emerald-500/10 text-emerald-600 dark:text-emerald-400';
  }
  if (normalized === 'negative') {
    return 'border-red-500/30 bg-red-500/10 text-red-600 dark:text-red-400';
  }
  return 'border-sky-500/30 bg-sky-500/10 text-sky-600 dark:text-sky-400';
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
    <DialogContent class="sm:max-w-xl">
      <DialogHeader>
        <DialogTitle class="flex items-center gap-2">
          <BrainCircuit class="h-5 w-5 text-primary" />
          {{ t('sentiment.prediction.title') }}
        </DialogTitle>
        <DialogDescription>
          {{ t('sentiment.prediction.description') }}
        </DialogDescription>
      </DialogHeader>

      <div class="space-y-4">
        <div
          v-if="loading"
          class="flex items-center gap-3 rounded-md border p-4 text-sm text-muted-foreground"
        >
          <Loader2 class="h-4 w-4 animate-spin" />
          {{ t('sentiment.prediction.loading') }}
        </div>

        <Alert
          v-else-if="accountSettings && !accountSettings.aiSentimentEnabled"
        >
          <Settings2 class="h-4 w-4" />
          <AlertTitle>
            {{ t('sentiment.prediction.disabledTitle') }}
          </AlertTitle>
          <AlertDescription>
            {{ t('sentiment.prediction.disabledDescription') }}
          </AlertDescription>
        </Alert>

        <Alert v-else-if="errorMessage" variant="destructive">
          <AlertTitle>
            {{ t('sentiment.prediction.failed') }}
          </AlertTitle>
          <AlertDescription>{{ errorMessage }}</AlertDescription>
        </Alert>

        <div v-else-if="prediction" class="space-y-4">
          <div class="rounded-md border p-4">
            <div
              class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"
            >
              <div class="space-y-2">
                <div class="text-sm text-muted-foreground">
                  {{ t('sentiment.prediction.primaryLabel') }}
                </div>
                <Badge
                  variant="outline"
                  :class="sentimentClass(prediction.prediction.label)"
                >
                  <Sparkles class="h-3 w-3" />
                  {{
                    sentimentLabel(prediction.prediction.label)
                  }}
                </Badge>
              </div>
              <div class="grid grid-cols-2 gap-4 text-sm">
                <div>
                  <div class="text-muted-foreground">
                    {{ t('sentiment.prediction.score') }}
                  </div>
                  <div class="font-medium">
                    {{
                      formatPercent(prediction.prediction.score)
                    }}
                  </div>
                </div>
                <div>
                  <div class="text-muted-foreground">
                    {{ t('sentiment.prediction.confidence') }}
                  </div>
                  <div class="font-medium">
                    {{
                      formatPercent(
                        prediction.prediction.confidence
                      )
                    }}
                  </div>
                </div>
              </div>
            </div>

            <Separator class="my-4" />

            <div class="grid gap-3 text-sm sm:grid-cols-2">
              <div>
                <div class="text-muted-foreground">
                  {{ t('sentiment.prediction.model') }}
                </div>
                <div class="font-medium">
                  {{ prediction.model.name }}
                </div>
                <div class="text-xs text-muted-foreground">
                  {{ prediction.model.id }} · v{{
                    prediction.model.version
                  }}
                </div>
              </div>
              <div>
                <div class="text-muted-foreground">
                  {{ t('sentiment.prediction.timing') }}
                </div>
                <div class="flex items-center gap-2 font-medium">
                  <Timer class="h-4 w-4 text-muted-foreground" />
                  {{ prediction.timing_ms }} ms
                </div>
                <div class="text-xs text-muted-foreground">
                  {{ prediction.created_at }}
                </div>
              </div>
            </div>
          </div>

          <div
            v-if="probabilityItems.length > 0"
            class="rounded-md border p-4"
          >
            <div class="mb-3 text-sm font-medium">
              {{ t('sentiment.prediction.probabilities') }}
            </div>
            <div class="space-y-3">
              <div
                v-for="item in probabilityItems"
                :key="item.label"
                class="space-y-1.5"
              >
                <div
                  class="flex items-center justify-between text-sm"
                >
                  <span>{{ sentimentLabel(item.label) }}</span>
                  <span class="font-medium">
                    {{ formatPercent(item.score) }}
                  </span>
                </div>
                <Progress
                  :model-value="Math.round(item.score * 100)"
                />
              </div>
            </div>
          </div>

          <div
            v-if="predictionTopK.length > 0"
            class="rounded-md border p-4"
          >
            <div class="mb-3 text-sm font-medium">
              {{ t('sentiment.prediction.topK') }}
            </div>
            <div class="flex flex-wrap gap-2">
              <Badge
                v-for="item in predictionTopK"
                :key="item.label"
                variant="secondary"
              >
                {{ sentimentLabel(item.label) }}
                {{ formatPercent(item.score) }}
              </Badge>
            </div>
          </div>

          <div
            v-if="prediction.input"
            class="rounded-md border bg-muted/30 p-4 text-sm"
          >
            <div class="mb-2 font-medium">
              {{ t('sentiment.prediction.metadata') }}
            </div>
            <div class="grid gap-2 sm:grid-cols-3">
              <div>
                <div class="text-muted-foreground">
                  {{ t('sentiment.prediction.language') }}
                </div>
                <div>{{ prediction.input.language }}</div>
              </div>
              <div>
                <div class="text-muted-foreground">
                  {{ t('sentiment.prediction.length') }}
                </div>
                <div>{{ prediction.input.length }}</div>
              </div>
              <div>
                <div class="text-muted-foreground">
                  {{ t('sentiment.prediction.requestId') }}
                </div>
                <div class="truncate">
                  {{ prediction.request_id }}
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <DialogFooter class="gap-2 sm:gap-0">
        <Button
          v-if="accountSettings && !accountSettings.aiSentimentEnabled"
          as-child
          variant="outline"
        >
          <NuxtLink :to="localePath('/account/settings')">
            <Settings2 class="mr-2 h-4 w-4" />
            {{ t('sentiment.actions.openSettings') }}
          </NuxtLink>
        </Button>
        <Button
          v-else
          variant="outline"
          :disabled="loading"
          @click="runPrediction"
        >
          <Loader2
            v-if="loading"
            class="mr-2 h-4 w-4 animate-spin"
          />
          {{ t('sentiment.actions.retryPredict') }}
        </Button>
        <Button @click="localOpen = false">
          {{ t('common.close') }}
        </Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>
</template>
