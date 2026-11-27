# NekoTribe · Rust 后端

[![最新 Release](https://img.shields.io/github/v/release/Cthaat/NekoTribe?label=Release)](https://github.com/Cthaat/NekoTribe/releases/latest)
[![Rust CI](https://github.com/Cthaat/NekoTribe/actions/workflows/ci-rust.yml/badge.svg?branch=Rust)](https://github.com/Cthaat/NekoTribe/actions/workflows/ci-rust.yml)
[![Docker 镜像](https://img.shields.io/badge/GHCR-rust-2496ED?logo=docker&logoColor=white)](https://github.com/Cthaat/NekoTribe/pkgs/container/nekotribe-rust)
[![Rust](https://img.shields.io/badge/Rust-1.95-000000?logo=rust&logoColor=white)](https://www.rust-lang.org/)

NekoTribe 的高性能 Rust 原生后端，使用 Tokio 和 Axum 提供社区 API 与实时服务。

| 分支 | 组件 | 适用场景 |
| --- | --- | --- |
| [`master`](https://github.com/Cthaat/NekoTribe/tree/master) | Nuxt 4 全栈 | 一次部署社区 Web、API 和实时服务，或单独作为 Web 界面 |
| [`codex/go`](https://github.com/Cthaat/NekoTribe/tree/codex/go) | Go 原生后端 | 复用已有 Oracle / Redis，以纯 Go 二进制或容器提供 API |
| [`Rust`](https://github.com/Cthaat/NekoTribe/tree/Rust)（当前分支） | Rust 原生后端 | 复用已有 Oracle / Redis，以 Rust 二进制或容器提供 API |
| [`Flutter`](https://github.com/Cthaat/NekoTribe/tree/Flutter) | 跨端客户端 | 安装 Windows、Android 应用或部署独立 Web，连接任一后端 |

## ⚡ 快速开始

### A. Docker 部署（推荐）

准备 Docker Engine 或 Docker Desktop（Linux 容器模式）、Docker Compose，以及已经初始化并迁移的 Oracle 和 Redis。默认只启动 **1 个常驻应用容器**。按下方目录运行时，Compose 生成容器名 `nekotribe-rust-rust-1`。

| Compose 服务名 | 镜像 | 用途 | 默认端口（宿主机 → 容器） | 常驻 |
| --- | --- | --- | --- | --- |
| `rust` | `ghcr.io/cthaat/nekotribe-rust:rust` | Rust API、WebSocket 和媒体 | `127.0.0.1:30003 → 8080` | 是 |

Oracle、Redis 由已有部署提供。Qdrant、Ollama 和知识索引服务可按需独立运行。Rust Docker 镜像已内置 Oracle Instant Client。

```sh
git clone --branch Rust --single-branch https://github.com/Cthaat/NekoTribe.git nekotribe-rust
cd nekotribe-rust
cp env.example .env.rust
```

在 Windows PowerShell 中可用 `Copy-Item env.example .env.rust`。在 `.env.rust` 中填入以下配置再启动。容器访问宿主机服务可填 `host.docker.internal`，前提是依赖在该地址上可达。

| 需要填写的配置 | 填法 |
| --- | --- |
| `RUST_APP_IMAGE` | `ghcr.io/cthaat/nekotribe-rust:rust`，也可指定该镜像的 Release 版本标签 |
| `ORACLE_HOST`、`ORACLE_PORT`、`ORACLE_SERVICE_NAME` | 容器可达的 Oracle 地址、端口和 PDB 服务名，例如 Oracle Free 23 的 `FREEPDB1` |
| `ORACLE_USER`、`ORACLE_PASSWORD` | 已初始化的应用 schema 凭据 |
| `REDIS_URL` 或 `REDIS_HOST`、`REDIS_PORT`、`REDIS_DB`、`REDIS_PASSWORD` | 可访问的共享 Redis、逻辑库及所需凭据 |
| `ACCESS_SECRET`、`REFRESH_SECRET` | 对应 Nuxt / 其他后端的签名密钥。访问和刷新使用不同的随机长字符串 |

```sh
docker compose --env-file .env.rust pull rust
docker compose --env-file .env.rust up -d --no-build
docker compose --env-file .env.rust ps
curl --fail http://127.0.0.1:30003/api/ready
```

API 基址为 **http://127.0.0.1:30003**。`/api/ready` 返回 HTTP 200 时，后端可访问 Oracle 和 Redis。Windows PowerShell 中可使用 `curl.exe`。页面使用 [Nuxt Web](https://github.com/Cthaat/NekoTribe/tree/master) 或 [Flutter](https://github.com/Cthaat/NekoTribe/tree/Flutter) 连接该 API。Oracle 19c Enterprise 官方镜像需授权，可连接独立的 Oracle Free 23 或已有 Oracle，按需通过 Nuxt 的纯结构基线和迁移工具准备数据库。[数据库部署](https://github.com/Cthaat/NekoTribe/blob/master/docs/deployment.md#外部数据库--分机)

### B. 运行 Release 预编译包

1. 从 [最新正式版](https://github.com/Cthaat/NekoTribe/releases/latest) 或 [滚动预发布](https://github.com/Cthaat/NekoTribe/releases/tag/rolling-latest) 下载 `NekoTribe-<version>-rust.zip`，滚动版的 `<version>` 为 `latest`。核对同页的 `SHA256SUMS.txt`，解压后进入对应的 `windows-x64/` 或 `linux-x64/`。
2. 安装同架构的 Node.js 22 以运行启动脚本。安装 [Oracle Instant Client](https://www.oracle.com/database/technologies/instant-client.html) x64 Basic 或 Basic Light，Windows 将其目录加入 `PATH`，Linux 使用 `ldconfig` 或 `LD_LIBRARY_PATH`。将 `env.example` 复制为 `.env.rust`，填写宿主机可达的 Oracle、Redis 和签名配置。
3. Windows 双击 `start.cmd`，Linux 执行 `chmod +x ./nekotribe-rust` 后运行 `sh start.sh`。用 `curl --fail http://127.0.0.1:30003/api/ready` 验证后把该 API 基址填入客户端。

### C. 本地源码运行

准备 Rust 1.95.0（Windows 使用 MSVC 工具链，Linux 使用 C/C++ 构建工具）和提前配置好的 Oracle Instant Client、Node.js 22，以及 Oracle 和 Redis。从 Rust 分支的源码根目录复制 `env.example` 为 `.env.rust`。将容器地址改为宿主机可达地址，同时填写 schema 凭据和签名密钥。

三个后端共用 Oracle 基线与迁移。在同版本 Nuxt 源码根目录先运行 `yarn install --frozen-lockfile`，也可用 Nuxt 预编译包并执行 `node scripts/package-nuxt.mjs --prepare .`。如为新库，先完成空 schema 的纯结构初始化。将 `.env` 配置为同一 Oracle schema，获授权后执行以下命令。[基线、迁移与权限](https://github.com/Cthaat/NekoTribe/blob/master/docs/deployment.md#新-oracle-库只创建应用结构)

```sh
node scripts/migrate-db.mjs --apply --dotenv .env
node scripts/migrate-db.mjs --check --dotenv .env
```

回到 Rust 源码根目录启动。Windows 也可双击 `start.cmd`。

```sh
node scripts/start-native.mjs rust --env-file .env.rust
```

## 核心功能

- 社交动态、关注、评论、互动和媒体上传。
- 群组管理、实时频道聊天、私信和通知。
- 内容与账号审核、举报和申诉。
- 可配置的 AI 写作、群知识问答、群运营和审核助手。

## 常用配置与连接

| 设置 | 默认值或用法 |
| --- | --- |
| 本机监听 | `127.0.0.1:30003`，使用 `HOST`、`RUST_BACKEND_PORT` 调整 |
| 容器发布 | `RUST_PUBLISH_HOST`、`RUST_PUBLISH_PORT`，容器内监听 `0.0.0.0:8080` |
| API / 实时 / 公开媒体 | API 基址为发布地址，默认路径为 `/api/v2/`、`/_ws`、`/storage/` |
| 浏览器跨域 | 在 `CORS_ALLOWED_ORIGINS` 中列出实际 Web 客户端来源，启用 HTTPS 时设置 `COOKIE_SECURE=true` |
| 邮件与审核 | 邮箱验证码使用 `SMTP_*`，审核权限由 `MODERATION_ADMIN_ACCOUNTS` 指定 |

- **切换后端**：Nuxt、Go、Rust 可共用 Oracle schema、Redis 实例及逻辑库。对应的 JWT 密钥和有效期、媒体位置、审核账号及 AI 配额需一致。[运行约定](contracts/runtime-addresses.md)
- **AI 模型**：使用 `AI_MODEL_CONFIG_FILE` 或 `AI_MODEL_CONFIG_JSON` 选择模型与角色绑定，通过引用的环境变量提供凭据。容器可使用 `compose.ai-model.yaml` 和 `NEKO_AI_MODEL_CONFIG_DIR` 挂载配置。知识索引用 `AI_KNOWLEDGE_INDEX_URL` 和 `AI_INDEX_SERVICE_TOKEN` 接入。[模型与知识索引部署](https://github.com/Cthaat/NekoTribe/blob/master/docs/deployment.md)
- **媒体存储**：默认 `STORAGE_TYPE=local`，Docker 用 `NEKO_STORAGE_SOURCE` 指定挂载到 `/app/storage` 的宿主机目录。切换至 `STORAGE_TYPE=s3` 时，填写 `STORAGE_S3_*`，与其他后端统一存储位置、公开路径和 CDN 地址。

## 架构与目录

<details>
<summary>Rust、Axum、Tokio、Oracle、Redis</summary>

| 路径 | 内容 |
| --- | --- |
| `src/main.rs` | 服务入口 |
| `src/` | Axum 路由、业务逻辑、数据访问和存储 |
| `tests/` | 路由和契约测试 |
| `contracts/` | 共享 OpenAPI、运行约定、行为场景和来源清单 |
| `scripts/` | 本地启动、后端打包和端点检查 |

</details>

## 参与开发

Rust 可运行与 CI 一致的离线测试。

```sh
cargo test --locked --lib --test contract_test --test ai_knowledge_route_test --test ai_conversation_route_test
```

从 Nuxt 源码根目录运行共享契约检查。四个工作树位于同一父目录时可执行：

```sh
node scripts/contracts.mjs check --workspace-root ..
node scripts/parity.mjs check --workspace-root ..
```

更多说明见 [全项目文档总索引 (master)](https://github.com/Cthaat/NekoTribe/blob/master/docs/README.md)、[Rust 分支文档说明](docs/README.md)、[部署手册](https://github.com/Cthaat/NekoTribe/blob/master/docs/deployment.md)、[OpenAPI](contracts/v2.openapi.json) 和 [运行约定](contracts/runtime-addresses.md)。
