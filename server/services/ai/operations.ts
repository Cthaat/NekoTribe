import { setResponseHeader, type H3Event } from 'h3';
import contract from '../../../specifications/requirements/ai-operations.json';
import { requireModerationAccess } from '~/server/services/v2/moderation';
import { safeV2Action } from '~/server/utils/auth-entry-errors';
import { readAiServiceQuota } from '~/server/utils/ai-model-quota';
import { v2Auth, v2Ok, v2Rows, v2WithConnection } from '~/server/utils/v2';
import { normalizeAiHttpBaseUrl, type AiModelSelection } from './model-configuration';
import { configuredModelRouter } from './model-source';
import { loadSkillRegistry } from './skill-config-store';
import { summarizeAISkills } from './skill-selection';

type ModelState = 'unconfigured' | 'missing_credential' | 'unreachable' | 'model_unavailable' | 'ready';

async function modelNames(model: AiModelSelection, key?: string) {
  const ollama = model.adapter === 'ollama';
  const response = await fetch(model.baseUrl.replace(/\/+$/, '') + (ollama ? '/api/tags' : '/models'), {
    redirect: 'error',
    signal: AbortSignal.timeout(contract.healthTimeoutMilliseconds),
    headers: key ? { Authorization: `Bearer ${key}` } : {}
  });
  if (!response.ok) {
    await response.body?.cancel();
    throw new Error('Provider unavailable');
  }
  const result = await response.json() as { models?: { name: string }[]; data?: { id: string }[] };
  return new Set(ollama ? result.models?.map(item => item.name) : result.data?.map(item => item.id));
}

async function modelStatus() {
  const router = await configuredModelRouter().catch(() => null);
  const providers = new Map<string, Promise<Set<string> | null>>();
  const models = await Promise.all(contract.roles.map(async purpose => {
    const model = router?.select(purpose === 'group' ? 'agent' : purpose);
    let state: ModelState = 'unconfigured';
    if (model) {
      const key = model.apiKeyEnv ? process.env[model.apiKeyEnv] : undefined;
      if (model.apiKeyEnv && !key) {
        state = 'missing_credential';
      } else {
        if (!providers.has(model.providerId)) providers.set(model.providerId, modelNames(model, key).catch(() => null));
        const names = await providers.get(model.providerId);
        state = !names ? 'unreachable' : names.has(model.model) ? 'ready' : 'model_unavailable';
      }
    }
    return {
      purpose, provider_id: model?.providerId ?? null, model_id: model?.profileId ?? null,
      model_version: model?.modelVersion ?? null, state
    };
  }));
  return {
    model_config_revision: router?.select('knowledge').configurationRevision ?? null,
    nodes: [...new Set(models.flatMap(model => model.provider_id ? [model.provider_id] : []))],
    models
  };
}

async function indexStatus() {
  const address = process.env.AI_KNOWLEDGE_INDEX_URL;
  const token = process.env.AI_INDEX_SERVICE_TOKEN;
  if (!address || !token) return null;
  try {
    const response = await fetch(normalizeAiHttpBaseUrl(address) + contract.indexStatusPath, {
      headers: { Authorization: `Bearer ${token}` },
      redirect: 'error',
      signal: AbortSignal.timeout(contract.indexTimeoutMilliseconds)
    });
    if (!response.ok) {
      await response.body?.cancel();
      return null;
    }
    const { version, ready, status } = await response.json() as {
      version: number; ready: boolean;
      status?: { point_count: number; phase: string | null; last_success_at: number | null; next_at: number | null };
    };
    if (version !== 1 || !ready || !status || !Number.isSafeInteger(status.point_count)) return null;
    const phase = ['syncing', 'pruning', 'waiting', 'stopped'].find(phase => phase === status.phase) ?? null;
    const time = (value: number | null) => Number.isSafeInteger(value) ? value : null;
    return { point_count: status.point_count, phase, last_success_at: time(status.last_success_at), next_at: time(status.next_at) };
  } catch {
    return null;
  }
}

export async function readAiOperations(event: H3Event) {
  setResponseHeader(event, 'Cache-Control', 'private, no-store');
  v2Auth(event);
  return safeV2Action(async () => {
    const { data } = await v2WithConnection(event, async connection => {
      await requireModerationAccess(event, connection);
      const rows = await v2Rows(connection, contract.feedbackSql);
      const feedback = rows.map(row => {
        const helpful = Number(row.HELPFUL);
        const incorrect = Number(row.INCORRECT);
        return {
          model_id: row.MODEL_ID ?? null, model_version: row.MODEL_VERSION ?? null, config_revision: row.CONFIG_REVISION ?? null,
          helpful, incorrect, insufficient: Number(row.INSUFFICIENT),
          accuracy: helpful + incorrect ? helpful / (helpful + incorrect) : null
        };
      });
      const config = await loadSkillRegistry(event, connection).catch(() => null);
      const skills = config ? {
        generation: config.generation,
        items: summarizeAISkills(config.registry.userAvailability()).map(({ id, purpose, version, enabled }) => ({ id, purpose, version, enabled }))
      } : null;
      return v2Ok({ feedback, skills });
    });
    const [models, global_quota, index] = await Promise.all([
      modelStatus(), readAiServiceQuota(event.context.aiQuotaRedis), indexStatus()
    ]);
    return v2Ok({ backend: 'nuxt', ...models, global_quota, index, ...data });
  });
}
