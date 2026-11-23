use nekotribe_backend::{
    app,
    auth::{github_oauth::GithubOAuth, passkey::PasskeyEngine},
    config::env::{AppConfig, BackendMode},
    link_preview::PreviewCache,
    posts::draft_worker,
};
use tracing_subscriber::{
    filter::filter_fn, layer::SubscriberExt, util::SubscriberInitExt, EnvFilter, Layer,
};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut args = std::env::args().skip(1);
    let command = args.next();
    if command.as_deref() == Some("--check-config") {
        if args.next().is_some() {
            eprintln!("usage: nekotribe-rust --check-config");
            std::process::exit(2);
        }
        let config = AppConfig::native_from_lookup(|key| std::env::var(key).ok())?;
        config
            .native
            .ok_or("missing native configuration")?
            .keys
            .codec()
            .map_err(|_| "invalid authentication configuration")?;
        println!("rust backend configuration valid (offline)");
        return Ok(());
    }
    if command.as_deref() == Some("skills") {
        let args: Vec<_> = args.collect();
        match nekotribe_backend::ai::skill_config_store::maintain_skills(&args, |key| {
            std::env::var(key).ok()
        }) {
            Ok(result) => println!("{result}"),
            Err(code) => {
                eprintln!("{code}");
                std::process::exit(1);
            }
        }
        return Ok(());
    }
    init_tracing();

    let config = AppConfig::from_env()?;
    let bind_addr = config.server.bind_addr();
    let (router, ban_expiry) = app::routes::prepare_router(config.clone()).await?;
    let router = if config.backend_mode == BackendMode::Native {
        let router = match PreviewCache::from_config(&config.redis) {
            Some(cache) => router.layer(axum::Extension(cache)),
            None => router,
        };
        let router = match PasskeyEngine::from_lookup(|key| std::env::var(key).ok()) {
            Some(engine) => router.layer(axum::Extension(engine)),
            None => router,
        };
        match GithubOAuth::from_lookup(|key| std::env::var(key).ok()) {
            Some(engine) => router.layer(axum::Extension(engine)),
            None => router,
        }
    } else {
        router
    };
    let listener = tokio::net::TcpListener::bind(&bind_addr).await?;
    let drafts = draft_worker::start(&config);

    tracing::info!(%bind_addr, "nekotribe rust backend listening");
    axum::serve(
        listener,
        router.into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
    .with_graceful_shutdown(async move {
        app::shutdown::shutdown_signal().await;
        if let Some(sweep) = ban_expiry {
            sweep.abort();
        }
        if let Some(sweep) = drafts {
            sweep.abort();
        }
    })
    .await?;

    Ok(())
}

fn init_tracing() {
    let env_filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("nekotribe_backend=info,tower_http=info"));
    tracing_subscriber::registry()
        .with(env_filter)
        // The upstream engine includes raw assertion and challenge state in trace events.
        .with(
            tracing_subscriber::fmt::layer()
                .with_filter(filter_fn(|meta| !meta.target().starts_with("webauthn_rs"))),
        )
        .init();
}
