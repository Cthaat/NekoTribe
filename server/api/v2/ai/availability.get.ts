import { defineEventHandler, isError } from 'h3';
import { readAIAvailability, readInferenceAvailability, unavailableAIConfiguration } from '~/server/services/ai/availability';
import { privateAiHandler } from '~/server/services/ai/private-http';
import { summarizeAISkills } from '~/server/services/ai/skill-selection';

const route = privateAiHandler(readAIAvailability);

export default defineEventHandler(async event => {
  try {
    const result = await route(event);
    if (!result.data) throw unavailableAIConfiguration();
    return {
      ...result,
      data: { ...result.data, ...await readInferenceAvailability(result.data), skills: summarizeAISkills(result.data) }
    };
  } catch (error) {
    // This read-only endpoint treats connection acquisition/close failures as
    // unavailable configuration. Other v2 routes keep their existing semantics.
    if (isError(error) && error.statusCode === 500) throw unavailableAIConfiguration();
    throw error;
  }
});
