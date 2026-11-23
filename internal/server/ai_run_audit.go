package server

import (
	"context"
	"errors"
	"log/slog"
	"time"
)

type aiRunAudit struct {
	operation       string
	stage           string
	configRevision  int64
	skillGeneration int64
	skillSelection  string
	toolCount       int
	startedAt       time.Time
}

func newAIRunAudit(operation string, skillGeneration int64) aiRunAudit {
	return aiRunAudit{operation: operation, stage: "validation", skillGeneration: skillGeneration, skillSelection: "purpose-default", startedAt: time.Now()}
}

func (audit *aiRunAudit) finish(ctx context.Context, message *conversationMessage, err error) {
	audit.finishResult(ctx, message != nil, err)
}

func (audit *aiRunAudit) finishResult(ctx context.Context, generated bool, err error) {
	outcome := "failed"
	var exhausted aiQuotaExceeded
	switch {
	case generated:
		outcome = "generated"
	case err == nil:
		outcome = "insufficient_evidence"
	case ctx.Err() != nil:
		outcome = "cancelled"
	case errors.As(err, &exhausted):
		outcome = "quota_exhausted"
	case errors.Is(err, errAIQuotaUnavailable):
		outcome = "quota_unavailable"
	}
	elapsed := time.Since(audit.startedAt)
	request := requestTelemetryFrom(ctx)
	attrs := []slog.Attr{
		slog.String("event", "ai.run"), slog.Int("version", 1), slog.String("operation", audit.operation),
		slog.String("stage", audit.stage), slog.String("outcome", outcome), slog.Int64("config_revision", audit.configRevision),
		slog.Int64("skill_generation", audit.skillGeneration), slog.String("skill_selection", audit.skillSelection),
		slog.Int("tool_count", audit.toolCount), slog.Int64("elapsed_ms", elapsed.Milliseconds()),
	}
	logger := telemetryLogger
	if request.id != "" {
		attrs = append(attrs, slog.String("request_id", request.id))
	}
	if request.telemetry != nil {
		logger = request.telemetry.logger
		request.telemetry.recordAI(audit.operation, outcome, elapsed.Seconds())
	}
	logger.LogAttrs(ctx, slog.LevelInfo, "ai.run", attrs...)
}
