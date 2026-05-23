use nekotribe_backend::{app, config::env::AppConfig};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    init_tracing();

    let config = AppConfig::from_env()?;
    let bind_addr = config.server.bind_addr();
    let listener = tokio::net::TcpListener::bind(&bind_addr).await?;
    let router = app::routes::build_router(config);

    tracing::info!(%bind_addr, "nekotribe rust backend listening");
    axum::serve(listener, router)
        .with_graceful_shutdown(app::shutdown::shutdown_signal())
        .await?;

    Ok(())
}

fn init_tracing() {
    let env_filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("nekotribe_backend=info,tower_http=info"));
    tracing_subscriber::registry()
        .with(env_filter)
        .with(tracing_subscriber::fmt::layer())
        .init();
}
