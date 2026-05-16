export type SentimentFlowJson =
  | string
  | number
  | boolean
  | null
  | SentimentFlowJson[]
  | { [key: string]: SentimentFlowJson };
export type SentimentFlowPrimitive =
  | string
  | number
  | boolean
  | null;

export interface SentimentFlowApiErrorDetail {
  field?: string;
  reason: string;
}

export interface SentimentFlowApiError {
  type: string;
  details?: SentimentFlowApiErrorDetail[];
}

export interface SentimentFlowApiResponse<T> {
  code: number;
  message: string;
  data: T;
  error?: SentimentFlowApiError;
}

export interface SentimentFlowIntegrationConfig {
  enabled: boolean;
  baseUrlConfigured: boolean;
  proxyBasePath: string;
  timeoutMs: number;
}

export interface SentimentFlowLoginPayload {
  username: string;
  password: string;
}

export interface SentimentFlowUser {
  id: string;
  username: string;
  role: string;
}

export interface SentimentFlowLoginData {
  access_token: string;
  token_type: string;
  expires_in: number;
  user: SentimentFlowUser;
}

export interface SentimentFlowPredictPayload {
  text: string;
  model_id?: string;
  return_probabilities?: boolean;
  include_metadata?: boolean;
  top_k?: number;
}

export interface SentimentFlowModelRef {
  id: string;
  name: string;
  version: string;
}

export interface SentimentFlowPredictionInput {
  text: string;
  language: string;
  length: number;
}

export interface SentimentFlowPredictionTopKItem {
  label: string;
  score: number;
}

export interface SentimentFlowPredictionResult {
  label: string;
  score: number;
  confidence: number;
  probabilities?: Record<string, number>;
  top_k?: SentimentFlowPredictionTopKItem[];
}

export interface SentimentFlowPredictData {
  request_id: string;
  model: SentimentFlowModelRef;
  input: SentimentFlowPredictionInput;
  prediction: SentimentFlowPredictionResult;
  timing_ms: number;
  created_at: string;
}

export type SentimentFlowJobStatus =
  | 'queued'
  | 'running'
  | 'succeeded'
  | 'failed'
  | 'cancelled'
  | 'cancelling'
  | (string & {});

export interface SentimentFlowTrainingStartPayload {
  dataset_path: string;
  model_type: string;
  hyperparams?: Record<string, SentimentFlowJson>;
  notes?: string;
}

export interface SentimentFlowTrainingStartData {
  job_id: string;
  status: SentimentFlowJobStatus;
  created_at: string;
}

export interface SentimentFlowTrainingProgress {
  percent: number;
  epoch?: number;
  total_epochs?: number;
  step?: number;
  total_steps?: number;
  eta_seconds?: number;
}

export interface SentimentFlowTrainingStatusData {
  job_id: string;
  status: SentimentFlowJobStatus;
  progress?: SentimentFlowTrainingProgress;
  metrics?: Record<string, number>;
  started_at?: string;
  updated_at?: string;
}

export interface SentimentFlowTrainingJobItem {
  job_id: string;
  status: SentimentFlowJobStatus;
  model_type: string;
  created_at: string;
}

export interface SentimentFlowTrainingJobsQuery {
  [key: string]:
    | SentimentFlowPrimitive
    | undefined
    | ReadonlyArray<SentimentFlowPrimitive>;
  status?: SentimentFlowJobStatus | 'all';
  page?: number;
  page_size?: number;
}

export interface SentimentFlowTrainingJobsData {
  items: SentimentFlowTrainingJobItem[];
  page: number;
  page_size: number;
  total: number;
}

export interface SentimentFlowTrainingCancelData {
  job_id: string;
  status: SentimentFlowJobStatus;
}

export interface SentimentFlowModelItem {
  model_id: string;
  name: string;
  version: string;
  type: string;
  is_active: boolean;
  created_at: string;
}

export interface SentimentFlowModelsData {
  items: SentimentFlowModelItem[];
  total: number;
}

export interface SentimentFlowActiveModelData {
  model_id: string;
  name: string;
  version: string;
  activated_at: string;
}

export interface SentimentFlowSetActiveModelPayload {
  model_id: string;
}

export interface SentimentFlowDeleteModelData {
  model_id: string;
}

export interface SentimentFlowStatsOverviewData {
  total_predictions: number;
  total_training_jobs: number;
  active_model: SentimentFlowActiveModelData | null;
}

export interface SentimentFlowAdminUserItem {
  id: string;
  username: string;
  role: string;
}

export interface SentimentFlowAdminUsersData {
  items: SentimentFlowAdminUserItem[];
  total: number;
}
