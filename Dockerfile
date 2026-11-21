ARG GO_BUILD_IMAGE=golang:1.26-bookworm
FROM ${GO_BUILD_IMAGE} AS build

WORKDIR /workspace
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
COPY contracts ./contracts
RUN CGO_ENABLED=0 go build -trimpath -o /out/nekotribe-go ./cmd/server

FROM debian:bookworm-slim AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl ffmpeg \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /out/nekotribe-go /usr/local/bin/nekotribe-go
ENV HOST=0.0.0.0 GO_BACKEND_PORT=8080 STORAGE_PATH=/app/storage
EXPOSE 8080
CMD ["nekotribe-go"]
