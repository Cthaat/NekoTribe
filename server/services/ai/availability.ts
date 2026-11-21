import { createError } from 'h3';
import type { H3Event } from 'h3';
import type oracledb from 'oracledb';
import { v2Auth, v2Ok } from '~/server/utils/v2';
import { loadSkillRegistry } from './skill-config-store';
import { configuredModelRouter, MAX_STORED_MODEL_REVISION } from './model-source';
import type { SkillRegistry } from './skill-selection';

type Flags = ReturnType<SkillRegistry['userAvailability']>;
const unavailable: Flags = { knowledge: false, writing: false, group: false, moderation: false };

export async function readInferenceAvailability(skills: Flags) {
  const unconfigured = { inference: unavailable, model_config_revision: null };
  try {
    const router = await configuredModelRouter();
    const revision = router.select('knowledge').configurationRevision;
    if (revision > MAX_STORED_MODEL_REVISION) return unconfigured;
    const configured = (feature: keyof Flags) => {
      if (!skills[feature]) return false;
      const role = feature === 'group' ? 'agent' : feature;
      const model = router.select(role);
      return model.apiKeyEnv === null || /^[\x21-\x7e]+$/.test(process.env[model.apiKeyEnv] ?? '');
    };
    return {
      inference: {
        knowledge: configured('knowledge'), writing: configured('writing'),
        group: configured('group'), moderation: configured('moderation')
      },
      model_config_revision: revision
    };
  } catch {
    return unconfigured;
  }
}

export function unavailableAIConfiguration() {
  return createError({
    statusCode: 503,
    statusMessage: 'Service temporarily unavailable',
    data: { code: 50301, message: '服务暂不可用，请稍后重试。', data: null, meta: null }
  });
}

/** Status is a configuration snapshot, not a model health or authorization grant. */
export async function readAIAvailability(event: H3Event, connection: oracledb.Connection) {
  v2Auth(event);
  try {
    const { registry } = await loadSkillRegistry(event, connection);
    return v2Ok(registry.userAvailability());
  } catch {
    throw unavailableAIConfiguration();
  }
}
