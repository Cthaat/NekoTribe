<script setup lang="ts">
import {
  computed,
  onBeforeUnmount,
  onMounted,
  ref
} from 'vue';
import { toast } from 'vue-sonner';
import {
  Activity,
  BrainCircuit,
  CheckCircle2,
  CircleOff,
  Loader2,
  Play,
  RefreshCw,
  Save,
  SlidersHorizontal,
  Square,
  TestTube2
} from 'lucide-vue-next';
import {
  Alert,
  AlertDescription,
  AlertTitle
} from '@/components/ui/alert';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Progress } from '@/components/ui/progress';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@/components/ui/select';
import { Switch } from '@/components/ui/switch';
import {
  Table,
  TableBody,
  TableCell,
  TableEmpty,
  TableHead,
  TableHeader,
  TableRow
} from '@/components/ui/table';
import {
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger
} from '@/components/ui/tabs';
import { Textarea } from '@/components/ui/textarea';
import {
  sentimentFlowCancelTraining,
  sentimentFlowConfig,
  sentimentFlowGetActiveModel,
  sentimentFlowGetTrainingStatus,
  sentimentFlowListModels,
  sentimentFlowListTrainingJobs,
  sentimentFlowPredict,
  sentimentFlowSetActiveModel,
  sentimentFlowStartTraining,
  sentimentFlowStatsOverview,
  sentimentFlowTrainingStreamUrl,
  v2GetSettings,
  v2PatchSettings
} from '@/services';
import type {
  AccountSettingsVM,
  SentimentFlowActiveModelData,
  SentimentFlowIntegrationConfig,
  SentimentFlowModelItem,
  SentimentFlowPredictData,
  SentimentFlowStatsOverviewData,
  SentimentFlowTrainingJobItem,
  SentimentFlowTrainingStatusData
} from '@/services';

type StatusTone =
  | 'primary'
  | 'emerald'
  | 'sky'
  | 'amber'
  | 'rose'
  | 'muted';
type TrainingStatusFilter =
  | 'all'
  | 'queued'
  | 'running'
  | 'succeeded'
  | 'failed'
  | 'cancelled';

interface TrainingLogItem {
  id: number;
  event: string;
  message: string;
  time: string;
}

const ACTIVE_MODEL_VALUE = '__active__';
const TRAINING_STATUS_FILTERS: TrainingStatusFilter[] = [
  'all',
  'queued',
  'running',
  'succeeded',
  'failed',
  'cancelled'
];

const { t, locale } = useAppLocale();

const loading = ref(false);
const saving = ref(false);
const testing = ref(false);
const startingTraining = ref(false);
const activeModelUpdating = ref('');
const loadError = ref('');
const upstreamError = ref('');

const integrationConfig =
  ref<SentimentFlowIntegrationConfig | null>(null);
const models = ref<SentimentFlowModelItem[]>([]);
const activeModel = ref<SentimentFlowActiveModelData | null>(null);
const stats = ref<SentimentFlowStatsOverviewData | null>(null);
const trainingJobs = ref<SentimentFlowTrainingJobItem[]>([]);
const selectedTrainingStatus =
  ref<SentimentFlowTrainingStatusData | null>(null);
const trainingLogs = ref<TrainingLogItem[]>([]);

const aiSentimentEnabled = ref(false);
const selectedModelId = ref('');
const returnProbabilities = ref(true);
const includeMetadata = ref(false);
const topK = ref(3);

const testText = ref('这个产品体验很好，物流也很快。');
const testPrediction = ref<SentimentFlowPredictData | null>(null);

const trainDatasetPath = ref('datasets/sentiment/train_v5.csv');
const trainModelType = ref('bert');
const trainEpochs = ref(5);
const trainBatchSize = ref(32);
const trainLearningRate = ref('0.00002');
const trainNotes = ref('');
const trainingStatusFilter =
  ref<TrainingStatusFilter>('all');
const selectedTrainingJobId = ref('');
let trainingEventSource: EventSource | null = null;
let trainingLogId = 0;

const canUseUpstream = computed(() => {
  return (
    integrationConfig.value?.enabled === true &&
    integrationConfig.value.baseUrlConfigured
  );
});

const defaultModelValue = computed({
  get: () => selectedModelId.value || ACTIVE_MODEL_VALUE,
  set: (value: string) => {
    selectedModelId.value =
      value === ACTIVE_MODEL_VALUE ? '' : value;
  }
});

const selectedModelName = computed(() => {
  if (!selectedModelId.value) {
    return t('sentiment.panel.activeModelDefault');
  }
  const model = models.value.find(
    item => item.model_id === selectedModelId.value
  );
  return model
    ? `${model.name} v${model.version}`
    : selectedModelId.value;
});

const probabilityItems = computed(() => {
  const probabilities =
    testPrediction.value?.prediction.probabilities ?? {};
  return Object.entries(probabilities)
    .map(([label, score]) => ({ label, score }))
    .sort((a, b) => b.score - a.score);
});

const statusPillClassMap: Record<StatusTone, string> = {
  primary:
    'border-primary/30 bg-primary/10 text-primary',
  emerald:
    'border-emerald-200/60 bg-emerald-100/60 text-emerald-700 dark:border-emerald-900/40 dark:bg-emerald-950/40 dark:text-emerald-300',
  sky: 'border-sky-200/60 bg-sky-100/60 text-sky-700 dark:border-sky-900/40 dark:bg-sky-950/40 dark:text-sky-300',
  amber:
    'border-amber-200/60 bg-amber-100/60 text-amber-700 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-300',
  rose: 'border-rose-200/60 bg-rose-100/60 text-rose-700 dark:border-rose-900/40 dark:bg-rose-950/40 dark:text-rose-300',
  muted:
    'border-border/60 bg-muted/40 text-muted-foreground'
};

function errorText(error: unknown): string {
  return error instanceof Error
    ? error.message
    : t('common.unknownError');
}

function formatPercent(value: number): string {
  return `${(value * 100).toFixed(1)}%`;
}

function formatDate(value: string): string {
  if (!value) {
    return '-';
  }
  return new Date(value).toLocaleString(
    locale.value === 'zh' ? 'zh-CN' : 'en-US',
    {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    }
  );
}

function boundedInteger(
  value: string | number,
  fallback: number,
  min: number,
  max: number
): number {
  const parsed = Math.trunc(Number(value));
  if (!Number.isFinite(parsed)) {
    return fallback;
  }
  return Math.min(Math.max(parsed, min), max);
}

function updateTopK(value: string | number): void {
  topK.value = boundedInteger(value, 3, 1, 10);
}

function updateEpochs(value: string | number): void {
  trainEpochs.value = boundedInteger(value, 5, 1, 100);
}

function updateBatchSize(value: string | number): void {
  trainBatchSize.value = boundedInteger(value, 32, 1, 4096);
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

function statusLabel(status: string): string {
  return t(`sentiment.trainingStatus.${status}`);
}

function statusTone(status: string): StatusTone {
  if (status === 'succeeded') return 'emerald';
  if (
    status === 'failed' ||
    status === 'cancelled' ||
    status === 'cancelling'
  )
    return 'rose';
  if (status === 'running') return 'sky';
  if (status === 'queued') return 'amber';
  return 'muted';
}

function statusPillClass(status: string): string {
  return statusPillClassMap[statusTone(status)];
}

function applySettings(settings: AccountSettingsVM): void {
  aiSentimentEnabled.value = settings.aiSentimentEnabled;
  selectedModelId.value = settings.aiSentimentModelId ?? '';
  returnProbabilities.value =
    settings.aiSentimentReturnProbabilities;
  includeMetadata.value = settings.aiSentimentIncludeMetadata;
  topK.value = boundedInteger(
    settings.aiSentimentTopK,
    3,
    1,
    10
  );
}

async function refreshUpstream(): Promise<void> {
  upstreamError.value = '';
  const [
    modelResult,
    activeModelResult,
    statsResult,
    jobsResult
  ] = await Promise.allSettled([
    sentimentFlowListModels(),
    sentimentFlowGetActiveModel(),
    sentimentFlowStatsOverview(),
    sentimentFlowListTrainingJobs({
      status: trainingStatusFilter.value,
      page: 1,
      page_size: 10
    })
  ]);
  const errors: string[] = [];

  if (modelResult.status === 'fulfilled') {
    models.value = modelResult.value.items;
  } else {
    errors.push(errorText(modelResult.reason));
  }

  if (activeModelResult.status === 'fulfilled') {
    activeModel.value = activeModelResult.value;
  } else {
    activeModel.value = null;
    errors.push(errorText(activeModelResult.reason));
  }

  if (statsResult.status === 'fulfilled') {
    stats.value = statsResult.value;
  } else {
    stats.value = null;
    errors.push(errorText(statsResult.reason));
  }

  if (jobsResult.status === 'fulfilled') {
    trainingJobs.value = jobsResult.value.items;
  } else {
    trainingJobs.value = [];
    errors.push(errorText(jobsResult.reason));
  }

  upstreamError.value = errors[0] ?? '';
}

async function refreshAll(): Promise<void> {
  if (loading.value) {
    return;
  }

  loading.value = true;
  loadError.value = '';
  upstreamError.value = '';

  try {
    const [settings, config] = await Promise.all([
      v2GetSettings(),
      sentimentFlowConfig()
    ]);
    applySettings(settings);
    integrationConfig.value = config;

    if (config.enabled && config.baseUrlConfigured) {
      await refreshUpstream();
    }
  } catch (error) {
    loadError.value = errorText(error);
  } finally {
    loading.value = false;
  }
}

async function saveAiSettings(): Promise<void> {
  if (saving.value) {
    return;
  }

  saving.value = true;
  try {
    const settings = await v2PatchSettings({
      aiSentimentEnabled: aiSentimentEnabled.value,
      aiSentimentModelId: selectedModelId.value || null,
      aiSentimentReturnProbabilities:
        returnProbabilities.value,
      aiSentimentIncludeMetadata: includeMetadata.value,
      aiSentimentTopK: topK.value
    });
    applySettings(settings);
    toast.success(t('sentiment.panel.feedback.saved'));
  } catch (error) {
    toast.error(t('sentiment.panel.feedback.saveFailed'), {
      description: errorText(error)
    });
  } finally {
    saving.value = false;
  }
}

async function updateActiveModel(modelId: string): Promise<void> {
  if (activeModelUpdating.value) {
    return;
  }

  activeModelUpdating.value = modelId;
  try {
    activeModel.value = await sentimentFlowSetActiveModel({
      model_id: modelId
    });
    await refreshUpstream();
    toast.success(t('sentiment.panel.feedback.activeModelSaved'));
  } catch (error) {
    toast.error(
      t('sentiment.panel.feedback.activeModelFailed'),
      {
        description: errorText(error)
      }
    );
  } finally {
    activeModelUpdating.value = '';
  }
}

async function runTestPrediction(): Promise<void> {
  if (testing.value) {
    return;
  }

  const text = testText.value.trim();
  if (!text) {
    toast.error(t('sentiment.panel.feedback.testTextRequired'));
    return;
  }

  testing.value = true;
  testPrediction.value = null;
  try {
    testPrediction.value = await sentimentFlowPredict({
      text,
      model_id: selectedModelId.value || undefined,
      return_probabilities: returnProbabilities.value,
      include_metadata: includeMetadata.value,
      top_k: topK.value
    });
  } catch (error) {
    toast.error(t('sentiment.panel.feedback.predictFailed'), {
      description: errorText(error)
    });
  } finally {
    testing.value = false;
  }
}

async function refreshTrainingJobs(): Promise<void> {
  try {
    const jobs = await sentimentFlowListTrainingJobs({
      status: trainingStatusFilter.value,
      page: 1,
      page_size: 10
    });
    trainingJobs.value = jobs.items;
  } catch (error) {
    toast.error(t('sentiment.panel.feedback.jobsFailed'), {
      description: errorText(error)
    });
  }
}

async function refreshTrainingStatus(
  jobId: string
): Promise<void> {
  selectedTrainingJobId.value = jobId;
  try {
    selectedTrainingStatus.value =
      await sentimentFlowGetTrainingStatus(jobId);
  } catch (error) {
    toast.error(t('sentiment.panel.feedback.statusFailed'), {
      description: errorText(error)
    });
  }
}

function parseLearningRate(): number | null {
  const parsed = Number(trainLearningRate.value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
}

async function startTraining(): Promise<void> {
  if (startingTraining.value) {
    return;
  }

  const datasetPath = trainDatasetPath.value.trim();
  if (!datasetPath) {
    toast.error(t('sentiment.panel.feedback.datasetRequired'));
    return;
  }

  const learningRate = parseLearningRate();
  if (!learningRate) {
    toast.error(t('sentiment.panel.feedback.learningRateInvalid'));
    return;
  }

  startingTraining.value = true;
  try {
    const job = await sentimentFlowStartTraining({
      dataset_path: datasetPath,
      model_type: trainModelType.value,
      hyperparams: {
        epochs: trainEpochs.value,
        batch_size: trainBatchSize.value,
        learning_rate: learningRate
      },
      notes: trainNotes.value.trim() || undefined
    });
    selectedTrainingJobId.value = job.job_id;
    toast.success(t('sentiment.panel.feedback.trainingStarted'));
    await Promise.all([
      refreshTrainingJobs(),
      refreshTrainingStatus(job.job_id)
    ]);
    openTrainingStream(job.job_id);
  } catch (error) {
    toast.error(t('sentiment.panel.feedback.trainingFailed'), {
      description: errorText(error)
    });
  } finally {
    startingTraining.value = false;
  }
}

async function cancelTraining(jobId: string): Promise<void> {
  try {
    await sentimentFlowCancelTraining(jobId);
    toast.success(t('sentiment.panel.feedback.cancelRequested'));
    await refreshTrainingJobs();
    if (selectedTrainingJobId.value === jobId) {
      await refreshTrainingStatus(jobId);
    }
  } catch (error) {
    toast.error(t('sentiment.panel.feedback.cancelFailed'), {
      description: errorText(error)
    });
  }
}

function streamMessage(data: string): string {
  try {
    const parsed = JSON.parse(data) as Record<string, unknown>;
    if (typeof parsed.message === 'string') {
      return parsed.message;
    }
    return JSON.stringify(parsed);
  } catch {
    return data;
  }
}

function addTrainingLog(event: string, data: string): void {
  trainingLogId += 1;
  trainingLogs.value = [
    ...trainingLogs.value,
    {
      id: trainingLogId,
      event,
      message: streamMessage(data),
      time: new Date().toLocaleTimeString(
        locale.value === 'zh' ? 'zh-CN' : 'en-US'
      )
    }
  ].slice(-80);
}

function closeTrainingStream(): void {
  trainingEventSource?.close();
  trainingEventSource = null;
}

function openTrainingStream(jobId: string): void {
  selectedTrainingJobId.value = jobId;
  trainingLogs.value = [];
  closeTrainingStream();

  if (!import.meta.client) {
    return;
  }

  const source = new EventSource(
    sentimentFlowTrainingStreamUrl(jobId)
  );
  trainingEventSource = source;

  const eventNames = [
    'training.started',
    'training.progress',
    'training.log',
    'training.completed',
    'training.failed',
    'heartbeat'
  ];
  for (const eventName of eventNames) {
    source.addEventListener(eventName, event => {
      const messageEvent = event as MessageEvent<string>;
      addTrainingLog(eventName, messageEvent.data);
      if (
        eventName === 'training.completed' ||
        eventName === 'training.failed'
      ) {
        closeTrainingStream();
        void refreshTrainingJobs();
        void refreshTrainingStatus(jobId);
      }
    });
  }
  source.onmessage = event => {
    if (event.data === '[DONE]') {
      addTrainingLog(
        'done',
        t('sentiment.panel.training.streamDone')
      );
      closeTrainingStream();
      void refreshTrainingJobs();
      void refreshTrainingStatus(jobId);
      return;
    }
    addTrainingLog('message', event.data);
  };
  source.onerror = () => {
    addTrainingLog(
      'error',
      t('sentiment.panel.training.streamError')
    );
  };
}

onMounted(() => {
  void refreshAll();
});

onBeforeUnmount(() => {
  closeTrainingStream();
});
</script>

<template>
  <section
    class="grid gap-5 rounded-xl border border-border/60 bg-card p-5 shadow-none sm:p-6"
  >
    <div
      class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"
    >
      <div class="flex items-start gap-3">
        <span
          class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-violet-500/10 text-violet-600 dark:text-violet-400"
        >
          <BrainCircuit class="h-5 w-5" />
        </span>
        <div class="grid gap-1">
          <div class="flex items-center gap-2">
            <h3 class="text-base font-semibold tracking-tight">
              {{ t('sentiment.panel.title') }}
            </h3>
            <span
              class="inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-medium"
              :class="
                canUseUpstream
                  ? statusPillClassMap.emerald
                  : statusPillClassMap.muted
              "
            >
              <span
                class="size-1.5 rounded-full"
                :class="
                  canUseUpstream
                    ? 'bg-emerald-500'
                    : 'bg-muted-foreground/60'
                "
              />
              {{
                canUseUpstream
                  ? t('sentiment.panel.statusReady')
                  : t('sentiment.panel.statusOffline')
              }}
            </span>
          </div>
          <p class="text-xs text-muted-foreground">
            {{ t('sentiment.panel.description') }}
          </p>
        </div>
      </div>
      <Button
        variant="outline"
        size="sm"
        class="h-8 w-full rounded-md shadow-xs sm:w-auto"
        :disabled="loading"
        @click="refreshAll"
      >
        <Loader2
          v-if="loading"
          class="h-3.5 w-3.5 animate-spin"
        />
        <RefreshCw v-else class="h-3.5 w-3.5" />
        {{ t('common.refresh') }}
      </Button>
    </div>

    <Alert
      v-if="loadError"
      variant="destructive"
      class="rounded-lg"
    >
      <AlertTitle>
        {{ t('sentiment.panel.feedback.loadFailed') }}
      </AlertTitle>
      <AlertDescription>{{ loadError }}</AlertDescription>
    </Alert>

    <Alert
      v-else-if="upstreamError"
      class="rounded-lg border-border/60"
    >
      <CircleOff class="h-4 w-4" />
      <AlertTitle>
        {{ t('sentiment.panel.upstreamWarningTitle') }}
      </AlertTitle>
      <AlertDescription>{{ upstreamError }}</AlertDescription>
    </Alert>

    <Tabs default-value="overview" class="w-full">
      <div class="overflow-x-auto">
        <TabsList class="grid w-max min-w-full grid-cols-3 shadow-xs">
          <TabsTrigger value="overview" class="text-xs font-medium">
            {{ t('sentiment.panel.tabs.overview') }}
          </TabsTrigger>
          <TabsTrigger value="prediction" class="text-xs font-medium">
            {{ t('sentiment.panel.tabs.prediction') }}
          </TabsTrigger>
          <TabsTrigger value="training" class="text-xs font-medium">
            {{ t('sentiment.panel.tabs.training') }}
          </TabsTrigger>
        </TabsList>
      </div>

      <TabsContent value="overview" class="grid gap-4 pt-4">
        <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_18rem]">
          <div
            class="grid gap-4 rounded-xl border border-border/60 bg-background p-4"
          >
            <div
              class="flex flex-col items-start gap-3 sm:flex-row sm:items-center sm:justify-between"
            >
              <div class="grid gap-1">
                <Label class="text-xs font-medium">
                  {{ t('sentiment.panel.enableLabel') }}
                </Label>
                <p class="text-[11px] text-muted-foreground">
                  {{ t('sentiment.panel.enableDescription') }}
                </p>
              </div>
              <Switch v-model:checked="aiSentimentEnabled" />
            </div>

            <div class="border-t border-border/60" />

            <div class="grid gap-4 md:grid-cols-2">
              <div class="grid gap-2">
                <Label
                  for="ai-sentiment-model"
                  class="text-xs font-medium"
                >
                  {{ t('sentiment.panel.defaultModel') }}
                </Label>
                <Select
                  v-model="defaultModelValue"
                  :disabled="models.length === 0"
                >
                  <SelectTrigger
                    id="ai-sentiment-model"
                    class="h-9 shadow-xs"
                  >
                    <SelectValue
                      :placeholder="
                        t('sentiment.panel.defaultModel')
                      "
                    />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem :value="ACTIVE_MODEL_VALUE">
                      {{
                        t('sentiment.panel.activeModelDefault')
                      }}
                    </SelectItem>
                    <SelectItem
                      v-for="model in models"
                      :key="model.model_id"
                      :value="model.model_id"
                    >
                      {{ model.name }} v{{ model.version }}
                    </SelectItem>
                  </SelectContent>
                </Select>
                <p class="text-[11px] text-muted-foreground">
                  {{ selectedModelName }}
                </p>
              </div>

              <div class="grid gap-2">
                <Label
                  for="ai-sentiment-top-k"
                  class="text-xs font-medium"
                >
                  {{ t('sentiment.panel.topK') }}
                </Label>
                <Input
                  id="ai-sentiment-top-k"
                  type="number"
                  min="1"
                  max="10"
                  :model-value="topK"
                  class="h-9 shadow-xs"
                  @update:model-value="updateTopK"
                />
                <p class="text-[11px] text-muted-foreground">
                  {{ t('sentiment.panel.topKDescription') }}
                </p>
              </div>
            </div>

            <div class="grid gap-3 md:grid-cols-2">
              <div
                class="flex items-center justify-between gap-4 rounded-lg border border-border/60 bg-muted/20 p-3"
              >
                <div class="grid gap-1">
                  <Label class="text-xs font-medium">
                    {{
                      t('sentiment.panel.returnProbabilities')
                    }}
                  </Label>
                  <p class="text-[11px] text-muted-foreground">
                    {{
                      t(
                        'sentiment.panel.returnProbabilitiesDesc'
                      )
                    }}
                  </p>
                </div>
                <Switch
                  v-model:checked="returnProbabilities"
                />
              </div>
              <div
                class="flex items-center justify-between gap-4 rounded-lg border border-border/60 bg-muted/20 p-3"
              >
                <div class="grid gap-1">
                  <Label class="text-xs font-medium">
                    {{ t('sentiment.panel.includeMetadata') }}
                  </Label>
                  <p class="text-[11px] text-muted-foreground">
                    {{
                      t('sentiment.panel.includeMetadataDesc')
                    }}
                  </p>
                </div>
                <Switch v-model:checked="includeMetadata" />
              </div>
            </div>

            <div class="flex justify-end">
              <Button
                class="h-9 w-full rounded-md shadow-xs sm:w-auto"
                :disabled="saving"
                @click="saveAiSettings"
              >
                <Loader2
                  v-if="saving"
                  class="h-3.5 w-3.5 animate-spin"
                />
                <Save v-else class="h-3.5 w-3.5" />
                {{ t('sentiment.actions.saveSettings') }}
              </Button>
            </div>
          </div>

          <div
            class="grid gap-3 rounded-xl border border-border/60 bg-background p-4 text-sm"
          >
            <div
              class="flex items-center gap-2 text-xs font-semibold uppercase tracking-wider text-muted-foreground"
            >
              <Activity class="h-3.5 w-3.5 text-violet-500" />
              {{ t('sentiment.panel.runtimeTitle') }}
            </div>
            <div class="grid gap-3">
              <div class="grid gap-1">
                <div class="text-[11px] text-muted-foreground">
                  {{ t('sentiment.panel.activeModel') }}
                </div>
                <div class="font-medium">
                  {{
                    activeModel
                      ? `${activeModel.name} v${activeModel.version}`
                      : '-'
                  }}
                </div>
              </div>
              <div class="grid grid-cols-2 gap-3">
                <div class="grid gap-1">
                  <div class="text-[11px] text-muted-foreground">
                    {{ t('sentiment.panel.totalPredictions') }}
                  </div>
                  <div
                    class="text-xl font-semibold tabular-nums tracking-tight"
                  >
                    {{ stats?.total_predictions ?? 0 }}
                  </div>
                </div>
                <div class="grid gap-1">
                  <div class="text-[11px] text-muted-foreground">
                    {{ t('sentiment.panel.totalTrainingJobs') }}
                  </div>
                  <div
                    class="text-xl font-semibold tabular-nums tracking-tight"
                  >
                    {{ stats?.total_training_jobs ?? 0 }}
                  </div>
                </div>
              </div>
              <div class="grid gap-1">
                <div class="text-[11px] text-muted-foreground">
                  {{ t('sentiment.panel.timeout') }}
                </div>
                <div class="tabular-nums">
                  {{ integrationConfig?.timeoutMs ?? '-' }} ms
                </div>
              </div>
            </div>
          </div>
        </div>

        <div
          class="overflow-hidden rounded-xl border border-border/60 bg-background"
        >
          <Table class="min-w-[640px]">
            <TableHeader>
              <TableRow class="bg-muted/30 hover:bg-muted/30">
                <TableHead
                  class="text-xs font-semibold uppercase tracking-wider text-muted-foreground"
                >
                  {{ t('sentiment.panel.models.name') }}
                </TableHead>
                <TableHead
                  class="text-xs font-semibold uppercase tracking-wider text-muted-foreground"
                >
                  {{ t('sentiment.panel.models.type') }}
                </TableHead>
                <TableHead
                  class="text-xs font-semibold uppercase tracking-wider text-muted-foreground"
                >
                  {{ t('sentiment.panel.models.status') }}
                </TableHead>
                <TableHead
                  class="text-right text-xs font-semibold uppercase tracking-wider text-muted-foreground"
                >
                  {{ t('sentiment.panel.models.action') }}
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              <TableEmpty
                v-if="models.length === 0"
                :colspan="4"
              >
                {{ t('sentiment.panel.models.empty') }}
              </TableEmpty>
              <TableRow
                v-for="model in models"
                :key="model.model_id"
              >
                <TableCell>
                  <div class="font-medium">
                    {{ model.name }}
                  </div>
                  <div class="text-[11px] text-muted-foreground">
                    {{ model.model_id }} · v{{ model.version }}
                  </div>
                </TableCell>
                <TableCell class="text-sm">{{ model.type }}</TableCell>
                <TableCell>
                  <span
                    class="inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-medium"
                    :class="
                      model.is_active
                        ? statusPillClassMap.emerald
                        : statusPillClassMap.muted
                    "
                  >
                    {{
                      model.is_active
                        ? t('sentiment.panel.models.active')
                        : t('sentiment.panel.models.standby')
                    }}
                  </span>
                </TableCell>
                <TableCell class="text-right">
                  <Button
                    variant="outline"
                    size="sm"
                    class="h-8 rounded-md shadow-xs"
                    :disabled="
                      model.is_active ||
                      activeModelUpdating === model.model_id
                    "
                    @click="updateActiveModel(model.model_id)"
                  >
                    <Loader2
                      v-if="
                        activeModelUpdating === model.model_id
                      "
                      class="h-3.5 w-3.5 animate-spin"
                    />
                    <CheckCircle2 v-else class="h-3.5 w-3.5" />
                    {{
                      t('sentiment.actions.setActiveModel')
                    }}
                  </Button>
                </TableCell>
              </TableRow>
            </TableBody>
          </Table>
        </div>
      </TabsContent>

      <TabsContent value="prediction" class="grid gap-4 pt-4">
        <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_18rem]">
          <div class="grid gap-3">
            <Label
              for="ai-sentiment-test-text"
              class="text-xs font-medium"
            >
              {{ t('sentiment.panel.testText') }}
            </Label>
            <Textarea
              id="ai-sentiment-test-text"
              v-model="testText"
              class="min-h-32 resize-none rounded-md shadow-xs"
              maxlength="2000"
            />
            <div class="flex justify-end">
              <Button
                class="h-9 w-full rounded-md shadow-xs sm:w-auto"
                :disabled="testing || !canUseUpstream"
                @click="runTestPrediction"
              >
                <Loader2
                  v-if="testing"
                  class="h-3.5 w-3.5 animate-spin"
                />
                <TestTube2 v-else class="h-3.5 w-3.5" />
                {{ t('sentiment.actions.testPrediction') }}
              </Button>
            </div>
          </div>

          <div
            class="rounded-xl border border-border/60 bg-background p-4 text-sm"
          >
            <div
              class="mb-3 flex items-center gap-2 text-xs font-semibold uppercase tracking-wider text-muted-foreground"
            >
              <SlidersHorizontal
                class="h-3.5 w-3.5 text-violet-500"
              />
              {{ t('sentiment.panel.currentPayload') }}
            </div>
            <div class="grid gap-2 text-xs text-muted-foreground">
              <div class="flex items-center justify-between">
                <span>model_id</span>
                <span class="font-mono text-foreground">
                  {{ selectedModelId || 'active' }}
                </span>
              </div>
              <div class="flex items-center justify-between">
                <span>return_probabilities</span>
                <span class="font-mono text-foreground">
                  {{ returnProbabilities }}
                </span>
              </div>
              <div class="flex items-center justify-between">
                <span>include_metadata</span>
                <span class="font-mono text-foreground">
                  {{ includeMetadata }}
                </span>
              </div>
              <div class="flex items-center justify-between">
                <span>top_k</span>
                <span class="font-mono tabular-nums text-foreground">{{ topK }}</span>
              </div>
            </div>
          </div>
        </div>

        <div
          v-if="testPrediction"
          class="grid gap-4 rounded-xl border border-border/60 bg-background p-4 lg:grid-cols-2"
        >
          <div class="grid gap-2">
            <div
              class="text-[11px] uppercase tracking-wider text-muted-foreground"
            >
              {{ t('sentiment.prediction.primaryLabel') }}
            </div>
            <div class="flex flex-wrap items-center gap-2">
              <span
                class="inline-flex items-center gap-1 rounded-full border px-2.5 py-0.5 text-xs font-medium"
                :class="statusPillClassMap.primary"
              >
                {{
                  sentimentLabel(
                    testPrediction.prediction.label
                  )
                }}
              </span>
              <span class="text-sm font-semibold tabular-nums">
                {{
                  formatPercent(
                    testPrediction.prediction.confidence
                  )
                }}
              </span>
            </div>
            <p class="text-[11px] text-muted-foreground">
              {{ testPrediction.model.name }} ·
              <span class="tabular-nums">
                {{ testPrediction.timing_ms }} ms
              </span>
            </p>
          </div>

          <div
            v-if="probabilityItems.length > 0"
            class="grid gap-3"
          >
            <div
              v-for="item in probabilityItems"
              :key="item.label"
              class="grid gap-1.5"
            >
              <div class="flex justify-between text-sm">
                <span>{{ sentimentLabel(item.label) }}</span>
                <span class="font-medium tabular-nums">{{
                  formatPercent(item.score)
                }}</span>
              </div>
              <Progress
                :model-value="Math.round(item.score * 100)"
                class="h-1.5"
              />
            </div>
          </div>
        </div>
      </TabsContent>

      <TabsContent value="training" class="grid gap-4 pt-4">
        <div class="grid gap-4 lg:grid-cols-2">
          <div
            class="grid gap-4 rounded-xl border border-border/60 bg-background p-4"
          >
            <div class="grid gap-4 md:grid-cols-2">
              <div class="grid gap-2 md:col-span-2">
                <Label
                  for="sentiment-dataset-path"
                  class="text-xs font-medium"
                >
                  {{ t('sentiment.panel.training.dataset') }}
                </Label>
                <Input
                  id="sentiment-dataset-path"
                  v-model="trainDatasetPath"
                  class="h-9 shadow-xs"
                />
              </div>
              <div class="grid gap-2">
                <Label
                  for="sentiment-model-type"
                  class="text-xs font-medium"
                >
                  {{ t('sentiment.panel.training.modelType') }}
                </Label>
                <Select v-model="trainModelType">
                  <SelectTrigger
                    id="sentiment-model-type"
                    class="h-9 shadow-xs"
                  >
                    <SelectValue placeholder="bert" />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="bert">bert</SelectItem>
                    <SelectItem value="lstm">lstm</SelectItem>
                  </SelectContent>
                </Select>
              </div>
              <div class="grid gap-2">
                <Label
                  for="sentiment-epochs"
                  class="text-xs font-medium"
                >
                  {{ t('sentiment.panel.training.epochs') }}
                </Label>
                <Input
                  id="sentiment-epochs"
                  type="number"
                  min="1"
                  :model-value="trainEpochs"
                  class="h-9 shadow-xs"
                  @update:model-value="updateEpochs"
                />
              </div>
              <div class="grid gap-2">
                <Label
                  for="sentiment-batch-size"
                  class="text-xs font-medium"
                >
                  {{ t('sentiment.panel.training.batchSize') }}
                </Label>
                <Input
                  id="sentiment-batch-size"
                  type="number"
                  min="1"
                  :model-value="trainBatchSize"
                  class="h-9 shadow-xs"
                  @update:model-value="updateBatchSize"
                />
              </div>
              <div class="grid gap-2">
                <Label
                  for="sentiment-learning-rate"
                  class="text-xs font-medium"
                >
                  {{ t('sentiment.panel.training.learningRate') }}
                </Label>
                <Input
                  id="sentiment-learning-rate"
                  v-model="trainLearningRate"
                  class="h-9 shadow-xs"
                />
              </div>
              <div class="grid gap-2 md:col-span-2">
                <Label
                  for="sentiment-notes"
                  class="text-xs font-medium"
                >
                  {{ t('sentiment.panel.training.notes') }}
                </Label>
                <Textarea
                  id="sentiment-notes"
                  v-model="trainNotes"
                  class="min-h-20 resize-none rounded-md shadow-xs"
                />
              </div>
            </div>
            <div class="flex justify-end">
              <Button
                class="h-9 w-full rounded-md shadow-xs sm:w-auto"
                :disabled="startingTraining || !canUseUpstream"
                @click="startTraining"
              >
                <Loader2
                  v-if="startingTraining"
                  class="h-3.5 w-3.5 animate-spin"
                />
                <Play v-else class="h-3.5 w-3.5" />
                {{ t('sentiment.actions.startTraining') }}
              </Button>
            </div>
          </div>

          <div
            class="grid gap-4 rounded-xl border border-border/60 bg-background p-4"
          >
            <div
              class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between"
            >
              <div class="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
                {{ t('sentiment.panel.training.statusTitle') }}
              </div>
              <div class="grid grid-cols-[minmax(0,1fr)_auto] gap-2 sm:flex">
                <Select
                  v-model="trainingStatusFilter"
                  @update:model-value="refreshTrainingJobs"
                >
                  <SelectTrigger
                    class="h-8 w-full rounded-md shadow-xs sm:w-32"
                  >
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem
                      v-for="status in TRAINING_STATUS_FILTERS"
                      :key="status"
                      :value="status"
                    >
                      {{ statusLabel(status) }}
                    </SelectItem>
                  </SelectContent>
                </Select>
                <button
                  type="button"
                  class="flex h-8 w-8 items-center justify-center rounded-md border border-border/60 bg-background text-muted-foreground transition hover:bg-muted hover:text-foreground disabled:opacity-50"
                  :disabled="!canUseUpstream"
                  @click="refreshTrainingJobs"
                >
                  <RefreshCw class="h-3.5 w-3.5" />
                </button>
              </div>
            </div>

            <div
              v-if="selectedTrainingStatus"
              class="grid gap-3 rounded-lg border border-border/60 bg-muted/30 p-3"
            >
              <div
                class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between"
              >
                <span class="break-all font-mono text-xs">
                  {{ selectedTrainingStatus.job_id }}
                </span>
                <span
                  class="inline-flex w-fit items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-medium"
                  :class="
                    statusPillClass(selectedTrainingStatus.status)
                  "
                >
                  {{
                    statusLabel(selectedTrainingStatus.status)
                  }}
                </span>
              </div>
              <Progress
                :model-value="
                  selectedTrainingStatus.progress?.percent ?? 0
                "
                class="h-1.5"
              />
              <div
                class="grid gap-2 text-[11px] text-muted-foreground sm:grid-cols-2"
              >
                <span class="tabular-nums">
                  epoch:
                  {{
                    selectedTrainingStatus.progress?.epoch ??
                    '-'
                  }}/{{
                    selectedTrainingStatus.progress
                      ?.total_epochs ?? '-'
                  }}
                </span>
                <span class="tabular-nums">
                  val_accuracy:
                  {{
                    selectedTrainingStatus.metrics
                      ?.val_accuracy ?? '-'
                  }}
                </span>
              </div>
            </div>

            <div
              class="max-h-72 overflow-auto rounded-lg border border-border/60"
            >
              <Table class="min-w-[640px]">
                <TableHeader>
                  <TableRow class="bg-muted/30 hover:bg-muted/30">
                    <TableHead
                      class="text-xs font-semibold uppercase tracking-wider text-muted-foreground"
                    >
                      {{ t('sentiment.panel.training.job') }}
                    </TableHead>
                    <TableHead
                      class="text-xs font-semibold uppercase tracking-wider text-muted-foreground"
                    >
                      {{ t('sentiment.panel.training.status') }}
                    </TableHead>
                    <TableHead
                      class="text-right text-xs font-semibold uppercase tracking-wider text-muted-foreground"
                    >
                      {{ t('sentiment.panel.training.action') }}
                    </TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  <TableEmpty
                    v-if="trainingJobs.length === 0"
                    :colspan="3"
                  >
                    {{ t('sentiment.panel.training.empty') }}
                  </TableEmpty>
                  <TableRow
                    v-for="job in trainingJobs"
                    :key="job.job_id"
                  >
                    <TableCell>
                      <div class="font-mono text-xs font-medium">
                        {{ job.job_id }}
                      </div>
                      <div class="text-[11px] text-muted-foreground">
                        {{ job.model_type }} ·
                        {{ formatDate(job.created_at) }}
                      </div>
                    </TableCell>
                    <TableCell>
                      <span
                        class="inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-medium"
                        :class="statusPillClass(job.status)"
                      >
                        {{ statusLabel(job.status) }}
                      </span>
                    </TableCell>
                    <TableCell class="text-right">
                      <div class="flex justify-end gap-1.5">
                        <Button
                          variant="outline"
                          size="sm"
                          class="h-8 rounded-md shadow-xs"
                          @click="
                            refreshTrainingStatus(job.job_id)
                          "
                        >
                          {{ t('sentiment.actions.viewStatus') }}
                        </Button>
                        <button
                          type="button"
                          class="flex h-8 w-8 items-center justify-center rounded-md border border-border/60 bg-background text-muted-foreground transition hover:bg-muted hover:text-foreground"
                          @click="openTrainingStream(job.job_id)"
                        >
                          <Activity class="h-3.5 w-3.5" />
                        </button>
                        <button
                          v-if="
                            job.status === 'queued' ||
                            job.status === 'running'
                          "
                          type="button"
                          class="flex h-8 w-8 items-center justify-center rounded-md border border-rose-500/30 bg-rose-500/10 text-rose-600 transition hover:bg-rose-500/20 dark:text-rose-400"
                          @click="cancelTraining(job.job_id)"
                        >
                          <Square class="h-3.5 w-3.5" />
                        </button>
                      </div>
                    </TableCell>
                  </TableRow>
                </TableBody>
              </Table>
            </div>
          </div>
        </div>

        <div
          v-if="selectedTrainingJobId"
          class="grid gap-3 rounded-xl border border-border/60 bg-background p-4"
        >
          <div
            class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between"
          >
            <div class="min-w-0">
              <div class="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
                {{ t('sentiment.panel.training.streamTitle') }}
              </div>
              <div class="break-all font-mono text-xs text-foreground">
                {{ selectedTrainingJobId }}
              </div>
            </div>
            <Button
              variant="outline"
              size="sm"
              class="h-8 w-full rounded-md shadow-xs sm:w-auto"
              @click="closeTrainingStream"
            >
              {{ t('common.close') }}
            </Button>
          </div>
          <div
            class="max-h-56 grid gap-2 overflow-auto rounded-lg border border-border/60 bg-muted/30 p-3 text-xs"
          >
            <div
              v-if="trainingLogs.length === 0"
              class="text-muted-foreground"
            >
              {{ t('sentiment.panel.training.noLogs') }}
            </div>
            <div
              v-for="item in trainingLogs"
              :key="item.id"
              class="grid gap-2 sm:grid-cols-[5rem_9rem_minmax(0,1fr)]"
            >
              <span class="font-mono text-muted-foreground tabular-nums">
                {{ item.time }}
              </span>
              <span class="font-mono font-medium">{{ item.event }}</span>
              <span class="break-words font-mono">{{ item.message }}</span>
            </div>
          </div>
        </div>
      </TabsContent>
    </Tabs>
  </section>
</template>
