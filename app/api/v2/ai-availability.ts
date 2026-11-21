import { v2RequestData } from './client';
import type { AiAvailability, AiAvailabilityState, AiSkillPurpose, AiSkillSummary } from '@/services/ai-writing-controller';

const skillIds = {
  knowledge: 'knowledge-answer',
  writing: 'writing-draft',
  group: 'group-brief',
  moderation: 'moderation-advice'
} satisfies Record<AiSkillPurpose, string>;

function readSkills(value: unknown, flags: AiAvailability): AiSkillSummary[] {
  if (!Array.isArray(value) || value.length !== Object.keys(skillIds).length) throw new Error('Invalid AI availability skills');
  const skills = new Map<AiSkillPurpose, AiSkillSummary>();
  for (const item of value as unknown[]) {
    if (!item || typeof item !== 'object' || Array.isArray(item) || !('purpose' in item) ||
      typeof item.purpose !== 'string' || !Object.hasOwn(skillIds, item.purpose)) {
      throw new Error('Invalid AI availability skills');
    }
    const purpose = item.purpose as AiSkillPurpose;
    if (skills.has(purpose) || !('id' in item) || item.id !== skillIds[purpose] ||
      !('version' in item) || typeof item.version !== 'number' || !Number.isSafeInteger(item.version) || item.version < 1 ||
      !('enabled' in item) || typeof item.enabled !== 'boolean' || item.enabled !== flags[purpose]) {
      throw new Error('Invalid AI availability skills');
    }
    const explicitSelection = 'explicit_selection' in item ? item.explicit_selection : undefined;
    if ('explicit_selection' in item && typeof explicitSelection !== 'boolean') {
      throw new Error('Invalid AI availability skills');
    }
    skills.set(purpose, {
      id: item.id, purpose, version: item.version, enabled: item.enabled,
      ...(typeof explicitSelection === 'boolean' ? { explicitSelection } : {})
    });
  }
  return [...skills.values()];
}

function optionalWorkflowFlags(data: object): Pick<AiAvailability, 'group' | 'moderation'> {
  const flags: Pick<AiAvailability, 'group' | 'moderation'> = {};
  for (const name of ['group', 'moderation'] as const) {
    if (!(name in data)) continue;
    const value: unknown = Reflect.get(data, name);
    if (typeof value !== 'boolean') throw new Error('Invalid AI availability');
    flags[name] = value;
  }
  return flags;
}

export async function getAiAvailability(signal?: AbortSignal): Promise<AiAvailability> {
  const data = await v2RequestData<unknown>('/api/v2/ai/availability', { method: 'GET', signal });
  if (!data || typeof data !== 'object' || Array.isArray(data) ||
      !('knowledge' in data) || typeof data.knowledge !== 'boolean' ||
      !('writing' in data) || typeof data.writing !== 'boolean') {
    throw new Error('Invalid AI availability');
  }
  const flags: AiAvailability = { knowledge: data.knowledge, writing: data.writing, ...optionalWorkflowFlags(data) };
  if ('model_config_revision' in data && data.model_config_revision !== null) {
    const revision = data.model_config_revision;
    if (typeof revision !== 'number' || !Number.isSafeInteger(revision) || revision < 1 || revision > 999_999_999_999_999) {
      throw new Error('Invalid AI availability model configuration revision');
    }
    flags.modelConfigRevision = revision;
  }
  if ('skills' in data) flags.skills = readSkills(data.skills, flags);
  if (!('inference' in data)) return flags;
  const inference = data.inference;
  if (!inference || typeof inference !== 'object' || Array.isArray(inference) ||
      !('knowledge' in inference) || typeof inference.knowledge !== 'boolean' ||
      !('writing' in inference) || typeof inference.writing !== 'boolean') {
    throw new Error('Invalid AI availability');
  }
  return { ...flags, inference: { knowledge: inference.knowledge, writing: inference.writing, ...optionalWorkflowFlags(inference) } };
}

export function aiWorkflowAvailability(
  flags: AiAvailability,
  workflow: 'group' | 'moderation'
): AiAvailabilityState {
  if (flags[workflow] === false) return 'disabled';
  return flags.inference?.[workflow] === false ? 'unconfigured' : 'enabled';
}
