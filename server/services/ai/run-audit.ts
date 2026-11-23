import type { H3Event } from 'h3';
import { getRequestLogContext, logInfo } from '~/server/utils/logging';
import { AiQuotaError } from '~/server/utils/ai-model-quota';
import { observeAi, type AiOperation } from '../../utils/observability';

export type AiRunStage = 'validation' | 'configuration' | 'quota' | 'proposal' | 'evidence' | 'inference' | 'persist';
type AiRunOutcome = 'generated' | 'insufficient_evidence' | 'quota_exhausted' | 'quota_unavailable' | 'cancelled' | 'failed';

export class AiRunAudit {
  stage: AiRunStage = 'validation';
  configRevision = 0;
  toolCount = 0;
  private readonly startedAt = performance.now();
  private readonly requestId: string | undefined;

  constructor(event: H3Event, private readonly operation: AiOperation, private readonly skillGeneration: number,
    private readonly skillSelection: 'explicit' | 'purpose-default' = 'purpose-default') {
    this.requestId = getRequestLogContext(event)?.requestId;
  }

  finish(outcome: AiRunOutcome) {
    const elapsed = performance.now() - this.startedAt;
    const result = outcome === 'generated' || outcome === 'insufficient_evidence' ? 'success'
      : outcome === 'cancelled' ? 'cancelled' : 'failure';
    observeAi(this.operation, result, elapsed / 1000, outcome === 'quota_exhausted' || outcome === 'quota_unavailable');
    logInfo('ai', {
      event: 'ai.run', version: 1, operation: this.operation, stage: this.stage, outcome,
      ...(this.requestId ? { request_id: this.requestId } : {}),
      config_revision: this.configRevision, skill_generation: this.skillGeneration,
      skill_selection: this.skillSelection,
      tool_count: this.toolCount, elapsed_ms: Math.floor(elapsed),
    });
  }

  fail(error: unknown, signal?: AbortSignal) {
    if (signal?.aborted) this.finish('cancelled');
    else if (error instanceof AiQuotaError) {
      this.finish(error.retryAfter === null ? 'quota_unavailable' : 'quota_exhausted');
    } else this.finish('failed');
  }
}
