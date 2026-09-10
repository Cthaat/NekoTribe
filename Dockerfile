FROM rust:1.95-bookworm AS build

WORKDIR /workspace

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential pkg-config ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY tests ./tests
COPY contracts/v2.openapi.json ./contracts/v2.openapi.json

RUN cargo build --locked --release -j 2

FROM container-registry.oracle.com/os/oraclelinux:9-slim AS runtime

WORKDIR /app

RUN microdnf install -y oracle-instantclient-release-el9 ca-certificates curl \
  && microdnf install -y oracle-instantclient19.31-basiclite \
  && microdnf clean all

ENV HOST=0.0.0.0
ENV RUST_BACKEND_PORT=8080
ENV RUST_BACKEND_DOCKER=true
ENV LD_LIBRARY_PATH=/usr/lib/oracle/19.31/client64/lib

COPY --from=build /workspace/target/release/nekotribe-backend /usr/local/bin/nekotribe-backend

EXPOSE 8080

CMD ["nekotribe-backend"]
