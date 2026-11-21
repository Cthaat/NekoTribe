import { logInfo } from '~/server/utils/logging';
import { AiQuotaError } from '~/server/utils/ai-model-quota';

export type AiRunStage = 'validation' | 'configuration' | 'quota' | 'proposal' | 'evidence' | 'inference' | 'persist';
type AiRunOutcome = 'generated' | 'insufficient_evidence' | 'quota_exhausted' | 'quota_unavailable' | 'cancelled' | 'failed';

export class AiRunAudit {
  stage: AiRunStage = 'validation';
  configRevision = 0;
  toolCount = 0;
  private readonly startedAt = performance.now();

  constructor(private readonly operation: 'knowledge_answer' | 'writing_draft' | 'group_draft' | 'moderation_advice', private readonly skillGeneration: number,
    private readonly skillSelection: 'explicit' | 'purpose-default' = 'purpose-default') {}

  finish(outcome: AiRunOutcome) {
    logInfo('ai', {
      event: 'ai.run', version: 1, operation: this.operation, stage: this.stage, outcome,
      config_revision: this.configRevision, skill_generation: this.skillGeneration,
      skill_selection: this.skillSelection,
      tool_count: this.toolCount, elapsed_ms: Math.floor(performance.now() - this.startedAt),
    });
  }

  fail(error: unknown, signal?: AbortSignal) {
    if (signal?.aborted) this.finish('cancelled');
    else if (error instanceof AiQuotaError) {
      this.finish(error.retryAfter === null ? 'quota_unavailable' : 'quota_exhausted');
    } else this.finish('failed');
  }
}
