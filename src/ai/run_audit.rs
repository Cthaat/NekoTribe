use std::time::Instant;

use super::model_quota::QuotaError;

pub(super) struct AiRunAudit {
    operation: &'static str,
    pub stage: &'static str,
    pub config_revision: u64,
    skill_generation: i64,
    pub skill_selection: &'static str,
    pub tool_count: usize,
    started_at: Instant,
    finished: bool,
}

impl AiRunAudit {
    pub fn new(operation: &'static str, skill_generation: i64) -> Self {
        Self {
            operation,
            stage: "validation",
            config_revision: 0,
            skill_generation,
            skill_selection: "purpose-default",
            tool_count: 0,
            started_at: Instant::now(),
            finished: false,
        }
    }

    pub fn finish<T, E>(
        &mut self,
        result: &Result<Option<T>, E>,
        cancelled: bool,
        quota_error: impl FnOnce(&E) -> Option<QuotaError>,
    ) {
        let outcome = match result {
            Ok(Some(_)) => "generated",
            Ok(None) => "insufficient_evidence",
            Err(_) if cancelled => "cancelled",
            Err(error) => match quota_error(error) {
                Some(QuotaError::Exhausted(_)) => "quota_exhausted",
                Some(QuotaError::Unavailable) => "quota_unavailable",
                None => "failed",
            },
        };
        self.finished = true;
        self.emit(outcome);
    }

    fn emit(&self, outcome: &'static str) {
        tracing::info!(
            event = "ai.run",
            version = 1,
            operation = self.operation,
            stage = self.stage,
            outcome,
            config_revision = self.config_revision,
            skill_generation = self.skill_generation,
            skill_selection = self.skill_selection,
            tool_count = self.tool_count,
            elapsed_ms = self.started_at.elapsed().as_millis() as u64,
            "AI run finished"
        );
    }
}

impl Drop for AiRunAudit {
    fn drop(&mut self) {
        if !self.finished {
            self.emit(if std::thread::panicking() { "failed" } else { "cancelled" });
        }
    }
}
