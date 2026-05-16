import { apiFetch } from '@/composables/useApi';
import type {
  SentimentFlowActiveModelData,
  SentimentFlowAdminUsersData,
  SentimentFlowDeleteModelData,
  SentimentFlowIntegrationConfig,
  SentimentFlowLoginData,
  SentimentFlowLoginPayload,
  SentimentFlowModelsData,
  SentimentFlowPredictData,
  SentimentFlowPredictPayload,
  SentimentFlowSetActiveModelPayload,
  SentimentFlowStatsOverviewData,
  SentimentFlowTrainingCancelData,
  SentimentFlowTrainingJobsData,
  SentimentFlowTrainingJobsQuery,
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
  return await sentimentFlowRequestData<
    SentimentFlowPredictData,
    SentimentFlowPredictPayload
  >('/predict/', {
    method: 'POST',
    body: payload
  });
}

export async function sentimentFlowStartTraining(
  payload: SentimentFlowTrainingStartPayload
): Promise<SentimentFlowTrainingStartData> {
  return await sentimentFlowRequestData<
    SentimentFlowTrainingStartData,
    SentimentFlowTrainingStartPayload
  >('/training/start', {
    method: 'POST',
    body: payload
  });
}

export async function sentimentFlowGetTrainingStatus(
  jobId: string
): Promise<SentimentFlowTrainingStatusData> {
  return await sentimentFlowRequestData<SentimentFlowTrainingStatusData>(
    `/training/status/${encodePathSegment(jobId)}`
  );
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
  return await sentimentFlowRequestData<
    SentimentFlowTrainingJobsData,
    undefined,
    SentimentFlowTrainingJobsQuery
  >('/training/jobs', {
    method: 'GET',
    query
  });
}

export async function sentimentFlowCancelTraining(
  jobId: string
): Promise<SentimentFlowTrainingCancelData> {
  return await sentimentFlowRequestData<SentimentFlowTrainingCancelData>(
    `/training/cancel/${encodePathSegment(jobId)}`,
    {
      method: 'POST'
    }
  );
}

export async function sentimentFlowListModels(): Promise<SentimentFlowModelsData> {
  return await sentimentFlowRequestData<SentimentFlowModelsData>(
    '/models/'
  );
}

export async function sentimentFlowGetActiveModel(): Promise<SentimentFlowActiveModelData> {
  return await sentimentFlowRequestData<SentimentFlowActiveModelData>(
    '/models/active'
  );
}

export async function sentimentFlowSetActiveModel(
  payload: SentimentFlowSetActiveModelPayload
): Promise<SentimentFlowActiveModelData> {
  return await sentimentFlowRequestData<
    SentimentFlowActiveModelData,
    SentimentFlowSetActiveModelPayload
  >('/models/active', {
    method: 'PUT',
    body: payload
  });
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
  return await sentimentFlowRequestData<SentimentFlowStatsOverviewData>(
    '/stats/overview'
  );
}

export async function sentimentFlowListAdminUsers(): Promise<SentimentFlowAdminUsersData> {
  return await sentimentFlowRequestData<SentimentFlowAdminUsersData>(
    '/admin/users'
  );
}
