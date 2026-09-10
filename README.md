# NekoTribe Rust compatibility backend

This branch contains an independent Rust crate. Business routes currently proxy to the existing Nuxt HTTP service; this is not a completed native Rust business backend. Health endpoints, response helpers, middleware and Oracle/Redis infrastructure are implemented in Rust. WebSocket, authentication and storage integration still depend on the upstream service and deployment routing.

## Build and test

Run from this project root with Rust/Cargo installed:

```text
cargo fmt --all -- --check
cargo check --locked -j 2
cargo test --locked -j 2
cargo build --locked -j 2
```

Oracle connectivity additionally needs a supported Oracle Instant Client library available to the process. Two connectivity tests are ignored by default; they are not evidence of a successful live database/Redis check. Only with explicitly configured isolated test services run `cargo test --locked -j 2 --test connectivity_test -- --ignored`. These tests read only this crate root's `.env`, and never search parent folders.

## Configuration and run

Use `env.example` as a variable reference. Inject the selected variables into your shell/process; the application does not automatically load `.env`. In PowerShell, for example:

```powershell
$env:HOST = '127.0.0.1'
$env:RUST_BACKEND_PORT = '30003'
$env:LEGACY_BACKEND_BASE_URL = 'http://127.0.0.1:30001'
cargo run --locked -j 2
```

An unavailable Nuxt upstream means proxied business requests cannot succeed. Docker runtime uses port 8080 and Docker-specific upstream settings; provide a reachable `DOCKER_LEGACY_BACKEND_BASE_URL` on your existing network. `docker build -t nekotribe-rust:local .` builds only this project. It does not start or initialize Oracle, Redis, Nuxt or any other service. The inherited Nuxt Compose and publishing workflows were removed.

## Contract and history

The compile-time contract lives in [contracts/v2.openapi.json](contracts/v2.openapi.json); see [its source manifest](contracts/manifest.json). Nuxt `doc/` remains authoritative. This fixed copy does not require sibling source directories at build or runtime; specification coverage and future synchronization are tracked by T11–T13.

Before root extraction, this branch stored the crate in `backend-rust/` and included inherited Nuxt files. That full history, including old migration reports, remains available at commit `ab45d491818ad6a3db3866adf2a2e136be80a49e`. Historical acceptance statements are not current validation results. Native business migration is deferred.