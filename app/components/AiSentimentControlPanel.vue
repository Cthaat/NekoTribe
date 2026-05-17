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
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Progress } from '@/components/ui/progress';
import { Separator } from '@/components/ui/separator';
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

type BadgeVariant =
  | 'default'
  | 'secondary'
  | 'destructive'
  | 'outline';
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

function statusVariant(status: string): BadgeVariant {
  if (status === 'succeeded') {
    return 'default';
  }
  if (
    status === 'failed' ||
    status === 'cancelled' ||
    status === 'cancelling'
  ) {
    return 'destructive';
  }
  if (status === 'running' || status === 'queued') {
    return 'secondary';
  }
  return 'outline';
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
  <section class="space-y-4 rounded-md border p-4">
    <div
      class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"
    >
      <div class="space-y-1">
        <div class="flex items-center gap-2">
          <BrainCircuit class="h-5 w-5 text-primary" />
          <h3 class="text-lg font-semibold">
            {{ t('sentiment.panel.title') }}
          </h3>
          <Badge
            :variant="canUseUpstream ? 'default' : 'secondary'"
          >
            {{
              canUseUpstream
                ? t('sentiment.panel.statusReady')
                : t('sentiment.panel.statusOffline')
            }}
          </Badge>
        </div>
        <p class="text-sm text-muted-foreground">
          {{ t('sentiment.panel.description') }}
        </p>
      </div>
      <Button
        variant="outline"
        size="sm"
        class="gap-2"
        :disabled="loading"
        @click="refreshAll"
      >
        <Loader2
          v-if="loading"
          class="h-4 w-4 animate-spin"
        />
        <RefreshCw v-else class="h-4 w-4" />
        {{ t('common.refresh') }}
      </Button>
    </div>

    <Alert v-if="loadError" variant="destructive">
      <AlertTitle>
        {{ t('sentiment.panel.feedback.loadFailed') }}
      </AlertTitle>
      <AlertDescription>{{ loadError }}</AlertDescription>
    </Alert>

    <Alert v-else-if="upstreamError">
      <CircleOff class="h-4 w-4" />
      <AlertTitle>
        {{ t('sentiment.panel.upstreamWarningTitle') }}
      </AlertTitle>
      <AlertDescription>{{ upstreamError }}</AlertDescription>
    </Alert>

    <Tabs default-value="overview" class="w-full">
      <TabsList class="grid w-full grid-cols-3">
        <TabsTrigger value="overview">
          {{ t('sentiment.panel.tabs.overview') }}
        </TabsTrigger>
        <TabsTrigger value="prediction">
          {{ t('sentiment.panel.tabs.prediction') }}
        </TabsTrigger>
        <TabsTrigger value="training">
          {{ t('sentiment.panel.tabs.training') }}
        </TabsTrigger>
      </TabsList>

      <TabsContent value="overview" class="space-y-5 pt-4">
        <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_18rem]">
          <div class="space-y-4 rounded-md border p-4">
            <div class="flex items-center justify-between gap-4">
              <div>
                <Label class="font-medium">
                  {{ t('sentiment.panel.enableLabel') }}
                </Label>
                <p class="text-xs text-muted-foreground">
                  {{ t('sentiment.panel.enableDescription') }}
                </p>
              </div>
              <Switch
                v-model:checked="aiSentimentEnabled"
              />
            </div>

            <Separator />

            <div class="grid gap-4 md:grid-cols-2">
              <div class="space-y-2">
                <Label for="ai-sentiment-model">
                  {{ t('sentiment.panel.defaultModel') }}
                </Label>
                <Select
                  v-model="defaultModelValue"
                  :disabled="models.length === 0"
                >
                  <SelectTrigger id="ai-sentiment-model">
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
                <p class="text-xs text-muted-foreground">
                  {{ selectedModelName }}
                </p>
              </div>

              <div class="space-y-2">
                <Label for="ai-sentiment-top-k">
                  {{ t('sentiment.panel.topK') }}
                </Label>
                <Input
                  id="ai-sentiment-top-k"
                  type="number"
                  min="1"
                  max="10"
                  :model-value="topK"
                  @update:model-value="updateTopK"
                />
                <p class="text-xs text-muted-foreground">
                  {{ t('sentiment.panel.topKDescription') }}
                </p>
              </div>
            </div>

            <div class="grid gap-4 md:grid-cols-2">
              <div class="flex items-center justify-between gap-4">
                <div>
                  <Label class="font-medium">
                    {{
                      t('sentiment.panel.returnProbabilities')
                    }}
                  </Label>
                  <p class="text-xs text-muted-foreground">
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
              <div class="flex items-center justify-between gap-4">
                <div>
                  <Label class="font-medium">
                    {{ t('sentiment.panel.includeMetadata') }}
                  </Label>
                  <p class="text-xs text-muted-foreground">
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
                class="gap-2"
                :disabled="saving"
                @click="saveAiSettings"
              >
                <Loader2
                  v-if="saving"
                  class="h-4 w-4 animate-spin"
                />
                <Save v-else class="h-4 w-4" />
                {{ t('sentiment.actions.saveSettings') }}
              </Button>
            </div>
          </div>

          <div class="space-y-3 rounded-md border p-4 text-sm">
            <div class="flex items-center gap-2 font-medium">
              <Activity class="h-4 w-4 text-primary" />
              {{ t('sentiment.panel.runtimeTitle') }}
            </div>
            <div class="grid gap-3">
              <div>
                <div class="text-muted-foreground">
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
                <div>
                  <div class="text-muted-foreground">
                    {{ t('sentiment.panel.totalPredictions') }}
                  </div>
                  <div class="text-lg font-semibold">
                    {{ stats?.total_predictions ?? 0 }}
                  </div>
                </div>
                <div>
                  <div class="text-muted-foreground">
                    {{ t('sentiment.panel.totalTrainingJobs') }}
                  </div>
                  <div class="text-lg font-semibold">
                    {{ stats?.total_training_jobs ?? 0 }}
                  </div>
                </div>
              </div>
              <div>
                <div class="text-muted-foreground">
                  {{ t('sentiment.panel.timeout') }}
                </div>
                <div>
                  {{ integrationConfig?.timeoutMs ?? '-' }} ms
                </div>
              </div>
            </div>
          </div>
        </div>

        <div class="rounded-md border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>
                  {{ t('sentiment.panel.models.name') }}
                </TableHead>
                <TableHead>
                  {{ t('sentiment.panel.models.type') }}
                </TableHead>
                <TableHead>
                  {{ t('sentiment.panel.models.status') }}
                </TableHead>
                <TableHead class="text-right">
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
                  <div class="text-xs text-muted-foreground">
                    {{ model.model_id }} · v{{ model.version }}
                  </div>
                </TableCell>
                <TableCell>{{ model.type }}</TableCell>
                <TableCell>
                  <Badge
                    :variant="
                      model.is_active ? 'default' : 'secondary'
                    "
                  >
                    {{
                      model.is_active
                        ? t('sentiment.panel.models.active')
                        : t('sentiment.panel.models.standby')
                    }}
                  </Badge>
                </TableCell>
                <TableCell class="text-right">
                  <Button
                    variant="outline"
                    size="sm"
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
                      class="mr-2 h-4 w-4 animate-spin"
                    />
                    <CheckCircle2 v-else class="mr-2 h-4 w-4" />
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

      <TabsContent value="prediction" class="space-y-4 pt-4">
        <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_18rem]">
          <div class="space-y-3">
            <Label for="ai-sentiment-test-text">
              {{ t('sentiment.panel.testText') }}
            </Label>
            <Textarea
              id="ai-sentiment-test-text"
              v-model="testText"
              class="min-h-32 resize-none"
              maxlength="2000"
            />
            <div class="flex justify-end">
              <Button
                class="gap-2"
                :disabled="testing || !canUseUpstream"
                @click="runTestPrediction"
              >
                <Loader2
                  v-if="testing"
                  class="h-4 w-4 animate-spin"
                />
                <TestTube2 v-else class="h-4 w-4" />
                {{ t('sentiment.actions.testPrediction') }}
              </Button>
            </div>
          </div>

          <div class="rounded-md border p-4 text-sm">
            <div class="mb-3 flex items-center gap-2 font-medium">
              <SlidersHorizontal
                class="h-4 w-4 text-primary"
              />
              {{ t('sentiment.panel.currentPayload') }}
            </div>
            <div class="space-y-2 text-muted-foreground">
              <div>
                model_id:
                <span class="text-foreground">
                  {{ selectedModelId || 'active' }}
                </span>
              </div>
              <div>
                return_probabilities:
                <span class="text-foreground">
                  {{ returnProbabilities }}
                </span>
              </div>
              <div>
                include_metadata:
                <span class="text-foreground">
                  {{ includeMetadata }}
                </span>
              </div>
              <div>
                top_k:
                <span class="text-foreground">{{ topK }}</span>
              </div>
            </div>
          </div>
        </div>

        <div
          v-if="testPrediction"
          class="grid gap-4 rounded-md border p-4 lg:grid-cols-2"
        >
          <div class="space-y-2">
            <div class="text-sm text-muted-foreground">
              {{ t('sentiment.prediction.primaryLabel') }}
            </div>
            <div class="flex items-center gap-2">
              <Badge>
                {{
                  sentimentLabel(
                    testPrediction.prediction.label
                  )
                }}
              </Badge>
              <span class="text-sm font-medium">
                {{
                  formatPercent(
                    testPrediction.prediction.confidence
                  )
                }}
              </span>
            </div>
            <p class="text-xs text-muted-foreground">
              {{ testPrediction.model.name }} ·
              {{ testPrediction.timing_ms }} ms
            </p>
          </div>

          <div
            v-if="probabilityItems.length > 0"
            class="space-y-3"
          >
            <div
              v-for="item in probabilityItems"
              :key="item.label"
              class="space-y-1.5"
            >
              <div class="flex justify-between text-sm">
                <span>{{ sentimentLabel(item.label) }}</span>
                <span>{{ formatPercent(item.score) }}</span>
              </div>
              <Progress
                :model-value="Math.round(item.score * 100)"
              />
            </div>
          </div>
        </div>
      </TabsContent>

      <TabsContent value="training" class="space-y-5 pt-4">
        <div class="grid gap-4 lg:grid-cols-2">
          <div class="space-y-4 rounded-md border p-4">
            <div class="grid gap-4 md:grid-cols-2">
              <div class="space-y-2 md:col-span-2">
                <Label for="sentiment-dataset-path">
                  {{ t('sentiment.panel.training.dataset') }}
                </Label>
                <Input
                  id="sentiment-dataset-path"
                  v-model="trainDatasetPath"
                />
              </div>
              <div class="space-y-2">
                <Label for="sentiment-model-type">
                  {{ t('sentiment.panel.training.modelType') }}
                </Label>
                <Select v-model="trainModelType">
                  <SelectTrigger id="sentiment-model-type">
                    <SelectValue placeholder="bert" />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="bert">bert</SelectItem>
                    <SelectItem value="lstm">lstm</SelectItem>
                  </SelectContent>
                </Select>
              </div>
              <div class="space-y-2">
                <Label for="sentiment-epochs">
                  {{ t('sentiment.panel.training.epochs') }}
                </Label>
                <Input
                  id="sentiment-epochs"
                  type="number"
                  min="1"
                  :model-value="trainEpochs"
                  @update:model-value="updateEpochs"
                />
              </div>
              <div class="space-y-2">
                <Label for="sentiment-batch-size">
                  {{ t('sentiment.panel.training.batchSize') }}
                </Label>
                <Input
                  id="sentiment-batch-size"
                  type="number"
                  min="1"
                  :model-value="trainBatchSize"
                  @update:model-value="updateBatchSize"
                />
              </div>
              <div class="space-y-2">
                <Label for="sentiment-learning-rate">
                  {{ t('sentiment.panel.training.learningRate') }}
                </Label>
                <Input
                  id="sentiment-learning-rate"
                  v-model="trainLearningRate"
                />
              </div>
              <div class="space-y-2 md:col-span-2">
                <Label for="sentiment-notes">
                  {{ t('sentiment.panel.training.notes') }}
                </Label>
                <Textarea
                  id="sentiment-notes"
                  v-model="trainNotes"
                  class="min-h-20 resize-none"
                />
              </div>
            </div>
            <div class="flex justify-end">
              <Button
                class="gap-2"
                :disabled="startingTraining || !canUseUpstream"
                @click="startTraining"
              >
                <Loader2
                  v-if="startingTraining"
                  class="h-4 w-4 animate-spin"
                />
                <Play v-else class="h-4 w-4" />
                {{ t('sentiment.actions.startTraining') }}
              </Button>
            </div>
          </div>

          <div class="space-y-4 rounded-md border p-4">
            <div
              class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between"
            >
              <div class="font-medium">
                {{ t('sentiment.panel.training.statusTitle') }}
              </div>
              <div class="flex gap-2">
                <Select
                  v-model="trainingStatusFilter"
                  @update:model-value="refreshTrainingJobs"
                >
                  <SelectTrigger class="w-32">
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
                <Button
                  variant="outline"
                  size="icon"
                  :disabled="!canUseUpstream"
                  @click="refreshTrainingJobs"
                >
                  <RefreshCw class="h-4 w-4" />
                </Button>
              </div>
            </div>

            <div
              v-if="selectedTrainingStatus"
              class="space-y-3 rounded-md bg-muted/40 p-3"
            >
              <div class="flex items-center justify-between gap-2">
                <span class="font-medium">
                  {{ selectedTrainingStatus.job_id }}
                </span>
                <Badge
                  :variant="
                    statusVariant(selectedTrainingStatus.status)
                  "
                >
                  {{
                    statusLabel(selectedTrainingStatus.status)
                  }}
                </Badge>
              </div>
              <Progress
                :model-value="
                  selectedTrainingStatus.progress?.percent ?? 0
                "
              />
              <div class="grid gap-2 text-xs text-muted-foreground sm:grid-cols-2">
                <span>
                  epoch:
                  {{
                    selectedTrainingStatus.progress?.epoch ??
                    '-'
                  }}/{{
                    selectedTrainingStatus.progress
                      ?.total_epochs ?? '-'
                  }}
                </span>
                <span>
                  val_accuracy:
                  {{
                    selectedTrainingStatus.metrics
                      ?.val_accuracy ?? '-'
                  }}
                </span>
              </div>
            </div>

            <div class="max-h-72 overflow-auto rounded-md border">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>
                      {{ t('sentiment.panel.training.job') }}
                    </TableHead>
                    <TableHead>
                      {{ t('sentiment.panel.training.status') }}
                    </TableHead>
                    <TableHead class="text-right">
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
                      <div class="font-medium">
                        {{ job.job_id }}
                      </div>
                      <div class="text-xs text-muted-foreground">
                        {{ job.model_type }} ·
                        {{ formatDate(job.created_at) }}
                      </div>
                    </TableCell>
                    <TableCell>
                      <Badge :variant="statusVariant(job.status)">
                        {{ statusLabel(job.status) }}
                      </Badge>
                    </TableCell>
                    <TableCell class="text-right">
                      <div class="flex justify-end gap-2">
                        <Button
                          variant="outline"
                          size="sm"
                          @click="
                            refreshTrainingStatus(job.job_id)
                          "
                        >
                          {{ t('sentiment.actions.viewStatus') }}
                        </Button>
                        <Button
                          variant="outline"
                          size="icon"
                          @click="openTrainingStream(job.job_id)"
                        >
                          <Activity class="h-4 w-4" />
                        </Button>
                        <Button
                          v-if="
                            job.status === 'queued' ||
                            job.status === 'running'
                          "
                          variant="destructive"
                          size="icon"
                          @click="cancelTraining(job.job_id)"
                        >
                          <Square class="h-4 w-4" />
                        </Button>
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
          class="rounded-md border p-4"
        >
          <div class="mb-3 flex items-center justify-between gap-3">
            <div>
              <div class="font-medium">
                {{ t('sentiment.panel.training.streamTitle') }}
              </div>
              <div class="text-xs text-muted-foreground">
                {{ selectedTrainingJobId }}
              </div>
            </div>
            <Button
              variant="outline"
              size="sm"
              @click="closeTrainingStream"
            >
              {{ t('common.close') }}
            </Button>
          </div>
          <div
            class="max-h-56 space-y-2 overflow-auto rounded-md bg-muted/40 p-3 text-xs"
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
              <span class="text-muted-foreground">
                {{ item.time }}
              </span>
              <span class="font-medium">{{ item.event }}</span>
              <span class="break-words">{{ item.message }}</span>
            </div>
          </div>
        </div>
      </TabsContent>
    </Tabs>
  </section>
</template>
