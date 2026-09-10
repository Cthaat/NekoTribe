FROM rust:1.95-bookworm AS build

WORKDIR /workspace/backend-rust

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential pkg-config ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY backend-rust/Cargo.toml backend-rust/Cargo.lock ./
COPY backend-rust/src ./src
COPY backend-rust/tests ./tests
COPY doc/v2.openapi.json /workspace/doc/v2.openapi.json

RUN cargo build --release

FROM container-registry.oracle.com/os/oraclelinux:9-slim AS runtime

WORKDIR /app

RUN microdnf install -y oracle-instantclient-release-el9 ca-certificates curl \
  && microdnf install -y oracle-instantclient19.31-basiclite \
  && microdnf clean all

ENV HOST=0.0.0.0
ENV RUST_BACKEND_PORT=8080
ENV RUST_BACKEND_DOCKER=true
ENV LD_LIBRARY_PATH=/usr/lib/oracle/19.31/client64/lib

COPY --from=build /workspace/backend-rust/target/release/nekotribe-backend /usr/local/bin/nekotribe-backend

EXPOSE 8080

CMD ["nekotribe-backend"]
