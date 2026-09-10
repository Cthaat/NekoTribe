use crate::config::env::AppConfig;

#[derive(Clone, Debug)]
pub struct AppState {
    pub config: AppConfig,
    pub http_client: reqwest::Client,
}

impl AppState {
    pub fn new(config: AppConfig) -> Self {
        Self {
            config,
            http_client: reqwest::Client::new(),
        }
    }
}
