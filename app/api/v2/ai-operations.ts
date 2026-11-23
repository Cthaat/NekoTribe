import { v2RequestData } from './client';

export interface AiOperations {
  backend: 'nuxt' | 'go' | 'rust';
  model_config_revision: number | null;
  nodes: string[];
  models: { purpose: string; provider_id: string | null; model_id: string | null; model_version: string | null; state: string }[];
  global_quota: { used_units: number | null; limit_units: number | null; window_seconds: number };
  index: { point_count: number; phase: string | null; last_success_at: number | null; next_at: number | null } | null;
  feedback: AiFeedback[];
  skills: { generation: number; items: { id: string; purpose: string; version: number; enabled: boolean }[] } | null;
}

export interface AiFeedback {
  model_id: string | null;
  model_version: string | null;
  config_revision: number | null;
  helpful: number;
  incorrect: number;
  insufficient: number;
  accuracy: number | null;
}

export function getAiOperations(signal?: AbortSignal) {
  return v2RequestData<AiOperations>('/api/v2/moderation/ai/operations', { signal });
}
