use nekotribe_backend::ai::model_quota::{AiModelQuota, AiModelQuotaLimiter, QuotaFuture};
use std::sync::Arc;

struct SingleCallQuota;

impl AiModelQuotaLimiter for SingleCallQuota {
    fn reserve(&self, actor: u64, cost: u64) -> QuotaFuture<'_> {
        assert!(actor > 0);
        assert_eq!(cost, 1);
        Box::pin(async { Ok(0) })
    }
}

pub fn single_call_quota() -> AiModelQuota {
    AiModelQuota(Arc::new(SingleCallQuota))
}
