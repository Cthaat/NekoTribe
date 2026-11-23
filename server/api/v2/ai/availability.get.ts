import { defineEventHandler, isError } from 'h3';
import { readAIAvailability, readInferenceAvailability, unavailableAIConfiguration } from '~/server/services/ai/availability';
import { privateAiHandler } from '~/server/services/ai/private-http';
import { summarizeAISkills } from '~/server/services/ai/skill-selection';
import { personalWritingAvailability } from '~/server/services/ai/user-provider';

const route = privateAiHandler(readAIAvailability);

export default defineEventHandler(async event => {
  try {
    const result = await route(event);
    if (!result.data) throw unavailableAIConfiguration();
    const modelStatus = await readInferenceAvailability(result.data);
    const personal = result.data.writing ? await personalWritingAvailability(event) : null;
    return {
      ...result,
      data: { ...result.data, ...modelStatus, inference: {...modelStatus.inference, writing:personal ?? modelStatus.inference.writing},
        skills: summarizeAISkills(result.data) }
    };
  } catch (error) {
    // This read-only endpoint treats connection acquisition/close failures as
    // unavailable configuration. Other v2 routes keep their existing semantics.
    if (isError(error) && error.statusCode === 500) throw unavailableAIConfiguration();
    throw error;
  }
});
