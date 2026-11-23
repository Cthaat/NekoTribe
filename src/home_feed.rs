use serde::Deserialize;
use std::sync::OnceLock;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct HomeFeedSql {
    pub(crate) recommendation_recency: String,
    pub(crate) recommendation_score: String,
    pub(crate) group_activity: String,
}

pub(crate) fn sql() -> &'static HomeFeedSql {
    static SQL: OnceLock<HomeFeedSql> = OnceLock::new();
    SQL.get_or_init(|| {
        serde_json::from_str(include_str!("../contracts/requirements/home-feed.json"))
            .expect("valid home feed SQL")
    })
}
