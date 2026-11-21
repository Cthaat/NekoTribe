package server

import (
	"context"
	"errors"
	"log"
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
	outcome := "failed"
	var exhausted aiQuotaExceeded
	switch {
	case message != nil:
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
	log.Printf("event=ai.run version=1 operation=%s stage=%s outcome=%s config_revision=%d skill_generation=%d skill_selection=%s tool_count=%d elapsed_ms=%d",
		audit.operation, audit.stage, outcome, audit.configRevision, audit.skillGeneration, audit.skillSelection, audit.toolCount, time.Since(audit.startedAt).Milliseconds())
}
