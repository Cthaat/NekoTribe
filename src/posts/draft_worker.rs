use super::{
    create_notification::{self, NotificationContext},
    draft_input::Post,
    draft_store::{self, Notice},
};
use crate::{
    auth::session_repository::OracleSessions,
    config::env::{AppConfig, BackendMode},
    db::pool::OraclePool,
    group_post_write,
    notification_events::{NotificationPublisher, RedisNotificationPublisher},
};
use std::time::Duration;
use tokio::{
    task::JoinHandle,
    time::{interval_at, Instant, MissedTickBehavior},
};

pub fn start(config: &AppConfig) -> Option<JoinHandle<()>> {
    if config.backend_mode != BackendMode::Native {
        return None;
    }
    let storage = config.native.as_ref()?.storage_urls.clone();
    let pool = OraclePool::new(config.oracle.clone());
    let repository = OracleSessions {
        executor: pool.clone(),
    };
    let publisher = RedisNotificationPublisher::new(&config.redis).ok();
    Some(tokio::spawn(async move {
        let period = Duration::from_secs(draft_store::contract().sweep_interval_seconds);
        let mut ticks = interval_at(Instant::now() + period, period);
        ticks.set_missed_tick_behavior(MissedTickBehavior::Skip);
        let context = NotificationContext {
            repository: &repository,
            storage: &storage,
            publisher: publisher
                .as_ref()
                .map(|publisher| publisher as &dyn NotificationPublisher),
        };
        loop {
            ticks.tick().await;
            let ids = match pool.run_blocking(draft_store::candidates).await {
                Ok(ids) => ids,
                Err(_) => {
                    tracing::warn!("post draft scan incomplete");
                    continue;
                }
            };
            for id in ids {
                let post_storage = storage.clone();
                match pool
                    .run_blocking(move |connection| {
                        draft_store::publish_due(connection, id, &post_storage)
                    })
                    .await
                {
                    Ok(Some(notice)) => notify(&context, notice).await,
                    Ok(None) => {}
                    Err(_) => tracing::warn!("scheduled post draft publication incomplete"),
                }
            }
        }
    }))
}

pub(super) async fn notify(context: &NotificationContext<'_>, notice: Notice) {
    let delivered = match notice.post {
        Post::Regular(input) => {
            create_notification::notify_created_with(context, notice.owner, notice.post_id, &input)
                .await
                .is_ok()
        }
        Post::Group { group, input } => group_post_write::notify_with(
            context,
            notice.owner,
            group,
            notice.post_id,
            &input.content,
        )
        .await
        .is_ok(),
    };
    if !delivered {
        tracing::warn!("post draft notification unavailable");
    }
}
