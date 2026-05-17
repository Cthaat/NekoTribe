import { apiFetch } from '@/composables/useApi';
import type {
  SentimentFlowActiveModelData,
  SentimentFlowAdminUsersData,
  SentimentFlowDeleteModelData,
  SentimentFlowIntegrationConfig,
  SentimentFlowLoginData,
  SentimentFlowLoginPayload,
  SentimentFlowModelItem,
  SentimentFlowModelsData,
  SentimentFlowPredictData,
  SentimentFlowPredictPayload,
  SentimentFlowPredictionTopKItem,
  SentimentFlowSetActiveModelPayload,
  SentimentFlowStatsOverviewData,
  SentimentFlowTrainingCancelData,
  SentimentFlowTrainingJobItem,
  SentimentFlowTrainingJobsData,
  SentimentFlowTrainingJobsQuery,
  SentimentFlowTrainingProgress,
  SentimentFlowTrainingStartData,
  SentimentFlowTrainingStartPayload,
  SentimentFlowTrainingStatusData
} from '@/types/sentiment-flow';
import type { V2ApiResponse } from '@/types/v2';
import {
  SENTIMENT_FLOW_PROXY_BASE,
  sentimentFlowRequestData
} from './client';

export * from './client';
export * from '@/types/sentiment-flow';

function encodePathSegment(value: string): string {
  return encodeURIComponent(value);
}

type SentimentFlowModelType = 'lstm' | 'bert';

interface ActualSentimentFlowPredictPayload {
  text: string;
  model?: SentimentFlowModelType;
  model_id?: string;
  return_probabilities?: boolean;
  include_metadata?: boolean;
  top_k?: number;
}

interface ActualSentimentFlowTrainingStartPayload {
  dataset_path: string;
  model_type: string;
  hyperparams?: Record<string, unknown>;
  config: Record<string, unknown>;
  notes?: string;
}

interface ActualSentimentFlowSetActivePayload {
  model_id?: string;
  model_type?: string;
  model_path?: string;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value &&
    typeof value === 'object' &&
    !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function stringValue(value: unknown, fallback = ''): string {
  if (typeof value === 'string') return value;
  if (
    typeof value === 'number' ||
    typeof value === 'boolean'
  ) {
    return String(value);
  }
  return fallback;
}

function numberValue(value: unknown, fallback = 0): number {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === 'string') {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : fallback;
  }
  return fallback;
}

function booleanValue(value: unknown): boolean {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return value === 1;
  if (typeof value === 'string') {
    return ['1', 'true', 'yes', 'on'].includes(
      value.toLowerCase()
    );
  }
  return false;
}

function nullableNumber(value: unknown): number | null {
  if (value === null || value === undefined || value === '') {
    return null;
  }
  const parsed = numberValue(value, Number.NaN);
  return Number.isFinite(parsed) ? parsed : null;
}

function basename(value: string): string {
  return value.replace(/\\/g, '/').split('/').filter(Boolean).pop() ?? '';
}

function normalizeModelType(
  value: unknown
): SentimentFlowModelType | undefined {
  const normalized = stringValue(value).toLowerCase();
  if (normalized.includes('bert')) return 'bert';
  if (normalized.includes('lstm')) return 'lstm';
  return undefined;
}

function activePath(
  record: Record<string, unknown>,
  modelType: string
): string {
  if (modelType === 'bert') {
    return stringValue(
      record.active_bert_path ?? record.bert_path
    );
  }
  if (modelType === 'lstm') {
    return stringValue(
      record.active_lstm_path ?? record.lstm_path
    );
  }
  return '';
}

function normalizeModelItem(
  value: unknown,
  root: Record<string, unknown>
): SentimentFlowModelItem | null {
  const record = asRecord(value);
  if (!record) return null;

  const modelId = stringValue(
    record.model_id ?? record.id ?? record.name
  );
  if (!modelId) return null;

  const type = stringValue(
    record.type ?? record.model_type,
    'unknown'
  );
  const path = stringValue(record.path);
  const activeModelPath = activePath(root, type);
  const predictType = stringValue(
    root.predict_model_type
  ).toLowerCase();
  const isActive =
    booleanValue(record.is_active) ||
    (!!path && !!activeModelPath && path === activeModelPath) ||
    (!activeModelPath &&
      !!predictType &&
      type.toLowerCase() === predictType);

  return {
    model_id: modelId,
    name: stringValue(record.name, modelId),
    version: stringValue(
      record.version,
      record.best_epoch ? `epoch ${record.best_epoch}` : ''
    ),
    type,
    path: path || undefined,
    size_mb: nullableNumber(record.size_mb),
    best_f1: nullableNumber(record.best_f1),
    best_mae: nullableNumber(record.best_mae),
    best_qwk: nullableNumber(record.best_qwk),
    best_epoch: nullableNumber(record.best_epoch),
    is_active: isActive,
    created_at: stringValue(
      record.created_at ?? record.started_at
    )
  };
}

function normalizeModelsData(
  value: unknown
): SentimentFlowModelsData {
  const record = asRecord(value) ?? {};
  const sourceItems = asArray(record.items ?? record.models);
  const items = sourceItems
    .map(item => normalizeModelItem(item, record))
    .filter((item): item is SentimentFlowModelItem => !!item);

  return {
    items,
    total: numberValue(record.total, items.length)
  };
}

function normalizeActiveModel(
  value: unknown
): SentimentFlowActiveModelData {
  const record = asRecord(value) ?? {};
  const modelType = stringValue(
    record.predict_model_type ?? record.model_type
  );
  const path = activePath(record, modelType);
  const modelId = stringValue(
    record.model_id,
    path ? basename(path) : modelType || 'active'
  );
  const displayType = modelType
    ? modelType.toUpperCase()
    : modelId;

  return {
    model_id: modelId,
    name: stringValue(record.name, displayType),
    version: stringValue(record.version),
    activated_at: stringValue(record.activated_at)
  };
}

function scoreLabel(score: number): string {
  const labels = [
    'extremely_negative',
    'clearly_negative',
    'slightly_negative',
    'neutral',
    'slightly_positive',
    'extremely_positive'
  ];
  return labels[score] ?? `score_${score}`;
}

function normalizeProbabilities(
  value: unknown
): Record<string, number> {
  if (Array.isArray(value)) {
    return Object.fromEntries(
      value.map((item, index) => [
        scoreLabel(index),
        numberValue(item)
      ])
    );
  }

  const record = asRecord(value);
  if (!record) return {};
  return Object.fromEntries(
    Object.entries(record).map(([key, item]) => [
      key,
      numberValue(item)
    ])
  );
}

function topKFromProbabilities(
  probabilities: Record<string, number>,
  topK: number
): SentimentFlowPredictionTopKItem[] {
  return Object.entries(probabilities)
    .map(([label, score]) => ({ label, score }))
    .sort((a, b) => b.score - a.score)
    .slice(0, topK);
}

function normalizePredictData(
  value: unknown,
  request: SentimentFlowPredictPayload
): SentimentFlowPredictData {
  const record = asRecord(value) ?? {};
  const predictionRecord = asRecord(record.prediction);
  if (predictionRecord) {
    return {
      request_id: stringValue(record.request_id),
      model: {
        id: stringValue(
          asRecord(record.model)?.id ?? request.model_id
        ),
        name: stringValue(
          asRecord(record.model)?.name,
          stringValue(request.model_id, 'active')
        ),
        version: stringValue(asRecord(record.model)?.version)
      },
      input: {
        text: stringValue(
          asRecord(record.input)?.text,
          request.text
        ),
        language: stringValue(
          asRecord(record.input)?.language,
          'zh'
        ),
        length: numberValue(
          asRecord(record.input)?.length,
          request.text.length
        )
      },
      prediction: {
        label: stringValue(predictionRecord.label),
        score: numberValue(predictionRecord.score),
        confidence: numberValue(predictionRecord.confidence),
        probabilities: normalizeProbabilities(
          predictionRecord.probabilities
        ),
        top_k: asArray(predictionRecord.top_k)
          .map(item => {
            const topItem = asRecord(item) ?? {};
            return {
              label: stringValue(topItem.label),
              score: numberValue(topItem.score)
            };
          })
          .filter(item => item.label.length > 0)
      },
      timing_ms: numberValue(record.timing_ms),
      created_at: stringValue(record.created_at)
    };
  }

  const probabilities = normalizeProbabilities(
    record.probabilities
  );
  const score = numberValue(record.score, 3);
  const label = stringValue(record.label, scoreLabel(score));
  const confidence = numberValue(record.confidence);

  return {
    request_id: stringValue(
      record.request_id,
      `local_${Date.now()}`
    ),
    model: {
      id: stringValue(
        record.model_name,
        request.model_id || request.model || 'active'
      ),
      name: stringValue(
        record.model_name,
        request.model_id || request.model || 'active'
      ),
      version: ''
    },
    input: {
      text: stringValue(record.text, request.text),
      language: 'zh',
      length: stringValue(record.text, request.text).length
    },
    prediction: {
      label,
      score:
        probabilities[label] ??
        probabilities[scoreLabel(score)] ??
        confidence,
      confidence,
      probabilities,
      top_k: topKFromProbabilities(
        probabilities,
        request.top_k ?? 3
      )
    },
    timing_ms: numberValue(record.timing_ms),
    created_at: stringValue(
      record.created_at,
      new Date().toISOString()
    )
  };
}

function normalizeTrainingJobStatus(status: unknown): string {
  const value = stringValue(status);
  return value === 'pending' ? 'queued' : value;
}

function normalizeTrainingJobItem(
  value: unknown
): SentimentFlowTrainingJobItem | null {
  const record = asRecord(value);
  if (!record) return null;
  const jobId = stringValue(record.job_id);
  if (!jobId) return null;

  return {
    job_id: jobId,
    status: normalizeTrainingJobStatus(record.status),
    model_type: stringValue(record.model_type),
    created_at: stringValue(
      record.created_at ??
        record.started_at ??
        record.finished_at
    )
  };
}

function normalizeTrainingJobsData(
  value: unknown
): SentimentFlowTrainingJobsData {
  const record = asRecord(value) ?? {};
  const sourceItems = asArray(record.items ?? record.jobs);
  const items = sourceItems
    .map(normalizeTrainingJobItem)
    .filter(
      (item): item is SentimentFlowTrainingJobItem => !!item
    );

  return {
    items,
    page: numberValue(record.page, 1),
    page_size: numberValue(
      record.page_size,
      items.length || 20
    ),
    total: numberValue(record.total, items.length)
  };
}

function normalizeTrainingProgress(
  value: unknown
): SentimentFlowTrainingProgress {
  const record = asRecord(value) ?? {};
  const epoch = numberValue(
    record.epoch ?? record.current_epoch
  );
  const totalEpochs = numberValue(
    record.total_epochs,
    epoch || 1
  );
  const step = numberValue(record.step ?? record.current_step);
  const totalSteps = numberValue(record.total_steps);
  const percent = numberValue(
    record.percent,
    totalSteps > 0
      ? (step / totalSteps) * 100
      : totalEpochs > 0
        ? (epoch / totalEpochs) * 100
        : 0
  );

  return {
    percent: Math.min(Math.max(percent, 0), 100),
    epoch,
    total_epochs: totalEpochs,
    step,
    total_steps: totalSteps,
    eta_seconds: numberValue(record.eta_seconds)
  };
}

function normalizeTrainingStatusData(
  value: unknown
): SentimentFlowTrainingStatusData {
  const record = asRecord(value) ?? {};
  const progressRecord = asRecord(record.progress) ?? {};

  return {
    job_id: stringValue(record.job_id),
    status: normalizeTrainingJobStatus(record.status),
    progress: normalizeTrainingProgress(record.progress),
    metrics: {
      train_loss: numberValue(
        progressRecord.train_loss ?? progressRecord.loss
      ),
      val_loss: numberValue(progressRecord.val_loss),
      val_accuracy: numberValue(
        progressRecord.val_accuracy ??
          progressRecord.val_acc
      ),
      val_f1: numberValue(progressRecord.val_f1),
      val_mae: numberValue(progressRecord.val_mae),
      val_qwk: numberValue(progressRecord.val_qwk)
    },
    started_at: stringValue(record.started_at),
    updated_at: stringValue(
      record.updated_at ??
        record.finished_at ??
        record.started_at
    )
  };
}

function normalizeStatsOverview(
  value: unknown
): SentimentFlowStatsOverviewData {
  const record = asRecord(value) ?? {};
  const activeModelRecord = asRecord(record.active_model);

  return {
    total_predictions: numberValue(record.total_predictions),
    total_training_jobs: numberValue(
      record.total_training_jobs
    ),
    active_model: activeModelRecord
      ? normalizeActiveModel(activeModelRecord)
      : null
  };
}

export async function sentimentFlowConfig(): Promise<SentimentFlowIntegrationConfig> {
  const response = await apiFetch<
    V2ApiResponse<SentimentFlowIntegrationConfig>
  >(`${SENTIMENT_FLOW_PROXY_BASE}/config`);
  return response.data;
}

export async function sentimentFlowLogin(
  payload: SentimentFlowLoginPayload
): Promise<SentimentFlowLoginData> {
  return await sentimentFlowRequestData<
    SentimentFlowLoginData,
    SentimentFlowLoginPayload
  >('/auth/login', {
    method: 'POST',
    body: payload
  });
}

export async function sentimentFlowPredict(
  payload: SentimentFlowPredictPayload
): Promise<SentimentFlowPredictData> {
  const model = payload.model ?? normalizeModelType(payload.model_id);
  const raw = await sentimentFlowRequestData<
    unknown,
    ActualSentimentFlowPredictPayload
  >('/predict/', {
    method: 'POST',
    body: {
      text: payload.text,
      model,
      model_id: payload.model_id,
      return_probabilities: payload.return_probabilities,
      include_metadata: payload.include_metadata,
      top_k: payload.top_k
    }
  });
  return normalizePredictData(raw, payload);
}

export async function sentimentFlowStartTraining(
  payload: SentimentFlowTrainingStartPayload
): Promise<SentimentFlowTrainingStartData> {
  const config = {
    dataset_path: payload.dataset_path,
    ...(payload.hyperparams ?? {}),
    ...(payload.config ?? {}),
    ...(payload.notes ? { notes: payload.notes } : {})
  };
  const raw = await sentimentFlowRequestData<
    unknown,
    ActualSentimentFlowTrainingStartPayload
  >('/training/start', {
    method: 'POST',
    body: {
      dataset_path: payload.dataset_path,
      model_type: payload.model_type,
      hyperparams: payload.hyperparams,
      config,
      notes: payload.notes
    }
  });
  const record = asRecord(raw) ?? {};
  return {
    job_id: stringValue(record.job_id),
    status: normalizeTrainingJobStatus(record.status),
    created_at: stringValue(
      record.created_at,
      new Date().toISOString()
    )
  };
}

export async function sentimentFlowGetTrainingStatus(
  jobId: string
): Promise<SentimentFlowTrainingStatusData> {
  const raw = await sentimentFlowRequestData<unknown>(
    `/training/status/${encodePathSegment(jobId)}`
  );
  return normalizeTrainingStatusData(raw);
}

export function sentimentFlowTrainingStreamUrl(
  jobId: string
): string {
  const path = `${SENTIMENT_FLOW_PROXY_BASE}/training/stream/${encodePathSegment(jobId)}`;

  try {
    const config = useRuntimeConfig();
    return `${String(config.public.apiBase ?? '')}${path}`;
  } catch {
    return path;
  }
}

export async function sentimentFlowListTrainingJobs(
  query: SentimentFlowTrainingJobsQuery = {}
): Promise<SentimentFlowTrainingJobsData> {
  const raw = await sentimentFlowRequestData<
    unknown,
    undefined,
    SentimentFlowTrainingJobsQuery
  >('/training/jobs', {
    method: 'GET',
    query
  });
  return normalizeTrainingJobsData(raw);
}

export async function sentimentFlowCancelTraining(
  jobId: string
): Promise<SentimentFlowTrainingCancelData> {
  const raw = await sentimentFlowRequestData<unknown>(
    `/training/cancel/${encodePathSegment(jobId)}`,
    {
      method: 'POST'
    }
  );
  const record = asRecord(raw) ?? {};
  return {
    job_id: stringValue(record.job_id, jobId),
    status: normalizeTrainingJobStatus(
      record.status ?? 'cancelling'
    )
  };
}

export async function sentimentFlowListModels(): Promise<SentimentFlowModelsData> {
  const raw = await sentimentFlowRequestData<unknown>(
    '/models/'
  );
  return normalizeModelsData(raw);
}

export async function sentimentFlowGetActiveModel(): Promise<SentimentFlowActiveModelData> {
  const raw = await sentimentFlowRequestData<unknown>(
    '/models/active'
  );
  return normalizeActiveModel(raw);
}

export async function sentimentFlowSetActiveModel(
  payload: SentimentFlowSetActiveModelPayload
): Promise<SentimentFlowActiveModelData> {
  const models = await sentimentFlowListModels();
  const model = models.items.find(
    item => item.model_id === payload.model_id
  );
  const raw = await sentimentFlowRequestData<
    unknown,
    ActualSentimentFlowSetActivePayload
  >('/models/active', {
    method: 'PUT',
    body:
      model?.path && model.type
        ? {
            model_type: model.type,
            model_path: model.path
          }
        : {
            model_id: payload.model_id
          }
  });
  return normalizeActiveModel(raw);
}

export async function sentimentFlowDeleteModel(
  modelId: string
): Promise<SentimentFlowDeleteModelData> {
  return await sentimentFlowRequestData<SentimentFlowDeleteModelData>(
    `/models/${encodePathSegment(modelId)}`,
    {
      method: 'DELETE'
    }
  );
}

export async function sentimentFlowStatsOverview(): Promise<SentimentFlowStatsOverviewData> {
  const raw = await sentimentFlowRequestData<unknown>(
    '/stats/overview'
  );
  return normalizeStatsOverview(raw);
}

export async function sentimentFlowListAdminUsers(): Promise<SentimentFlowAdminUsersData> {
  return await sentimentFlowRequestData<SentimentFlowAdminUsersData>(
    '/admin/users'
  );
}
