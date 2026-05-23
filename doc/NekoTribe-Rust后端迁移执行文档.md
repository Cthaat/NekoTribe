# NekoTribe Rust 后端迁移执行文档

> **给 AI 执行者的硬性要求：** 必须按阶段执行本文档。一次只做一个阶段；每个阶段完成后运行该阶段的验证命令，并把验收结果写回阶段记录。不要跳阶段，不要一次性重写整个后端。

**目标：** 将当前 Nuxt/Nitro TypeScript 后端迁移为可独立运行的 Rust 后端，并保持现有前端、Oracle 数据库、Redis、WebSocket、文件存储路径和 v2 API 契约不变。

**目标架构：** 第一版 Rust 后端只迁移后端运行时，不重建业务数据库，不重写前端契约。Rust 服务暴露 `/api/v2/**`、`/_ws`、`/storage/**`、`/uploads/**` 和 `/api/health`；Oracle 19c 继续作为唯一主业务库；Redis 继续承担限流、透明缓存和实时 Pub/Sub。

**推荐 Rust 技术栈：** Rust stable toolchain、Cargo edition 2021、`axum`、`tokio`、`tower`、`tower-http`、`serde`、`serde_json`、`oracle`、`redis`、`jsonwebtoken`、`bcrypt`、`reqwest`、`uuid`、`tracing`、`thiserror`。技术栈依据当前官方文档核对：`axum` 面向 Tokio/Hyper 并使用 Tower 中间件生态；`oracle` crate 基于 ODPI-C，运行时依赖 Oracle Client；`redis` crate 支持 Tokio 异步连接和 ConnectionManager；`jsonwebtoken` 用于 JWT 创建和解析。

---

> 适用日期：2026-05-23
> 适用仓库：`C:\Code\NekoTribe`
> 输出位置：`doc/NekoTribe-Rust后端迁移执行文档.md`
> 使用方式：把本文档按阶段交给 AI。每次只执行一个阶段，阶段验收通过后再进入下一阶段。

## 0. 迁移总原则

### 0.1 必须保持不变的外部契约

Rust 后端第一版必须兼容当前前端，不允许先改前端来迁就后端。

- v2 API 基础路径保持 `/api/v2/**`。
- WebSocket 路径保持 `/_ws`。
- 健康检查保持 `/api/health`。
- 静态存储访问保持 `/storage/**`。
- 旧 `/uploads/**` 返回 410，并返回现有 JSON 结构。
- SentimentFlow 代理路径保持 `/api/v2/integrations/sentiment-flow/**`。
- 未匹配的 `/api/v2/**` 返回 HTTP 404，响应体 `code=40404`、`message="API route not found"`。
- v2 响应统一使用：

```json
{
  "code": 200,
  "message": "success",
  "data": {},
  "meta": null
}
```

- 分页 `meta` 字段保持：

```json
{
  "page": 1,
  "page_size": 20,
  "total": 100,
  "has_next": true
}
```

- DTO 字段保持 snake_case，例如 `user_id`、`created_at`、`avatar_url`。
- 认证 Cookie 名称保持 `access_token`、`refresh_token`。
- Cookie 属性保持 `HttpOnly`、`SameSite=Lax`、`Path=/`，`Secure` 由 `COOKIE_SECURE=true` 控制。
- 前端仍可以通过 `Authorization: Bearer <token>` 或 `access_token` Cookie 鉴权；优先读取 Cookie，再读取 Bearer。
- 除非进入 v1 兼容阶段，否则 Rust 第一版默认只迁移 v2。当前 v1 API 受 `ENABLE_V1_API` 控制，默认禁用。

### 0.2 必须保留的数据库策略

当前业务规则大量依赖 Oracle 19c 的表、序列、触发器、视图和 PL/SQL 函数。Rust 迁移不能把第一版改成 MySQL/PostgreSQL，也不要用 ORM 自动建表覆盖现有 schema。

必须以 `doc/neko_tribe-oracle-v2.sql` 为数据库基线。当前基线统计如下：

- 52 张 `n_` 业务表
- 22 个 `v_` 视图
- 20 个 `fn_` PL/SQL 函数
- 34 个 `seq_` 序列
- 78 个触发器

Rust 第一版继续直接使用这些对象。SQL 中的 Oracle 特性必须保留：

- `ROW_NUMBER() OVER (...)`
- `FETCH FIRST ... ROWS ONLY`
- `MERGE INTO`
- `DBMS_LOB.SUBSTR`
- `NUMTODSINTERVAL`
- `SYSTIMESTAMP`
- `CURRENT_TIMESTAMP`
- `seq_xxx.NEXTVAL`
- `fn_can_view_post`
- `fn_get_user_relationship`
- `fn_has_group_permission`
- `fn_can_post_in_group`
- `fn_can_view_group`

### 0.3 推荐 Rust 技术栈

建议创建独立目录 `backend-rust/`，不要把 Rust 文件散放到现有 Nuxt `server/` 目录。

推荐组合：

| 能力 | Rust 方案 | 迁移理由 |
|---|---|---|
| HTTP 路由 | `axum` | 与 Tokio/Hyper 生态契合，路由、extractor、JSON 响应和 WebSocket 能力完整 |
| 异步运行时 | `tokio` | Redis、HTTP proxy、WebSocket 和 graceful shutdown 都需要稳定 async runtime |
| 中间件 | `tower`、`tower-http` | 适合实现 tracing、request id、CORS、超时、body limit、安全头 |
| JSON/DTO | `serde`、`serde_json` | 严格控制 snake_case DTO 和 v2 envelope |
| Oracle | `oracle` crate | 直接平移 Oracle SQL；注意它基于 ODPI-C，通常需要 Oracle Client |
| Oracle 阻塞隔离 | `tokio::task::spawn_blocking` + 有界连接池 | `oracle` crate 是同步驱动，不能直接阻塞 Tokio worker |
| Redis | `redis` crate，启用 `tokio-comp`、`connection-manager` | 覆盖普通命令、TTL、Pub/Sub、自动重连 |
| JWT | `jsonwebtoken` | 兼容 access/refresh token payload 和 HS256 |
| 密码 | `bcrypt` | 必须兼容现有 bcrypt hash，不能擅自改 Argon2 |
| 邮件 | `lettre` 或 SMTP 包装 | 实现 OTP、登录提醒、账号邮件 |
| HTTP proxy | `reqwest` | SentimentFlow 代理、超时、redirect 控制 |
| Multipart | `axum` multipart 或 `multer` | 媒体上传、头像上传 |
| MIME/媒体 | `mime_guess`、`infer`、`image`、`ffprobe` 命令 | 对齐当前 MIME、宽高、duration 提取 |
| 日志 | `tracing`、`tracing-subscriber` | 结构化日志、request span、错误追踪 |
| 错误 | `thiserror` | 业务错误、基础设施错误和 HTTP 输出分层 |
| 测试 | `cargo test`、`cargo clippy`、`tower::ServiceExt` | 每阶段可验收 |

Rust Oracle 驱动注意事项：

- `oracle` crate 基于 ODPI-C，运行时需要 Oracle Client 11.2+ 或 Instant Client。
- Windows 本地开发要把 Instant Client 目录加入 `PATH`。
- Linux/Docker 镜像要配置 `LD_LIBRARY_PATH` 或动态链接器路径。
- 因为 Oracle 驱动是同步接口，所有数据库读写必须经过统一 DB executor，用 `spawn_blocking` 包住阻塞操作，并用 pool/semaphore 限制并发。
- 不要在 Axum handler 中直接调用同步 Oracle API。
- 不要第一版使用 `sqlx`，因为本项目依赖 Oracle，第一阶段目标是平移 SQL 语义而不是换数据库生态。
- 如果 AI 想换纯 Rust Oracle 驱动，必须先验证当前所有 Oracle 特性、CLOB、TIMESTAMP、事务、视图、序列、named bind 和连接池行为；第一版不建议冒这个风险。

### 0.4 当前后端阅读结论

当前后端中心不在一个简单 controller 层，而是分散在这些文件：

```text
server/
  api/
    health.get.ts
    v1/                         # 旧接口，默认被 ENABLE_V1_API 控制
    v2/                         # 当前主 API，共 149 个实际路由文件
  middleware/
    auth.ts                     # v1/v2 JWT 鉴权中间件
    rate-limit.ts               # Redis IP 限流
  plugins/
    01-redisClient.ts           # Redis 单例注入
    02-oracle.ts                # Oracle 连接池注入和查询缓存包装
    03-log.ts                   # 请求日志
    04-global-hooks.ts          # 响应和错误日志
    05-security-headers.ts      # 安全响应头
  services/v2/
    auth.ts                     # 注册、登录、刷新、登出、2FA、会话、OTP
    users.ts                    # 用户资料、设置、邮箱、头像、关系、账号处置
    posts.ts                    # 帖子、评论、点赞、收藏、标签、统计
    groups.ts                   # 群组、成员、群组帖子、邀请、审计
    chat.ts                     # 群组聊天、频道、消息、反应、私聊
    notifications.ts            # 通知存储、读取、删除、实时推送
    presence.ts                 # 在线状态
    moderation.ts               # 内容审核、举报、用户处罚、审核设置、申诉
    media.ts                    # 媒体上传和删除
  models/v2.ts                  # 公共映射器，PublicUser/Post/Group/Media/Notification
  storage/                      # 本地/S3 存储抽象和文件读取
  routes/
    _ws.ts                      # WebSocket
    storage/[...segments].get.ts
    uploads/[...segments].get.ts
  utils/
    v2.ts                       # v2 响应、分页、参数解析、DB helper
    oracle.ts                   # Oracle pool
    oracle-query-cache.ts       # Oracle SELECT 透明 Redis 缓存
    api-cache.ts                # v2 GET 响应 Redis 缓存
    redis.ts                    # Redis Pub/Sub
    redis-config.ts             # Redis 配置
    wsSession.ts                # WebSocket 会话管理
    logging.ts                  # 请求日志和脱敏
    sentiment-flow.ts           # SentimentFlow 配置和 URL 拼接
```

Rust 迁移要先做横切能力，再迁移业务模块。否则每个模块都会重复造响应、鉴权、分页、Oracle 执行、Redis 缓存、日志、错误处理。

## 1. Rust 后端目标结构

建议生成如下目录：

```text
backend-rust/
  Cargo.toml
  Cargo.lock
  .cargo/
    config.toml                  # 可选：Windows/Linux Oracle client 链接配置说明
  src/
    main.rs
    app/
      mod.rs
      routes.rs
      state.rs
      shutdown.rs
    config/
      mod.rs
      env.rs
    httpx/
      mod.rs
      response.rs
      errors.rs
      pagination.rs
      request.rs
      json.rs
      extractors.rs
    middleware/
      mod.rs
      request_id.rs
      logging.rs
      security_headers.rs
      recover.rs
      rate_limit.rs
      auth.rs
      cache.rs
    db/
      mod.rs
      oracle.rs
      pool.rs
      query.rs
      tx.rs
      row.rs
      value.rs
      nullable.rs
    cache/
      mod.rs
      redis.rs
      api_cache.rs
      oracle_query_cache.rs
      tags.rs
    auth/
      mod.rs
      jwt.rs
      cookies.rs
      password.rs
      otp.rs
      two_factor.rs
      sessions.rs
      mail.rs
    storage/
      mod.rs
      config.rs
      provider.rs
      local.rs
      s3.rs
      http.rs
      media.rs
    ws/
      mod.rs
      hub.rs
      session.rs
      redis_bridge.rs
      handler.rs
      protocol.rs
    modules/
      mod.rs
      shared/
        mod.rs
        models.rs
        mappers.rs
      users/
        mod.rs
        handler.rs
        service.rs
        repository.rs
        dto.rs
      posts/
        mod.rs
        handler.rs
        service.rs
        repository.rs
        dto.rs
      groups/
        mod.rs
        handler.rs
        service.rs
        repository.rs
        dto.rs
      chat/
        mod.rs
        handler.rs
        service.rs
        repository.rs
        dto.rs
      notifications/
        mod.rs
        handler.rs
        service.rs
        repository.rs
        dto.rs
      moderation/
        mod.rs
        handler.rs
        service.rs
        repository.rs
        dto.rs
      media/
        mod.rs
        handler.rs
        service.rs
        repository.rs
        dto.rs
      integrations/
        mod.rs
        sentiment_flow.rs
  tests/
    health_test.rs
    auth_test.rs
    contract_test.rs
```

### 1.1 文件职责边界

- `main.rs` 只负责加载配置、初始化 state、启动 Axum、graceful shutdown。
- `app/routes.rs` 只装配路由，不写业务 SQL。
- `httpx` 只处理 v2 响应、错误、分页、请求解析。
- `middleware` 只处理横切逻辑：日志、安全头、鉴权、限流、缓存。
- `db` 只封装 Oracle 驱动、连接池、事务、行映射和类型转换。
- `cache` 只封装 Redis、API response cache、Oracle query cache 和 tag version。
- `modules/*/handler.rs` 只负责 HTTP extractors 和调用 service。
- `modules/*/service.rs` 负责业务规则、事务边界和副作用。
- `modules/*/repository.rs` 负责 SQL，不直接写 HTTP 响应。
- `modules/*/dto.rs` 负责请求/响应结构，必须加 `#[serde(rename_all = "snake_case")]` 或字段级 `rename`。

### 1.2 Rust 公共响应结构

必须先实现这些结构，所有模块复用：

```rust
use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct V2Response<T>
where
    T: Serialize,
{
    pub code: i32,
    pub message: String,
    pub data: T,
    pub meta: Option<V2Meta>,
}

#[derive(Debug, Serialize)]
pub struct V2NullResponse {
    pub code: i32,
    pub message: String,
    pub data: Option<()>,
    pub meta: Option<V2Meta>,
}

#[derive(Debug, Clone, Serialize)]
pub struct V2Meta {
    pub page: Option<u32>,
    pub page_size: Option<u32>,
    pub total: Option<u64>,
    pub has_next: Option<bool>,
}

#[derive(Debug, Clone)]
pub struct PageState {
    pub page: u32,
    pub page_size: u32,
    pub start_row: u64,
    pub end_row: u64,
}
```

错误码保持：

| HTTP | code | Rust helper | message 默认值 |
|---:|---:|---|---|
| 400 | 40001 | `bad_request` | `请求参数错误` |
| 401 | 40101 | `unauthorized` | `请先登录` |
| 403 | 40301 | `forbidden` | `权限不足` |
| 404 | 40401 | `not_found` | `资源不存在` |
| 409 | 40901 | `conflict` | `资源冲突` |
| 422 | 42201 | `unprocessable` | `请求无法处理` |
| 500 | 50001 | `server_error` | `服务器内部错误` |
| 404 | 40404 | `route_not_found` | `API route not found` |

### 1.3 Rust 配置映射

Rust 配置必须从现有 `.env.example`、`nuxt.config.ts` 的 runtimeConfig 对齐，不要创造新名字破坏部署。

| 配置 | Rust 字段 | 默认值/规则 |
|---|---|---|
| `HOST` | `server.host` | `0.0.0.0` |
| `PORT` 或 `RUST_BACKEND_PORT` | `server.port` | 建议 `8080` |
| `ACCESS_TOKEN_SECRET` | `auth.access_token_secret` | 必填 |
| `REFRESH_TOKEN_SECRET` | `auth.refresh_token_secret` | 必填 |
| `ACCESS_TOKEN_EXPIRES_IN` | `auth.access_token_expires_in` | 对齐当前值 |
| `REFRESH_TOKEN_EXPIRES_IN` | `auth.refresh_token_expires_in` | 对齐当前值 |
| `COOKIE_SECURE` | `auth.cookie_secure` | `false` |
| `ORACLE_HOST` | `oracle.host` | 必填 |
| `ORACLE_PORT` | `oracle.port` | `1521` |
| `ORACLE_SERVICE_NAME` | `oracle.service_name` | 必填 |
| `ORACLE_USER` | `oracle.user` | 必填 |
| `ORACLE_PASSWORD` | `oracle.password` | 必填 |
| `ORACLE_POOL_MIN` | `oracle.pool_min` | `2` |
| `ORACLE_POOL_MAX` | `oracle.pool_max` | `10` |
| `REDIS_URL` | `redis.url` | 优先级最高 |
| `REDIS_HOST` | `redis.host` | `127.0.0.1` |
| `REDIS_PORT` | `redis.port` | `6379` |
| `REDIS_DB` | `redis.db` | `0` |
| `REDIS_PASSWORD` | `redis.password` | 可空 |
| `SMTP_HOST`、`SMTP_PORT`、`SMTP_USER`、`SMTP_PASS` | `mail.*` | OTP 邮件 |
| `STORAGE_TYPE` | `storage.kind` | `local` |
| `STORAGE_PATH` 或 `STORAGE_ROOT_DIR` | `storage.root_dir` | 本地文件根目录 |
| `STORAGE_PUBLIC_BASE` | `storage.public_base` | `/storage` |
| `STORAGE_CDN_BASE_URL` | `storage.cdn_base_url` | 可空 |
| `SENTIMENTFLOW_ENABLED` | `sentiment_flow.enabled` | `false` |
| `SENTIMENTFLOW_BASE_URL` | `sentiment_flow.base_url` | 可从 host/port 推导 |
| `SENTIMENTFLOW_TIMEOUT_MS` | `sentiment_flow.timeout_ms` | `10000` |
| `MODERATION_ALLOW_ALL` | `moderation.allow_all` | `false` |
| `MODERATION_ADMIN_ACCOUNTS` | `moderation.admin_accounts` | 默认 `v2_admin` |
| `ENABLE_V1_API` | `compat.enable_v1_api` | `false` |

## 2. 分阶段迁移计划

每个阶段都必须做到：

- 新增或修改的 Rust 文件经过 `cargo fmt --all`。
- 运行 `cargo test --all`。
- 运行 `cargo clippy --all-targets -- -D warnings`；如果某阶段因外部 Oracle Client 缺失无法 clippy，要记录实际错误，不要假装通过。
- 运行本阶段指定的 curl 或 WebSocket 验收。
- 阶段完成后不要顺手重构其他阶段。
- 每个阶段可以单独提交一次，提交信息建议 `feat(rust-backend): stage N ...`。

### 阶段 1：创建 Rust 后端骨架和公共契约

**目标**

创建可启动的 Rust 服务，实现 `/api/health`、v2 响应结构、统一错误、分页、路由兜底、安全响应头和请求日志。

**输入文件**

- `package.json`
- `nuxt.config.ts`
- `.env.example`
- `server/api/health.get.ts`
- `server/api/v2/[...path].ts`
- `server/utils/v2.ts`
- `server/plugins/03-log.ts`
- `server/plugins/04-global-hooks.ts`
- `server/plugins/05-security-headers.ts`
- `server/utils/logging.ts`

**要创建的 Rust 文件**

- `backend-rust/Cargo.toml`
- `backend-rust/src/main.rs`
- `backend-rust/src/app/mod.rs`
- `backend-rust/src/app/routes.rs`
- `backend-rust/src/app/state.rs`
- `backend-rust/src/config/mod.rs`
- `backend-rust/src/config/env.rs`
- `backend-rust/src/httpx/mod.rs`
- `backend-rust/src/httpx/response.rs`
- `backend-rust/src/httpx/errors.rs`
- `backend-rust/src/httpx/pagination.rs`
- `backend-rust/src/httpx/request.rs`
- `backend-rust/src/middleware/mod.rs`
- `backend-rust/src/middleware/request_id.rs`
- `backend-rust/src/middleware/logging.rs`
- `backend-rust/src/middleware/security_headers.rs`
- `backend-rust/src/middleware/recover.rs`

**实现要求**

- 使用 `axum::Router` 创建应用。
- `GET /api/health` 返回：

```json
{
  "status": "ok",
  "service": "nekotribe",
  "timestamp": "ISO-8601"
}
```

- `/api/v2/*` 未匹配路由返回：

```json
{
  "code": 40404,
  "message": "API route not found",
  "data": null,
  "meta": null
}
```

- `ok(data)` 默认 message 为 `success`。
- `ok_with_message(data, message)` 支持自定义 message。
- `null_response(message)` 返回 `data:null`、`meta:null`。
- `ApiError` 包含 `status`、`code`、`message`，实现 `IntoResponse`。
- panic/rejection 统一输出 `50001` 或对应业务错误，生产环境不把 stack 放入响应。
- `PageState::from_query` 读取 `page`、`page_size`，默认 `1/20`，最大 `page_size=100`，生成 `start_row` 和 `end_row`，对齐当前 `v2Page`。
- 请求日志必须脱敏这些 query/header：`access_token`、`refresh_token`、`token`、`password`、`new_password`、`confirm_password`、`authorization`、`cookie`、`secret`、`client_secret`、`code`。
- 响应头保持：
  - `X-Content-Type-Options: nosniff`
  - `X-Frame-Options: DENY`
  - `Referrer-Policy: same-origin`
  - `Permissions-Policy: camera=(), microphone=(), geolocation=()`
  - `COOKIE_SECURE=true` 时增加 HSTS。

**验收**

```powershell
cd backend-rust
cargo fmt --all
cargo test --all
cargo clippy --all-targets -- -D warnings
cargo run
```

新开终端：

```powershell
curl.exe http://127.0.0.1:8080/api/health
curl.exe -i http://127.0.0.1:8080/api/v2/not-exists
```

必须看到 `/api/health` 为 `status=ok`，未匹配 v2 路由为 HTTP 404 且 `code=40404`。

**给 AI 的阶段提示词**

```text
请只执行《NekoTribe-Rust后端迁移执行文档》的阶段 1。创建 backend-rust Rust 项目骨架，使用 axum/tokio/tower，实现 /api/health、v2 响应结构、统一错误、分页、请求日志、安全响应头和 /api/v2/** 兜底 40404。不要迁移业务接口，不要连接 Oracle/Redis。完成后运行 cargo fmt --all、cargo test --all、cargo clippy --all-targets -- -D warnings，并用 curl 验证 /api/health 与 /api/v2/not-exists。
```

### 阶段 2：基础设施层 Oracle、Redis、限流和缓存框架

**目标**

让 Rust 后端能连接 Oracle 和 Redis，完成连接池、DB helper、事务、IP 限流、API 响应缓存和 Oracle 查询缓存的框架。

**输入文件**

- `server/utils/oracle.ts`
- `server/plugins/02-oracle.ts`
- `server/utils/redis.ts`
- `server/utils/redis-config.ts`
- `server/plugins/01-redisClient.ts`
- `server/middleware/rate-limit.ts`
- `server/utils/api-cache.ts`
- `server/utils/oracle-query-cache.ts`
- `doc/neko_tribe-oracle-v2.sql`
- `.env.example`

**要创建的 Rust 文件**

- `backend-rust/src/db/mod.rs`
- `backend-rust/src/db/oracle.rs`
- `backend-rust/src/db/pool.rs`
- `backend-rust/src/db/query.rs`
- `backend-rust/src/db/tx.rs`
- `backend-rust/src/db/row.rs`
- `backend-rust/src/db/value.rs`
- `backend-rust/src/db/nullable.rs`
- `backend-rust/src/cache/mod.rs`
- `backend-rust/src/cache/redis.rs`
- `backend-rust/src/cache/tags.rs`
- `backend-rust/src/cache/api_cache.rs`
- `backend-rust/src/cache/oracle_query_cache.rs`
- `backend-rust/src/middleware/rate_limit.rs`
- `backend-rust/src/middleware/cache.rs`

**Oracle 实现要求**

- DSN 由 `ORACLE_HOST`、`ORACLE_PORT`、`ORACLE_SERVICE_NAME`、`ORACLE_USER`、`ORACLE_PASSWORD` 拼出。
- Docker 模式优先读取 `DOCKER_ORACLE_HOST`、`DOCKER_ORACLE_PORT`。
- poolMin/poolMax 对齐 `.env.example`：默认 2/10。
- `OraclePool` 必须隐藏同步驱动细节，对外暴露 async API：
  - `query_rows(ctx, sql, binds) -> Vec<DbRow>`
  - `query_one(ctx, sql, binds) -> Option<DbRow>`
  - `execute(ctx, sql, binds) -> ExecuteResult`
  - `next_id(ctx, "seq_post_id") -> i64`
  - `count(ctx, sql, binds) -> u64`
  - `transaction(ctx, |tx| ...)`
- 每次 Oracle 操作必须进入 `spawn_blocking`，并由 semaphore 限制最大阻塞任务数，不能直接阻塞 Tokio worker。
- `DbRow` 使用 `BTreeMap<String, DbValue>` 或等价结构，列名统一大写，便于平移当前 mapper。
- `DbValue` 至少覆盖 `Null`、`String`、`I64`、`F64`、`BoolNumber`、`JsonString`、`TimestampString`。
- CLOB 必须转字符串。当前 TS 代码多处使用 `DBMS_LOB.SUBSTR(..., 4000, 1)`，Rust 平移时优先保留 SQL 侧转换。
- TIMESTAMP 返回给 DTO 时统一格式化为 ISO 字符串。
- 业务层多步写入必须用事务，例如媒体上传、发帖、群组发帖、聊天消息。
- `n_auth_sessions.last_accessed_at` 这类心跳更新不要触发大范围缓存失效。

**Redis 实现要求**

- 支持 `REDIS_URL` 优先，其次 `REDIS_HOST`、`REDIS_PORT`、`REDIS_DB`、`REDIS_PASSWORD`。
- Redis 连接失败时，限流、缓存、Pub/Sub 要能降级，不能让普通请求直接崩溃。
- 普通命令建议使用 `ConnectionManager`；Pub/Sub 使用独立连接或独立 async task。
- 保留 Redis channel：
  - `ws:broadcast`
  - `ws:user:{userId}`
  - `ws:room:{roomId}`
  - `ws:chat:channel:{channelId}`
  - `ws:presence`
  - `ws:system`
- 限流 key 保持 `rate_limit:{ip}`。
- 限流窗口保持 10 秒 100 次，Redis TTL 保持 120 秒，超限返回 HTTP 429，message 为 `请求过于频繁，请稍后再试`。

**缓存实现要求**

API 响应缓存对应 `server/utils/api-cache.ts`：

- 只缓存成功的 GET。
- 默认 prefix：`nt:api-cache`。
- hit prefix：`nt:api-cache-hits`。
- tag version prefix：`nt:api-cache-tag`。
- schema version 保持 `1`。
- tag version TTL 保持 7 天。
- 通过 method、path、query、authenticated user id、tag versions 生成稳定 key。
- 非 GET 成功后按路径标签递增版本，避免写后读到旧数据。
- OTP、2FA challenge、token refresh 等敏感接口不缓存。

Oracle 查询缓存对应 `server/utils/oracle-query-cache.ts`：

- prefix：`nt:oracle-query-cache`。
- hit prefix：`nt:oracle-query-cache-hits`。
- tag version prefix：`nt:oracle-query-cache-tag`。
- schema version 保持 `2`。
- 只缓存安全 `SELECT` / `WITH` 查询。
- 跳过含有 `NEXTVAL`、`FOR UPDATE`、`password_hash`、`access_token`、`refresh_token`、`access_jti`、`verification_code`、`sessions` 的 SQL。
- cache id 包含 normalized SQL、binds、options、viewer、tag versions。
- 命中热 key 时延长 TTL。
- mutation SQL 成功后按涉及表/域名递增 tag version。

**验收**

```powershell
cd backend-rust
cargo fmt --all
cargo test --all
cargo clippy --all-targets -- -D warnings
cargo run
curl.exe http://127.0.0.1:8080/api/health
```

再增加内部测试：

- 执行 `SELECT 1 AS total FROM dual`，确认 Oracle 可连。
- 执行 Redis `PING`，确认 Redis 可连。
- Redis 不可用时，普通请求仍能返回 `/api/health`。
- 模拟安全 SELECT 命中 query cache，模拟 mutation 后 tag version 增加。

**给 AI 的阶段提示词**

```text
请只执行阶段 2。基于当前 server/utils/oracle.ts、redis.ts、api-cache.ts、oracle-query-cache.ts、rate-limit.ts，在 backend-rust 中实现 Oracle/Redis 基础设施、DB helper、事务、限流、缓存框架。Rust Oracle 驱动必须通过统一 async wrapper + spawn_blocking 使用，不允许 handler 直接阻塞 Tokio。不要迁移业务模块。保留 Redis key/channel 前缀和 Oracle SQL 规则。完成后运行 cargo fmt、cargo test、cargo clippy，并验证 Oracle SELECT 1、Redis PING、/api/health。
```

### 阶段 3：认证、安全、OTP、会话和双因素认证

**目标**

迁移 v2 auth 模块，完成 JWT、Cookie、注册、登录、刷新、登出、OTP、密码重置、会话列表、会话撤销、TOTP 双因素认证、可信设备和登录提醒。

**输入文件**

- `server/middleware/auth.ts`
- `server/services/v2/auth.ts`
- `server/services/v2/notifications.ts`
- `server/models/v2.ts`
- `server/utils/v2.ts`
- `doc/neko_tribe-oracle-v2.sql`

**要创建的 Rust 文件**

- `backend-rust/src/middleware/auth.rs`
- `backend-rust/src/auth/jwt.rs`
- `backend-rust/src/auth/cookies.rs`
- `backend-rust/src/auth/password.rs`
- `backend-rust/src/auth/otp.rs`
- `backend-rust/src/auth/two_factor.rs`
- `backend-rust/src/auth/sessions.rs`
- `backend-rust/src/auth/mail.rs`
- `backend-rust/src/modules/auth/mod.rs`
- `backend-rust/src/modules/auth/handler.rs`
- `backend-rust/src/modules/auth/service.rs`
- `backend-rust/src/modules/auth/repository.rs`
- `backend-rust/src/modules/auth/dto.rs`

**接口清单**

- `POST /api/v2/auth/otp`
- `POST /api/v2/auth/otp/verification`
- `POST /api/v2/auth/password-reset`
- `POST /api/v2/auth/registration`
- `POST /api/v2/auth/tokens`
- `PATCH /api/v2/auth/tokens/current`
- `DELETE /api/v2/auth/tokens/current`
- `GET /api/v2/auth/sessions`
- `DELETE /api/v2/auth/sessions/{id}`
- `DELETE /api/v2/auth/sessions/others`
- `POST /api/v2/auth/two-factor/challenges`
- `POST /api/v2/auth/two-factor/challenges/{id}`
- `POST /api/v2/users/me/two-factor/setup`
- `POST /api/v2/users/me/two-factor/confirm`
- `DELETE /api/v2/users/me/two-factor`

**公开路由**

以下路径不要求 access token：

- `/api/v2/auth/otp`
- `/api/v2/auth/otp/verification`
- `/api/v2/auth/registration`
- `/api/v2/auth/tokens`
- `/api/v2/auth/two-factor/challenges`
- `/api/v2/auth/two-factor/challenges/{id}`
- `/api/v2/auth/tokens/current`
- `/api/v2/auth/password-reset`

注意：`PATCH /api/v2/auth/tokens/current` 使用 refresh cookie，不使用 access token。`DELETE /api/v2/auth/tokens/current` 要允许 access token 失效时仍可通过 refresh token 找 session 并清 cookie。

**JWT 规则**

Access token payload：

```json
{
  "userId": 1000,
  "userName": "demo",
  "sessionId": "sess_uuid",
  "type": "access",
  "jti": "uuid",
  "iat": 0,
  "exp": 0
}
```

Refresh token payload：

```json
{
  "userId": 1000,
  "userName": "demo",
  "sessionId": "sess_uuid",
  "type": "refresh",
  "iat": 0,
  "exp": 0
}
```

数据库会话表 `n_auth_sessions` 必须存：

- `session_id`
- `user_id`
- `access_jti`
- `refresh_token_hash`，使用 SHA-256 hex
- `device_info`，来自 `x-device-info`，默认 `unknown`
- `device_fingerprint`，来自 `x-device-fingerprint`，默认 `unknown`
- `ip_address`
- `user_agent`
- `access_token_expires_at`
- `refresh_token_expires_at`
- `last_accessed_at`
- `last_refresh_at`
- `revoked_at`

**OTP 规则**

- 验证码 6 位数字。
- 有效期 300 秒。
- `verification_id` 格式 `otp_<uuid>`。
- OTP 存 Oracle 表 `n_auth_otp_events`，不是 Redis。
- `verification_code_hash` 用 bcrypt。
- 注册必须先验证 `register` 类型 OTP。
- 密码重置必须验证 `password_reset` 类型 OTP。
- 邮件发送用 SMTP 配置；开发环境如没有 SMTP，可以由测试注入 fake mailer，但生产代码不要跳过邮件。

**双因素认证规则**

- TOTP 周期 30 秒，6 位，允许前后 1 个 step 漂移。
- secret 使用 Base32。
- secret 存库前加密，迁移 Rust 时必须保留加密字段：`secret_encrypted`、`secret_iv`、`secret_auth_tag`。
- recovery codes 生成 10 个，入库 hash，返回给用户明文只出现一次。
- 可信设备有效 30 天。
- 2FA challenge 有效期 300 秒。
- 设置 2FA 前必须校验当前密码。
- `two_factor_enabled` 只能通过 2FA 流程修改，不能被普通 settings PATCH 直接改。

**验收**

至少完成这些自动化或手动验证：

- 注册 OTP 创建和校验。
- 注册成功后 `n_users` 有新用户，`email_verified_at` 非空。
- 登录成功设置 `access_token`、`refresh_token` Cookie。
- Access token 过期或伪造时返回 `40101`。
- Refresh 成功时更新 `access_jti`、`refresh_token_hash`、`last_refresh_at`。
- Logout 后 `revoked_at` 非空，Cookie 被清除。
- 2FA 开启后登录返回 `two_factor_required=true`，完成 challenge 后才发 session。
- 会话列表分页 meta 正确。

**给 AI 的阶段提示词**

```text
请只执行阶段 3。迁移 v2 auth：JWT、Cookie、OTP、注册、登录、refresh、logout、sessions、2FA setup/confirm/disable、2FA challenge。严格参考 server/middleware/auth.ts 和 server/services/v2/auth.ts。保持响应 code/message/data/meta、Cookie 名称、bcrypt 兼容、Oracle 表结构和登录提醒副作用。完成后运行 cargo fmt、cargo test、cargo clippy，并用 curl 验证登录、refresh、logout、sessions。
```

### 阶段 4：公共 DTO 映射、用户、账号设置和关系模块

**目标**

迁移 `server/models/v2.ts` 中的公共 mapper，并完成用户资料、设置、账号处置、关注、拉黑、静音、推荐用户和用户统计。

**输入文件**

- `server/models/v2.ts`
- `server/services/v2/users.ts`
- `server/services/v2/presence.ts`
- `server/services/v2/auth.ts`
- `app/types/v2.ts`
- `server/types/v2.d.ts`

**要创建的 Rust 文件**

- `backend-rust/src/modules/shared/models.rs`
- `backend-rust/src/modules/shared/mappers.rs`
- `backend-rust/src/modules/users/mod.rs`
- `backend-rust/src/modules/users/handler.rs`
- `backend-rust/src/modules/users/service.rs`
- `backend-rust/src/modules/users/repository.rs`
- `backend-rust/src/modules/users/dto.rs`
- `backend-rust/src/modules/presence/mod.rs`
- `backend-rust/src/modules/presence/service.rs`

**接口清单**

- `GET /api/v2/users`
- `GET /api/v2/users/recommendations`
- `GET /api/v2/users/{id}`
- `GET /api/v2/users/{id}/analytics`
- `GET /api/v2/users/{id}/analytics/daily`
- `GET /api/v2/users/{id}/followers`
- `POST /api/v2/users/{id}/followers`
- `DELETE /api/v2/users/{id}/followers`
- `GET /api/v2/users/{id}/following`
- `GET /api/v2/users/{id}/mutual-following`
- `GET /api/v2/users/{id}/posts`
- `GET /api/v2/users/me`
- `PATCH /api/v2/users/me`
- `DELETE /api/v2/users/me`
- `PUT /api/v2/users/me/avatar`
- `PATCH /api/v2/users/me/email`
- `GET /api/v2/users/me/settings`
- `PATCH /api/v2/users/me/settings`
- `GET /api/v2/users/me/posts`
- `GET /api/v2/users/me/likes`
- `GET /api/v2/users/me/bookmarks`
- `GET /api/v2/users/me/groups`
- `GET /api/v2/users/me/group-invites`
- `GET /api/v2/users/me/blocks`
- `POST /api/v2/users/me/blocks/{target_id}`
- `DELETE /api/v2/users/me/blocks/{target_id}`
- `GET /api/v2/users/me/mutes`
- `POST /api/v2/users/me/mutes/{target_id}`
- `DELETE /api/v2/users/me/mutes/{target_id}`
- `GET /api/v2/users/me/account-statements`
- `PATCH /api/v2/users/me/account-statements/{id}`
- `POST /api/v2/users/me/account-statements/{id}/appeals`

**DTO 映射规则**

必须实现这些公共结构，JSON tag 使用 snake_case：

- `PublicUser`
- `SelfUser`
- `Relationship`
- `UserSettings`
- `AccountStatement`
- `StatementAppealData`
- `MediaAsset`
- `Post`
- `Comment`
- `Notification`
- `Group`

Rust DTO 必须避免把 Oracle NULL 误转成空字符串。除非现有 TypeScript mapper 明确返回空字符串，否则 nullable 字段使用 `Option<T>`。

`PublicUser` 的在线状态逻辑保持：

- `n_user_settings.show_online_status=0` 时返回 `online_status="hidden"`，`last_seen_at=null`。
- 最近 90 秒内有未 revoked 的 session，则 `online`。
- 否则 `offline`。

头像 URL 规则保持：

- 空头像返回默认头像路径。
- `/storage/**` URL 要标准化。
- 旧 `/upload` 或 `/uploads` 引用要按现有 storage normalize 逻辑处理。

账号设置规则：

- 若 `n_user_settings` 不存在，使用 `MERGE` 创建。
- AI 情感分析偏好字段必须保留：
  - `ai_sentiment_enabled`
  - `ai_sentiment_model_id`
  - `ai_sentiment_return_probabilities`
  - `ai_sentiment_include_metadata`
  - `ai_sentiment_top_k`
- `ai_sentiment_top_k` 限制 1 到 10，默认 3。
- `profile_visibility` 只允许 `public`、`private`。
- `two_factor_enabled` 不能通过 settings PATCH 修改。
- `show_online_status` 变化后要发布 presence 更新。

关系规则：

- 关注自己返回业务错误。
- 拉黑用户时要删除双方关注关系。
- 被拉黑、隐私设置、静音等逻辑必须对齐 `users.ts` 的 SQL。
- `fn_get_user_relationship(:viewer_id, user_id)` 仍作为关系来源。

**验收**

- 登录后 `GET /api/v2/users/me` 返回完整 `SelfUser`。
- `PATCH /api/v2/users/me/settings` 可以更新 AI 设置并再次读取。
- `PATCH /api/v2/users/me/settings` 传 `two_factor_enabled` 返回 40001。
- 关注/取消关注后 followers/following 计数变化。
- block 后关系状态变为 blocking，并删除关注关系。
- `GET /api/v2/users/{id}` 对 hidden 在线状态返回 `hidden` 且 `last_seen_at=null`。

**给 AI 的阶段提示词**

```text
请只执行阶段 4。迁移公共 v2 DTO mapper、用户资料、账号设置、关注/拉黑/静音、账号处置、用户统计和推荐用户。严格参考 server/models/v2.ts 与 server/services/v2/users.ts。保持 snake_case DTO、Oracle 视图/函数、settings AI 字段和 presence 更新。完成后运行 cargo fmt、cargo test、cargo clippy，并验证 /users/me、settings、follow、block。
```

### 阶段 5：存储和媒体模块

**目标**

迁移本地/S3 存储抽象、媒体上传、头像上传、媒体删除、`/storage/**` 文件读取和旧 `/uploads/**` 410。

**输入文件**

- `server/storage/config.ts`
- `server/storage/index.ts`
- `server/storage/http.ts`
- `server/storage/providers/local.ts`
- `server/storage/providers/s3.ts`
- `server/routes/storage/[...segments].get.ts`
- `server/routes/uploads/[...segments].get.ts`
- `server/services/v2/media.ts`
- `server/services/v2/users.ts`

**要创建的 Rust 文件**

- `backend-rust/src/storage/config.rs`
- `backend-rust/src/storage/provider.rs`
- `backend-rust/src/storage/local.rs`
- `backend-rust/src/storage/s3.rs`
- `backend-rust/src/storage/http.rs`
- `backend-rust/src/storage/media.rs`
- `backend-rust/src/modules/media/mod.rs`
- `backend-rust/src/modules/media/handler.rs`
- `backend-rust/src/modules/media/service.rs`
- `backend-rust/src/modules/media/repository.rs`
- `backend-rust/src/modules/media/dto.rs`

**接口清单**

- `POST /api/v2/media`
- `DELETE /api/v2/media/{id}`
- `PUT /api/v2/users/me/avatar`
- `GET /storage/**`
- `GET /uploads/**`

**存储规则**

- `STORAGE_TYPE=local` 默认。
- `STORAGE_PATH` 或 `STORAGE_ROOT_DIR` 指向根目录。
- `STORAGE_PUBLIC_BASE` 默认 `/storage`。
- `STORAGE_CDN_BASE_URL` 存在时生成 CDN 公开 URL。
- 默认头像 `default-avatar.png` 不存在时返回当前内置 PNG fallback。
- `/storage/**` 支持 Range 请求：
  - 无 Range 返回 200。
  - 有合法 Range 返回 206。
  - 非法 Range 返回 416。
  - 响应头包括 `Accept-Ranges`、`Cache-Control`、`Content-Type`、`ETag`、`Last-Modified`、`Content-Length`。
- `/uploads/**` 返回 HTTP 410，响应体：

```json
{
  "code": 410,
  "message": "Legacy /uploads path removed. Public files are served from /storage.",
  "data": {
    "requested_path": "/uploads/...",
    "storage_base": "/storage"
  },
  "meta": null
}
```

**媒体规则**

- 上传必须是 `multipart/form-data`。
- 文件字段名支持 `file` 或 `media`。
- 媒体最大 500MB。
- 头像最大 10MB，只允许 gif/jpeg/png。
- 帖子媒体允许 image、gif、video、audio、document、archive 等当前 MIME 集合。
- 图片宽高要提取；视频/音频 duration 建议用 ffprobe 或等效工具提取。
- 上传成功写入 `n_media_assets`，状态 `ready`。
- 上传数据库写入失败时删除已写入的物理文件。
- 删除媒体时必须校验 owner，删除 DB 后清理 `storage_key`、`public_url`、`thumbnail_url` 对应文件。

**验收**

- 上传图片后返回 `media_id`、`public_url`、`width`、`height`。
- 用返回的 `public_url` 请求 `/storage/**` 能读取文件。
- Range 请求视频/大文件返回 206。
- 删除媒体后 DB 记录消失且文件被删除。
- 请求 `/uploads/test.png` 返回 410。

**给 AI 的阶段提示词**

```text
请只执行阶段 5。迁移 storage、media upload/delete、avatar upload、/storage/** 文件读取和 /uploads/** 410。参考 server/storage 与 server/services/v2/media.ts。保留 MIME、大小、Range、默认头像、事务失败清理规则。完成后运行 cargo fmt、cargo test、cargo clippy，并用 multipart curl 验证上传、读取、删除。
```

### 阶段 6：帖子、评论、标签、推荐反馈和举报入口

**目标**

迁移帖子 feed、发帖、改帖、删帖、点赞、收藏、评论、回复、转发、标签搜索、趋势、统计、推荐反馈和普通用户举报入口。

**输入文件**

- `server/services/v2/posts.ts`
- `server/models/v2.ts`
- `server/services/v2/notifications.ts`
- `doc/neko_tribe-oracle-v2.sql`

**要创建的 Rust 文件**

- `backend-rust/src/modules/posts/mod.rs`
- `backend-rust/src/modules/posts/handler.rs`
- `backend-rust/src/modules/posts/service.rs`
- `backend-rust/src/modules/posts/repository.rs`
- `backend-rust/src/modules/posts/dto.rs`

**接口清单**

- `GET /api/v2/posts`
- `POST /api/v2/posts`
- `GET /api/v2/posts/trending`
- `GET /api/v2/posts/{id}`
- `PUT /api/v2/posts/{id}`
- `DELETE /api/v2/posts/{id}`
- `GET /api/v2/posts/{id}/analytics`
- `POST /api/v2/posts/{id}/likes`
- `GET /api/v2/posts/{id}/likes`
- `DELETE /api/v2/posts/{id}/likes`
- `POST /api/v2/posts/{id}/bookmarks`
- `DELETE /api/v2/posts/{id}/bookmarks`
- `GET /api/v2/posts/{id}/comments`
- `POST /api/v2/posts/{id}/comments`
- `GET /api/v2/posts/{id}/replies`
- `GET /api/v2/posts/{id}/retweets`
- `POST /api/v2/posts/{id}/retweets`
- `DELETE /api/v2/comments/{id}`
- `POST /api/v2/comments/{id}/likes`
- `DELETE /api/v2/comments/{id}/likes`
- `GET /api/v2/tags`
- `GET /api/v2/tags/trending`
- `GET /api/v2/tags/{name}/posts`
- `GET /api/v2/tags/{name}/analytics`
- `POST /api/v2/recommendations/feedback`
- `POST /api/v2/reports`

**核心业务规则**

- Feed 查询继续以 `v_post_feed_item` 和 `fn_can_view_post` 为核心。
- `v2PostSelectSql`、`v2PostCountSql`、`v2SortOrder` 的语义要平移，不要重新设计 feed 排序。
- `sort` 需要支持当前实现中的 `latest`、`popular`、`trending` 等排序。
- 发帖支持 `content`、`visibility`、`reply_to_id`、`quote_post_id`、`media_ids`、`tags`、`mentions`。
- 发帖、评论、点赞、转发、收藏都要更新对应 stats 或依赖触发器。
- 帖子删除为软删除，不能物理删业务主表。
- 评论删除、群组评论删除也要保持软删除语义。
- 点赞/取消点赞、收藏/取消收藏重复操作要幂等或返回现有业务错误。
- 创建评论、点赞、转发、私信等副作用必须创建通知。
- 普通举报 `POST /api/v2/reports` 在 moderation 阶段会复用，这里先保证用户入口可用。

**缓存失效要求**

- 发帖、改帖、删帖、评论、点赞、收藏、转发、标签变动后必须让 `posts`、`users`、`tags`、`media`、`notifications` 相关缓存失效。
- 不能只清单个 post key，因为 feed、用户主页、标签页、趋势页都会受影响。

**验收**

- 发帖后 `GET /api/v2/posts` 第一页能看到。
- 改帖后立即读取详情不会返回旧内容。
- 删除后详情返回 40401 或 feed 不再出现。
- 点赞后 likes_count 变化，并给作者创建通知。
- 收藏后 `GET /api/v2/users/me/bookmarks` 出现。
- 评论后 comments_count/replies_count 正确。
- 标签搜索和标签详情页返回分页 meta。

**给 AI 的阶段提示词**

```text
请只执行阶段 6。迁移 posts/comments/tags/recommendations/reports 模块。严格参考 server/services/v2/posts.ts 与 server/models/v2.ts，保留 Oracle SQL、视图、函数、通知副作用和缓存失效。完成后运行 cargo fmt、cargo test、cargo clippy，并验证发帖、改帖、删帖、点赞、评论、标签。
```

### 阶段 7：群组模块

**目标**

迁移群组、成员、通知偏好、群组帖子、群组评论、邀请、所有权转移和审计日志。

**输入文件**

- `server/services/v2/groups.ts`
- `server/models/v2.ts`
- `server/services/v2/notifications.ts`
- `doc/neko_tribe-oracle-v2.sql`

**要创建的 Rust 文件**

- `backend-rust/src/modules/groups/mod.rs`
- `backend-rust/src/modules/groups/handler.rs`
- `backend-rust/src/modules/groups/service.rs`
- `backend-rust/src/modules/groups/repository.rs`
- `backend-rust/src/modules/groups/dto.rs`

**接口清单**

- `GET /api/v2/groups`
- `POST /api/v2/groups`
- `GET /api/v2/groups/popular`
- `GET /api/v2/groups/{id}`
- `PATCH /api/v2/groups/{id}`
- `DELETE /api/v2/groups/{id}`
- `GET /api/v2/groups/by-slug/{slug}`
- `GET /api/v2/groups/{id}/notification-preference`
- `PUT /api/v2/groups/{id}/notification-preference`
- `GET /api/v2/groups/{id}/members`
- `POST /api/v2/groups/{id}/members/current`
- `DELETE /api/v2/groups/{id}/members/current`
- `PUT /api/v2/groups/{id}/members/{user_id}/approval-status`
- `DELETE /api/v2/groups/{id}/members/{user_id}`
- `PATCH /api/v2/groups/{id}/members/{user_id}/role`
- `PATCH /api/v2/groups/{id}/members/{user_id}/roles`
- `PUT /api/v2/groups/{id}/members/{user_id}/mute-status`
- `DELETE /api/v2/groups/{id}/members/{user_id}/mute-status`
- `PUT /api/v2/groups/{id}/ownership`
- `GET /api/v2/groups/{id}/posts`
- `POST /api/v2/groups/{id}/posts`
- `GET /api/v2/groups/{id}/posts/{post_id}`
- `DELETE /api/v2/groups/{id}/posts/{post_id}`
- `PUT /api/v2/groups/{id}/posts/{post_id}/pin-status`
- `POST /api/v2/groups/{id}/posts/{post_id}/likes`
- `DELETE /api/v2/groups/{id}/posts/{post_id}/likes`
- `GET /api/v2/groups/{id}/posts/{post_id}/comments`
- `POST /api/v2/groups/{id}/posts/{post_id}/comments`
- `DELETE /api/v2/groups/{id}/posts/{post_id}/comments/{comment_id}`
- `POST /api/v2/groups/{id}/posts/{post_id}/comments/{comment_id}/likes`
- `DELETE /api/v2/groups/{id}/posts/{post_id}/comments/{comment_id}/likes`
- `POST /api/v2/groups/{id}/invites`
- `GET /api/v2/groups/{id}/invites`
- `GET /api/v2/groups/invite-codes/{code}`
- `POST /api/v2/groups/invites/{invite_id}/responses`
- `GET /api/v2/groups/{id}/audit-logs`

**核心业务规则**

- 群组访问继续使用 Oracle 函数：
  - `fn_can_view_group`
  - `fn_has_group_permission`
  - `fn_can_post_in_group`
- 创建群组后创建 owner 成员。
- slug 生成规则对齐 `v2Slug` 与 `fn_generate_group_slug`。
- privacy 只允许 `public`、`private`、`secret`。
- post_permission 只允许 `all`、`admin_only`、`moderator_up`。
- category 支持 `tech/game/music/art/life/study/work/other` 或 null。
- group tags 写入 `n_group_tags`，更新时先删后插。
- 通知偏好存 `n_group_notification_preferences`。
- 入群支持公开直接加入、需要审批、邀请码加入。
- 成员角色支持 owner/admin/moderator/member。
- owner 不能被普通移除；转移 ownership 要事务处理。
- 群组帖子、评论、点赞要触发通知。
- `v2EnsureGroupFeatureSchema` 当前会请求时补列/补表；Rust 迁移时应把这些 DDL 固化到 baseline 或启动前 schema check，不建议在普通请求里执行 DDL。

**验收**

- 创建群组后自己是 owner。
- public group 可加入，private/approval group 按状态返回。
- 创建群组帖子后成员收到通知。
- moderator/admin 权限能 pin/delete，普通 member 不能。
- 邀请码创建、校验、接受/拒绝流程可用。
- 审计日志能看到管理操作。

**给 AI 的阶段提示词**

```text
请只执行阶段 7。迁移 groups 模块，包括群组 CRUD、成员、权限、群组帖子/评论/点赞、邀请、通知偏好、所有权转移、审计日志。参考 server/services/v2/groups.ts。保留 Oracle 函数权限判断、DTO 字段、通知副作用和缓存失效。完成后运行 cargo fmt、cargo test、cargo clippy，并验证创建群组、入群、发群组帖子、邀请和审计日志。
```

### 阶段 8：通知模块

**目标**

迁移通知存储、列表、读取状态、删除、恢复和实时通知事件发布。

**输入文件**

- `server/services/v2/notifications.ts`
- `server/models/v2.ts`
- `server/utils/redis.ts`

**要创建的 Rust 文件**

- `backend-rust/src/modules/notifications/mod.rs`
- `backend-rust/src/modules/notifications/handler.rs`
- `backend-rust/src/modules/notifications/service.rs`
- `backend-rust/src/modules/notifications/repository.rs`
- `backend-rust/src/modules/notifications/dto.rs`

**接口清单**

- `GET /api/v2/notifications`
- `PUT /api/v2/notifications/read-status`
- `PUT /api/v2/notifications/{id}/read-status`
- `DELETE /api/v2/notifications/{id}`
- `PUT /api/v2/notifications/{id}/restore-status`

**核心业务规则**

- 通知表 `n_notifications` 是唯一持久来源。
- `metadata_json` 如果是 CLOB，要用 SQL 转字符串，例如 `DBMS_LOB.SUBSTR(metadata_json, 4000, 1) AS metadata_json`。
- `V2Notification.metadata` 返回 JSON object 或 null，不返回 Oracle Lob 对象。
- 创建通知时检查用户通知偏好：
  - `n_user_settings.push_notification_enabled`
  - `n_notification_preferences`
- canPush 为 true 时发布 Redis user channel：`ws:user:{userId}`。
- 事件类型包括：
  - `notification_created`
  - `notification_read_status_updated`
  - `notifications_read_status_updated`
  - `notification_deleted`
  - `notification_restored`
- 批量 read status 支持传 `notification_ids`，为空时更新当前用户全部未删除通知。

**验收**

- 列表分页 meta 正确。
- 单条已读后 WebSocket 收到 `notification_read_status_updated`。
- 批量已读后 WebSocket 收到 `notifications_read_status_updated`。
- 删除后列表默认不显示。
- 恢复后列表能显示。
- metadata 不出现序列化错误。

**给 AI 的阶段提示词**

```text
请只执行阶段 8。迁移 notifications 模块和通知事件发布。参考 server/services/v2/notifications.ts。保留 n_notifications、metadata_json CLOB 字符串化、用户通知偏好和 Redis user channel 事件。完成后运行 cargo fmt、cargo test、cargo clippy，并验证列表、已读、批量已读、删除、恢复。
```

### 阶段 9：聊天、WebSocket 和在线状态

**目标**

迁移群组聊天、频道、消息、反应、私聊、WebSocket 会话管理、Redis Pub/Sub、presence online/offline。

**输入文件**

- `server/routes/_ws.ts`
- `server/utils/wsSession.ts`
- `server/utils/redis.ts`
- `server/services/v2/chat.ts`
- `server/services/v2/presence.ts`
- `server/services/v2/notifications.ts`

**要创建的 Rust 文件**

- `backend-rust/src/ws/mod.rs`
- `backend-rust/src/ws/hub.rs`
- `backend-rust/src/ws/session.rs`
- `backend-rust/src/ws/redis_bridge.rs`
- `backend-rust/src/ws/handler.rs`
- `backend-rust/src/ws/protocol.rs`
- `backend-rust/src/modules/chat/mod.rs`
- `backend-rust/src/modules/chat/handler.rs`
- `backend-rust/src/modules/chat/service.rs`
- `backend-rust/src/modules/chat/repository.rs`
- `backend-rust/src/modules/chat/dto.rs`

**REST 接口清单**

- `GET /api/v2/chat/groups`
- `GET /api/v2/chat/groups/{id}/channels`
- `POST /api/v2/chat/groups/{id}/channels`
- `GET /api/v2/chat/groups/{id}/members`
- `PATCH /api/v2/chat/channels/{channel_id}`
- `DELETE /api/v2/chat/channels/{channel_id}`
- `GET /api/v2/chat/channels/{channel_id}/messages`
- `POST /api/v2/chat/channels/{channel_id}/messages`
- `PUT /api/v2/chat/channels/{channel_id}/read-status`
- `PUT /api/v2/chat/channels/{channel_id}/mute-status`
- `PATCH /api/v2/chat/messages/{message_id}`
- `DELETE /api/v2/chat/messages/{message_id}`
- `PUT /api/v2/chat/messages/{message_id}/pin-status`
- `POST /api/v2/chat/messages/{message_id}/reactions`
- `DELETE /api/v2/chat/messages/{message_id}/reactions`
- `GET /api/v2/chat/direct-conversations`
- `POST /api/v2/chat/direct-conversations`
- `GET /api/v2/chat/direct-conversations/{conversation_id}/messages`
- `POST /api/v2/chat/direct-conversations/{conversation_id}/messages`

**WebSocket 契约**

路径：`GET /_ws`

认证 token 提取顺序：

1. query `?token=...`
2. `Authorization: Bearer ...`
3. Cookie `access_token`

连接时必须验证：

- access token 有效。
- payload 包含 `userId`、`sessionId`、`jti`。
- `n_auth_sessions` 中存在匹配 session，`revoked_at IS NULL`，`access_token_expires_at > CURRENT_TIMESTAMP`。
- 成功后更新 `last_accessed_at`。

客户端发给服务端的消息：

```json
{ "type": "chat_join_channel", "data": { "channel_id": 1 } }
```

```json
{ "type": "chat_leave_channel", "data": { "channel_id": 1 } }
```

```json
{ "type": "ping" }
```

服务端返回消息统一：

```json
{
  "type": "chat_message",
  "data": {},
  "timestamp": 1760000000000
}
```

事件类型必须覆盖：

- `chat_message`
- `chat_message_updated`
- `chat_message_deleted`
- `chat_reaction_updated`
- `chat_channel_updated`
- `direct_message`
- `notification_created`
- `notification_read_status_updated`
- `notifications_read_status_updated`
- `notification_deleted`
- `notification_restored`
- `presence_update`
- `pong`
- `error`
- `system_notification`

presence 规则：

- 同一用户多连接时，只要还有一个连接，就保持 online。
- 第一个连接上线时发布 `presence_update`。
- 最后一个连接关闭后延迟 95 秒再发布 offline；如果期间重连，取消 offline。
- ping 时 touch auth session。
- presence 发布到 Redis `ws:presence`，并带 `server_id`，同服务收到自己发的消息要忽略。

聊天规则：

- 频道访问由 `v2CanAccessChatChannel` 对齐。
- 加入频道前必须校验成员权限。
- 群聊事件发布到 `ws:chat:channel:{channelId}`。
- 私聊事件发布到双方 `ws:user:{userId}`。
- `allow_dm_from_strangers=false` 且双方无关系时禁止私信。
- 被拉黑时禁止私信。
- 聊天消息支持 media_ids、reply_to、reaction、pin、soft delete。
- direct message 创建要创建通知并发布 `direct_message`。

**验收**

- 未登录连接 `/_ws` 收到 error 后关闭。
- 登录用户连接成功收到 `system_notification`。
- `chat_join_channel` 无权限时收到 error。
- 有权限加入后发频道消息，另一个连接收到 `chat_message`。
- 编辑、删除、reaction、pin 都能收到相应事件。
- 私聊双方都能收到 `direct_message`。
- 用户上线/离线产生 `presence_update`。

**给 AI 的阶段提示词**

```text
请只执行阶段 9。迁移 chat REST、direct message、WebSocket /_ws、ws session manager、Redis Pub/Sub、presence。参考 server/routes/_ws.ts、server/utils/wsSession.ts、server/services/v2/chat.ts、presence.ts。保留认证顺序、Redis channels、事件 JSON、95 秒离线延迟、聊天权限和通知副作用。完成后运行 cargo fmt、cargo test、cargo clippy，并用两个客户端验证群聊、私聊、presence。
```

### 阶段 10：审核、举报、处罚和申诉模块

**目标**

迁移内容审核队列、举报、审核动作、批量动作、用户处罚、审核设置和申诉处理。

**输入文件**

- `server/services/v2/moderation.ts`
- `server/services/v2/users.ts`
- `server/models/v2.ts`
- `.env.example`

**要创建的 Rust 文件**

- `backend-rust/src/modules/moderation/mod.rs`
- `backend-rust/src/modules/moderation/handler.rs`
- `backend-rust/src/modules/moderation/service.rs`
- `backend-rust/src/modules/moderation/repository.rs`
- `backend-rust/src/modules/moderation/dto.rs`

**接口清单**

- `GET /api/v2/moderation/content`
- `POST /api/v2/moderation/content/{post_id}/actions`
- `POST /api/v2/moderation/content/bulk-actions`
- `GET /api/v2/moderation/stats`
- `GET /api/v2/moderation/reports`
- `PATCH /api/v2/moderation/reports/{report_id}`
- `GET /api/v2/moderation/users`
- `POST /api/v2/moderation/users/{user_id}/actions`
- `GET /api/v2/moderation/settings`
- `PATCH /api/v2/moderation/settings`
- `GET /api/v2/moderation/appeals`
- `PATCH /api/v2/moderation/appeals/{appeal_id}`
- `POST /api/v2/reports`
- `GET /api/v2/users/me/account-statements`
- `PATCH /api/v2/users/me/account-statements/{id}`
- `POST /api/v2/users/me/account-statements/{id}/appeals`

**审核权限规则**

审核后台权限不是群组角色，不是聊天角色。必须按当前 `requireModerationAccess()` 迁移：

- 如果 `MODERATION_ALLOW_ALL=true`，已登录用户都可访问审核后台。
- 否则读取 `MODERATION_ADMIN_ACCOUNTS`，用英文逗号分隔。
- 没配置时默认允许账号 `v2_admin`。
- 当前用户的 username 或 email 命中允许列表才可访问。
- 未命中返回 `40301`，message `需要审核权限`。

**枚举规则**

- report reason：`spam`、`harassment`、`hate`、`violence`、`adult`、`misinformation`、`copyright`、`other`
- priority：`low`、`normal`、`high`、`urgent`
- report status：`pending`、`in_review`、`resolved`、`dismissed`
- case status：`pending`、`approved`、`rejected`、`flagged`、`removed`、`restored`
- target type：`post`、`comment`、`user`、`group_post`、`group_comment`
- content action：`approve`、`reject`、`flag`、`remove`、`restore`、`claim`、`release`
- user action：`ban`、`unban`、`mute`、`unmute`、`note`

**核心业务规则**

- 普通举报入口 `POST /api/v2/reports` 需要登录，但不需要审核权限。
- 举报后要写 `n_moderation_reports`，必要时创建或更新 `n_moderation_cases`。
- 审核内容 action 要写 `n_moderation_actions`。
- remove/restore 要同步目标内容状态，例如 `n_posts`、`n_comments`、`n_group_posts`、`n_group_comments`。
- 用户 ban/mute 要写 `n_moderation_user_restrictions` 并同步 `n_users.status` 或可见限制。
- 用户申诉写 `n_statement_appeals`。
- 审核设置缺失时插入默认设置：
  - `auto_hide_report_threshold=10`
  - `require_note_on_reject=true`
  - `allow_moderator_claim=true`
  - `default_mute_hours=24`

**验收**

- 非审核账号访问 `/api/v2/moderation/stats` 返回 40301。
- 配置 `MODERATION_ALLOW_ALL=true` 后已登录用户可访问。
- 创建 report 后审核队列出现。
- claim/release、remove/restore、bulk actions 可用。
- ban/mute/unban/unmute 可用并生成账号处置记录。
- 用户可查看 account statements 并提交 appeal。

**给 AI 的阶段提示词**

```text
请只执行阶段 10。迁移 moderation、reports、account statements、appeals。参考 server/services/v2/moderation.ts 和 users.ts。重点保留 requireModerationAccess 的账号白名单规则、枚举、审核动作副作用、默认设置和账号处置/申诉流程。完成后运行 cargo fmt、cargo test、cargo clippy，并验证非审核账号 403、审核账号可处理举报。
```

### 阶段 11：SentimentFlow 代理和系统边界

**目标**

迁移 SentimentFlow 配置接口和透明代理，保证前端 AI 情感分析入口继续通过 NekoTribe 后端访问外部 SentimentFlow。

**输入文件**

- `server/utils/sentiment-flow.ts`
- `server/api/v2/integrations/sentiment-flow/config.get.ts`
- `server/api/v2/integrations/sentiment-flow/[...path].ts`
- `.env.example`
- `doc/api.md`

**要创建的 Rust 文件**

- `backend-rust/src/modules/integrations/mod.rs`
- `backend-rust/src/modules/integrations/sentiment_flow.rs`

**接口清单**

- `GET /api/v2/integrations/sentiment-flow/config`
- `ANY /api/v2/integrations/sentiment-flow/**`

**配置接口响应**

```json
{
  "code": 200,
  "message": "sentimentflow config",
  "data": {
    "enabled": true,
    "baseUrlConfigured": true,
    "proxyBasePath": "/api/v2/integrations/sentiment-flow",
    "timeoutMs": 10000
  },
  "meta": null
}
```

**代理规则**

- `SENTIMENTFLOW_ENABLED=false` 时返回 HTTP 503，v2 proxy error body。
- `SENTIMENTFLOW_BASE_URL` 为空时使用默认 `http://localhost:${SENTIMENTFLOW_HOST_PORT || SENTIMENTFLOW_CONTAINER_PORT || 8846}/api`。
- path 需要 normalize：
  - 去掉开头 `/`
  - 禁止 absolute upstream URL
  - 禁止 `.`、`..`
  - 最终 URL 不能逃逸 configured base URL
- query 原样追加。
- 阻止转发这些 request headers：
  - `host`
  - `connection`
  - `content-length`
  - `transfer-encoding`
  - `upgrade`
  - `keep-alive`
  - `proxy-authenticate`
  - `proxy-authorization`
  - `authorization`
  - `te`
  - `trailer`
  - `cookie`
- 阻止返回这些 response headers：
  - `connection`
  - `content-length`
  - `content-encoding`
  - `transfer-encoding`
  - `upgrade`
  - `keep-alive`
  - `location`
  - `proxy-authenticate`
  - `proxy-authorization`
  - `te`
  - `trailer`
- 手动处理上游 redirect，最多 5 次，redirect 不能逃逸 base URL。
- 301/302 + POST 或 303 要按当前逻辑转 GET。
- 超时返回 504，message `SentimentFlow request timed out`。
- 上游失败返回 502，message `SentimentFlow upstream request failed`。

**验收**

- disabled 时 config 显示 disabled，代理返回 503。
- enabled 且 baseUrl 可用时，`/models`、`/models/active`、`/predict/` 可以通过代理访问。
- 尝试代理 `http://evil.com` 返回 400。
- 尝试 `../` path traversal 返回 400。
- 上游超时返回 504。

**给 AI 的阶段提示词**

```text
请只执行阶段 11。迁移 SentimentFlow config 和 proxy。参考 server/utils/sentiment-flow.ts 与 server/api/v2/integrations/sentiment-flow。保留 enabled/baseUrl/timeout、path 安全检查、header blocklist、redirect 限制和 502/503/504 错误格式。完成后运行 cargo fmt、cargo test、cargo clippy，并验证 disabled、enabled、非法 path、timeout。
```

### 阶段 12：v1 兼容层和部署切换

**目标**

明确旧 `/api/v1/**` 策略，完成 Docker/Nginx/前端联调，让 Rust 后端可以替换 Nitro 后端。

**输入文件**

- `server/api/v1/**`
- `server/middleware/auth.ts`
- `docker-compose.yml`
- `Dockerfile`
- `nginx/nginx.compose.conf`
- `.env.example`
- `README.md`

**要创建或修改的文件**

- `backend-rust/Dockerfile`
- `backend-rust/.dockerignore`
- `docker-compose.yml`
- `nginx/nginx.compose.conf`
- `.env.example`
- `README.md` 或新增部署说明文档

**v1 策略**

推荐第一版 Rust 后端：

- 默认 `ENABLE_V1_API=false`。
- `ANY /api/v1/**` 返回 HTTP 410。
- 响应可使用 v1 风格或简单 JSON，但要说明 legacy disabled。
- 只有当前端仍有真实 v1 调用时，才逐个迁移 v1。不要主动迁移全部 v1 增加风险。

**部署切换策略**

推荐两阶段切换：

1. 并行运行：
   - Nuxt 前端仍运行现有服务。
   - Rust 后端监听 `8080`。
   - Nginx 将 `/api/**`、`/_ws`、`/storage/**` 转发到 Rust。
   - 其他页面和前端资源转发到 Nuxt。
2. 完全替换后端：
   - 删除或停用 Nuxt Nitro server API。
   - 前端仅作为静态/SSR 前端。
   - Rust 服务成为唯一 API、WS、storage 服务。

**Docker 要求**

- 新增 `backend-rust/Dockerfile`。
- Rust 镜像要包含 Oracle Client 依赖。
- 容器内监听端口建议 `8080`。
- Compose 中增加 `rust-backend` 服务。
- Rust 后端依赖 `redis` healthy 和 `db-init` completed。
- storage volume 继续挂载同一目录。
- healthcheck 使用 `GET /api/health`。

**Nginx 路由要求**

- `/api/` -> Rust backend
- `/_ws` -> Rust backend，并支持 WebSocket upgrade
- `/storage/` -> Rust backend 或 Nginx 静态目录，必须和当前行为一致
- `/uploads/` -> Rust backend 返回 410
- 前端页面 -> Nuxt/frontend

**验收**

- `docker compose config` 通过。
- `docker compose up -d rust-backend` 后 healthcheck healthy。
- 前端页面调用 `/api/v2/users/me` 命中 Rust。
- 浏览器 WebSocket 连接 `/_ws` 命中 Rust。
- 上传文件后 `/storage/**` 可访问。
- `/api/v1/users/me` 默认返回 410。

**给 AI 的阶段提示词**

```text
请只执行阶段 12。添加 Rust 后端 Dockerfile、Compose 服务、Nginx 转发和 v1 410 兼容层。不要迁移 v1 业务实现。确保 /api/**、/_ws、/storage/** 进入 Rust，前端页面仍可访问。完成后运行 docker compose config，并做 /api/health、/api/v2/users/me、/_ws、/uploads/** 验收。
```

## 3. 全量 v2 路由迁移索引

AI 每完成一个模块必须对照本节勾选。当前 `server/api/v2` 共有 149 个实际路由文件，不包括兜底 `[...path].ts`。

### 3.1 Auth

- `POST /api/v2/auth/otp`
- `POST /api/v2/auth/otp/verification`
- `POST /api/v2/auth/password-reset`
- `POST /api/v2/auth/registration`
- `GET /api/v2/auth/sessions`
- `DELETE /api/v2/auth/sessions/{id}`
- `DELETE /api/v2/auth/sessions/others`
- `POST /api/v2/auth/tokens`
- `PATCH /api/v2/auth/tokens/current`
- `DELETE /api/v2/auth/tokens/current`
- `POST /api/v2/auth/two-factor/challenges`
- `POST /api/v2/auth/two-factor/challenges/{id}`

### 3.2 Users

- `GET /api/v2/users`
- `GET /api/v2/users/recommendations`
- `GET /api/v2/users/{id}`
- `GET /api/v2/users/{id}/analytics`
- `GET /api/v2/users/{id}/analytics/daily`
- `GET /api/v2/users/{id}/followers`
- `POST /api/v2/users/{id}/followers`
- `DELETE /api/v2/users/{id}/followers`
- `GET /api/v2/users/{id}/following`
- `GET /api/v2/users/{id}/mutual-following`
- `GET /api/v2/users/{id}/posts`
- `GET /api/v2/users/me`
- `PATCH /api/v2/users/me`
- `DELETE /api/v2/users/me`
- `PUT /api/v2/users/me/avatar`
- `PATCH /api/v2/users/me/email`
- `GET /api/v2/users/me/settings`
- `PATCH /api/v2/users/me/settings`
- `GET /api/v2/users/me/posts`
- `GET /api/v2/users/me/likes`
- `GET /api/v2/users/me/bookmarks`
- `GET /api/v2/users/me/groups`
- `GET /api/v2/users/me/group-invites`
- `GET /api/v2/users/me/blocks`
- `POST /api/v2/users/me/blocks/{target_id}`
- `DELETE /api/v2/users/me/blocks/{target_id}`
- `GET /api/v2/users/me/mutes`
- `POST /api/v2/users/me/mutes/{target_id}`
- `DELETE /api/v2/users/me/mutes/{target_id}`
- `GET /api/v2/users/me/account-statements`
- `PATCH /api/v2/users/me/account-statements/{id}`
- `POST /api/v2/users/me/account-statements/{id}/appeals`
- `POST /api/v2/users/me/two-factor/setup`
- `POST /api/v2/users/me/two-factor/confirm`
- `DELETE /api/v2/users/me/two-factor`

### 3.3 Posts, Comments, Tags

- `GET /api/v2/posts`
- `POST /api/v2/posts`
- `GET /api/v2/posts/trending`
- `GET /api/v2/posts/{id}`
- `PUT /api/v2/posts/{id}`
- `DELETE /api/v2/posts/{id}`
- `GET /api/v2/posts/{id}/analytics`
- `POST /api/v2/posts/{id}/likes`
- `GET /api/v2/posts/{id}/likes`
- `DELETE /api/v2/posts/{id}/likes`
- `POST /api/v2/posts/{id}/bookmarks`
- `DELETE /api/v2/posts/{id}/bookmarks`
- `GET /api/v2/posts/{id}/comments`
- `POST /api/v2/posts/{id}/comments`
- `GET /api/v2/posts/{id}/replies`
- `GET /api/v2/posts/{id}/retweets`
- `POST /api/v2/posts/{id}/retweets`
- `DELETE /api/v2/comments/{id}`
- `POST /api/v2/comments/{id}/likes`
- `DELETE /api/v2/comments/{id}/likes`
- `GET /api/v2/tags`
- `GET /api/v2/tags/trending`
- `GET /api/v2/tags/{name}/posts`
- `GET /api/v2/tags/{name}/analytics`
- `POST /api/v2/recommendations/feedback`
- `POST /api/v2/reports`

### 3.4 Media and Storage

- `POST /api/v2/media`
- `DELETE /api/v2/media/{id}`
- `PUT /api/v2/users/me/avatar`
- `GET /storage/**`
- `GET /uploads/**`

### 3.5 Groups

- `GET /api/v2/groups`
- `POST /api/v2/groups`
- `GET /api/v2/groups/popular`
- `GET /api/v2/groups/{id}`
- `PATCH /api/v2/groups/{id}`
- `DELETE /api/v2/groups/{id}`
- `GET /api/v2/groups/by-slug/{slug}`
- `GET /api/v2/groups/{id}/notification-preference`
- `PUT /api/v2/groups/{id}/notification-preference`
- `GET /api/v2/groups/{id}/members`
- `POST /api/v2/groups/{id}/members/current`
- `DELETE /api/v2/groups/{id}/members/current`
- `PUT /api/v2/groups/{id}/members/{user_id}/approval-status`
- `DELETE /api/v2/groups/{id}/members/{user_id}`
- `PATCH /api/v2/groups/{id}/members/{user_id}/role`
- `PATCH /api/v2/groups/{id}/members/{user_id}/roles`
- `PUT /api/v2/groups/{id}/members/{user_id}/mute-status`
- `DELETE /api/v2/groups/{id}/members/{user_id}/mute-status`
- `PUT /api/v2/groups/{id}/ownership`
- `GET /api/v2/groups/{id}/posts`
- `POST /api/v2/groups/{id}/posts`
- `GET /api/v2/groups/{id}/posts/{post_id}`
- `DELETE /api/v2/groups/{id}/posts/{post_id}`
- `PUT /api/v2/groups/{id}/posts/{post_id}/pin-status`
- `POST /api/v2/groups/{id}/posts/{post_id}/likes`
- `DELETE /api/v2/groups/{id}/posts/{post_id}/likes`
- `GET /api/v2/groups/{id}/posts/{post_id}/comments`
- `POST /api/v2/groups/{id}/posts/{post_id}/comments`
- `DELETE /api/v2/groups/{id}/posts/{post_id}/comments/{comment_id}`
- `POST /api/v2/groups/{id}/posts/{post_id}/comments/{comment_id}/likes`
- `DELETE /api/v2/groups/{id}/posts/{post_id}/comments/{comment_id}/likes`
- `POST /api/v2/groups/{id}/invites`
- `GET /api/v2/groups/{id}/invites`
- `GET /api/v2/groups/invite-codes/{code}`
- `POST /api/v2/groups/invites/{invite_id}/responses`
- `GET /api/v2/groups/{id}/audit-logs`

### 3.6 Chat

- `GET /api/v2/chat/groups`
- `GET /api/v2/chat/groups/{id}/channels`
- `POST /api/v2/chat/groups/{id}/channels`
- `GET /api/v2/chat/groups/{id}/members`
- `PATCH /api/v2/chat/channels/{channel_id}`
- `DELETE /api/v2/chat/channels/{channel_id}`
- `GET /api/v2/chat/channels/{channel_id}/messages`
- `POST /api/v2/chat/channels/{channel_id}/messages`
- `PUT /api/v2/chat/channels/{channel_id}/read-status`
- `PUT /api/v2/chat/channels/{channel_id}/mute-status`
- `PATCH /api/v2/chat/messages/{message_id}`
- `DELETE /api/v2/chat/messages/{message_id}`
- `PUT /api/v2/chat/messages/{message_id}/pin-status`
- `POST /api/v2/chat/messages/{message_id}/reactions`
- `DELETE /api/v2/chat/messages/{message_id}/reactions`
- `GET /api/v2/chat/direct-conversations`
- `POST /api/v2/chat/direct-conversations`
- `GET /api/v2/chat/direct-conversations/{conversation_id}/messages`
- `POST /api/v2/chat/direct-conversations/{conversation_id}/messages`
- `GET /_ws`

### 3.7 Notifications

- `GET /api/v2/notifications`
- `PUT /api/v2/notifications/read-status`
- `PUT /api/v2/notifications/{id}/read-status`
- `DELETE /api/v2/notifications/{id}`
- `PUT /api/v2/notifications/{id}/restore-status`

### 3.8 Moderation

- `GET /api/v2/moderation/content`
- `POST /api/v2/moderation/content/{post_id}/actions`
- `POST /api/v2/moderation/content/bulk-actions`
- `GET /api/v2/moderation/stats`
- `GET /api/v2/moderation/reports`
- `PATCH /api/v2/moderation/reports/{report_id}`
- `GET /api/v2/moderation/users`
- `POST /api/v2/moderation/users/{user_id}/actions`
- `GET /api/v2/moderation/settings`
- `PATCH /api/v2/moderation/settings`
- `GET /api/v2/moderation/appeals`
- `PATCH /api/v2/moderation/appeals/{appeal_id}`

### 3.9 Integrations and Fallback

- `GET /api/health`
- `GET /api/v2/integrations/sentiment-flow/config`
- `ANY /api/v2/integrations/sentiment-flow/**`
- `ANY /api/v2/**` fallback 40404
- `ANY /api/v1/**` optional 410 or legacy compatibility

## 4. 数据库迁移细节

### 4.1 Baseline 管理

Rust 第一版不负责重新设计 schema。以 `doc/neko_tribe-oracle-v2.sql` 为唯一 baseline。

迁移时建议：

- 不使用 ORM 自动迁移。
- 不使用 SeaORM/Diesel 自动建表覆盖 Oracle schema。
- 如果使用迁移工具，只记录 baseline 已存在，不自动创建或修改表。
- 将当前请求时 DDL 固化为明确迁移脚本：
  - `n_media_assets.description`
  - `n_user_settings` 的 AI 情感分析字段
  - `n_groups.category`
  - `n_group_tags`
  - `n_group_notification_preferences`
  - 2FA 相关表和序列
- 如果 baseline 已包含这些对象，Rust 启动只做轻量 schema check，不在普通请求里执行 DDL。

### 4.2 SQL 平移规则

- SQL 参数保持 Oracle bind 语义，例如 `:user_id`。
- Rust 中封装 `NamedBind` 或 `BindMap`，业务层不要到处手写驱动绑定转换。
- 当前 TS 代码中 `v2Rows` 默认 outFormat object；Rust 也要返回列名到值的映射。
- CLOB 字段优先在 SQL 中 `DBMS_LOB.SUBSTR`，避免 Rust JSON 序列化 Lob。
- NUMBER(1) 转 bool 时按 `0=false`、非 0=true。
- NULL 字段使用 `Option<T>` 或自定义 nullable helper，不要把 NULL 误转为空字符串，除非现有 DTO 就要求空字符串。
- `created_at`、`updated_at` 返回 ISO 字符串；不要返回 Rust debug 格式或数据库本地格式。
- 多步写入必须事务化，失败后 rollback。
- 文件写入 + DB 写入要有补偿清理。
- 查询缓存必须在 DB helper 层拦截，不要分散在每个 repository。

### 4.3 主要数据库对象索引

Auth：

- `n_users`
- `n_auth_otp_events`
- `n_auth_sessions`
- `n_user_two_factor_secrets`
- `n_user_two_factor_recovery_codes`
- `n_user_two_factor_trusted_devices`
- `n_auth_two_factor_challenges`
- `seq_user_id`
- `seq_otp_event_id`
- `seq_2fa_recovery_code_id`
- `seq_2fa_trusted_device_id`

Users：

- `v_user_profile_public`
- `v_user_profile_self`
- `v_user_analytics`
- `n_user_settings`
- `n_user_follows`
- `n_user_blocks`
- `n_user_mutes`
- `n_user_stats`
- `n_account_statements`
- `n_statement_appeals`
- `fn_get_user_relationship`

Posts：

- `n_posts`
- `n_post_stats`
- `n_post_likes`
- `n_post_bookmarks`
- `n_comments`
- `n_comment_stats`
- `n_comment_likes`
- `n_tags`
- `n_post_tags`
- `n_post_mentions`
- `n_post_media`
- `v_post_feed_item`
- `v_post_comment_list_item`
- `v_post_analytics`
- `v_tag_analytics`
- `fn_can_view_post`
- `seq_post_id`
- `seq_comment_id`
- `seq_tag_id`

Groups：

- `n_groups`
- `n_group_members`
- `n_group_tags`
- `n_group_notification_preferences`
- `n_group_posts`
- `n_group_comments`
- `n_group_invites`
- `n_group_audit_logs`
- `n_group_post_likes`
- `n_group_comment_likes`
- `v_group_details`
- `v_group_member_details`
- `v_group_post_details`
- `v_group_comment_details`
- `v_group_invite_details`
- `v_group_audit_log_details`
- `v_popular_groups`
- `v_user_groups`
- `fn_can_view_group`
- `fn_has_group_permission`
- `fn_can_post_in_group`

Chat：

- `n_chat_channels`
- `n_chat_messages`
- `n_chat_message_media`
- `n_chat_message_reactions`
- `n_chat_channel_reads`
- `n_chat_channel_mutes`
- `n_direct_conversations`
- `n_direct_messages`
- `n_direct_conversation_reads`
- `seq_chat_channel_id`
- `seq_chat_message_id`
- `seq_chat_message_media_id`
- `seq_direct_conversation_id`
- `seq_direct_message_id`

Notifications：

- `n_notifications`
- `n_notification_preferences`
- `seq_notification_id`

Moderation：

- `n_moderation_reports`
- `n_moderation_cases`
- `n_moderation_actions`
- `n_moderation_user_restrictions`
- `n_moderation_settings`
- `seq_moderation_report_id`
- `seq_moderation_case_id`
- `seq_moderation_action_id`
- `seq_moderation_restriction_id`

Media：

- `n_media_assets`
- `n_post_media`
- `seq_media_id`

## 5. 缓存迁移要求

### 5.1 Redis 当前职责

Rust 迁移不能把 Redis 简化成“只做缓存”。当前 Redis 至少有这些职责：

- IP 限流：`rate_limit:{ip}`
- WebSocket 跨实例广播：
  - `ws:broadcast`
  - `ws:user:{userId}`
  - `ws:room:{roomId}`
  - `ws:chat:channel:{channelId}`
  - `ws:presence`
  - `ws:system`
- v2 GET 响应缓存：`nt:api-cache`
- Oracle SELECT 透明缓存：`nt:oracle-query-cache`
- tag version 失效机制

v2 OTP 不走 Redis，走 Oracle `n_auth_otp_events`。不要把 v2 OTP 误迁成 Redis-only。

### 5.2 API 响应缓存

缓存 key 必须考虑：

- method
- path
- query
- authenticated user id
- tag versions

缓存策略建议：

| 路径 | TTL |
|---|---:|
| auth sessions | 20s |
| chat / notifications | 20s |
| moderation | 45s |
| trending | 300s |
| post/group/user detail | 120s |
| 常规列表 | 60s |

非 GET 成功后必须增加相关 tag version：

- posts mutation：`posts`、`users`、`tags`、`media`
- comments mutation：`posts`、`comments`、`users`
- groups mutation：`groups`、`users`
- chat mutation：`chat`、`groups`
- notifications mutation：`notifications`
- moderation mutation：`moderation`、`posts`、`users`、`groups`
- settings/profile mutation：`users`

### 5.3 Oracle 查询缓存

安全缓存判断：

- 允许：以 `SELECT` 或 `WITH` 开头。
- 拒绝：包含 mutation 关键字、`NEXTVAL`、`FOR UPDATE`、敏感字段、会话/token/密码/验证码查询。
- Cache value 需要能 JSON serialize/deserialize，不保存 driver-specific object。
- Cache key 要包含 viewer，否则不同用户的 relationship/viewer_state 会串数据。
- Mutation 后通过 tag version 失效，不要逐 key 扫描删除。

## 6. 测试和验收总清单

### 6.1 自动化测试建议

必须优先补这些测试：

- `httpx::pagination`：默认值、最大值、非法值。
- `httpx::errors`：错误码和 HTTP status 映射。
- `auth::jwt`：access/refresh token type 校验、过期校验、jti。
- `auth::cookies`：Secure/SameSite/Path/HttpOnly。
- `auth::otp`：验证码有效期、bcrypt 校验。
- `cache::api_cache`：key 生成、tag version、非 GET invalidation。
- `cache::oracle_query_cache`：安全 SELECT 判断、敏感 SQL 跳过。
- `storage::http`：Range 200/206/416。
- `ws::protocol`：事件 JSON 序列化和反序列化。
- 各模块 repository 的 SQL bind 覆盖：至少用 fake db 或测试 Oracle 环境验证命名 bind 不错位。

### 6.2 手动回归主流程

每个大阶段结束后至少回归：

1. 注册 OTP -> 注册 -> 登录。
2. 刷新 token -> 获取 `/users/me`。
3. 上传头像和媒体。
4. 发帖 -> 评论 -> 点赞 -> 收藏 -> 删除。
5. 创建群组 -> 入群 -> 群组发帖 -> 邀请。
6. 打开两个用户 WebSocket -> 群聊消息 -> 私聊消息 -> presence。
7. 通知列表、已读、删除、恢复。
8. 普通举报 -> 审核账号处理 -> 用户申诉。
9. SentimentFlow config 和 proxy。
10. `/storage/**`、`/uploads/**`、`/api/v2/not-exists`。

### 6.3 前端联调要求

Rust 后端替换 Nitro API 时，前端不应感知 DTO 变化。联调时必须检查：

- 浏览器登录态 Cookie 是否正常写入。
- `useRealtimeSocket` 是否能连到 `/_ws`。
- `useNotificationMailbox` 是否能收到 realtime 事件。
- 首页 feed、用户主页、帖子详情、群组页、聊天页、审核页是否无 JSON 字段缺失。
- 网络面板中响应是否仍为 `code/message/data/meta`。
- 401 后前端是否正常清理登录态，不进入 refresh 死循环。

## 7. AI 执行总提示词模板

把下面模板给执行 AI，并替换 `{阶段号}`：

```text
你正在 C:\Code\NekoTribe 中执行 Rust 后端迁移。请严格阅读 doc/NekoTribe-Rust后端迁移执行文档.md，只执行阶段 {阶段号}，不要提前做后续阶段。

硬性要求：
1. 保持现有前端契约不变：/api/v2/**、/_ws、/storage/**、/api/health、code/message/data/meta、snake_case DTO。
2. 继续使用现有 Oracle schema：doc/neko_tribe-oracle-v2.sql。不要改成其他数据库，不要用 ORM 自动建表。
3. Redis key/channel/cache prefix 必须和现有项目一致。
4. Rust 使用 backend-rust/ 独立目录。不要把 Rust 文件放进 Nuxt server/ 目录。
5. Oracle 同步驱动必须通过统一 async wrapper + spawn_blocking 使用，不允许 Axum handler 直接阻塞。
6. 只改本阶段要求的文件。不要顺手重构其他模块。
7. 完成后运行本阶段验收命令：cargo fmt --all、cargo test --all、cargo clippy --all-targets -- -D warnings，以及文档指定 curl/WebSocket/Compose 验收。
8. 如果因为 Oracle Client、Docker 或外部服务缺失无法运行某项验收，必须记录具体命令和具体错误。

现在开始执行阶段 {阶段号}。
```

## 8. 迁移风险清单

| 风险 | 表现 | 规避方式 |
|---|---|---|
| Oracle Rust 驱动同步阻塞 | 高并发时 Tokio worker 被卡死 | 统一 DB executor，所有 Oracle 操作 `spawn_blocking`，并发由 semaphore 控制 |
| Oracle Client 缺失 | 本地或 Docker 启动失败 | 阶段 2 先验证 Instant Client，Dockerfile 明确安装和环境变量 |
| DTO 字段改名 | 前端大量 undefined | 所有 Rust DTO 使用 snake_case，按 `app/types/v2.ts` 对照 |
| NULL 处理错误 | 空字符串、0、false 误覆盖真实 null | repository 到 mapper 明确 `Option<T>` 语义 |
| CLOB 序列化失败 | notifications metadata 或 JSON 字段 500 | SQL 用 `DBMS_LOB.SUBSTR`，mapper 转 JSON string |
| 缓存串用户 | viewer_state、relationship 泄漏 | cache key 必含 viewer/auth context |
| mutation 后旧数据 | feed、详情、通知 stale | tag version invalidation，不逐 key 删除 |
| WebSocket 多实例不一致 | A 实例消息 B 实例收不到 | Redis Pub/Sub channel 保持一致，并携带 server_id |
| presence 离线抖动 | 用户刷新页面立即 offline | 保留 95 秒 offline grace |
| 2FA secret 不兼容 | 已开启用户无法登录 | 保留加密字段和 TOTP 参数 |
| v2 OTP 迁错到 Redis | 重启/审计行为变化 | v2 OTP 继续落 Oracle `n_auth_otp_events` |
| moderation 权限建模错误 | 普通用户访问审核后台或管理员被拒 | 严格迁移 `MODERATION_ALLOW_ALL`、`MODERATION_ADMIN_ACCOUNTS`、默认 `v2_admin` |
| SentimentFlow proxy SSRF | 代理外部任意 URL | 禁止 absolute URL、`.`、`..`，redirect 不得逃逸 base URL |
| 文件和 DB 不一致 | 上传失败残留物理文件 | 文件写入 + DB 事务失败时补偿清理 |

## 9. 推荐实施顺序

推荐按如下方式执行，便于你控制进度：

1. 先执行阶段 1，得到可启动 Rust 服务和公共响应契约。
2. 再执行阶段 2，解决 Oracle、Redis、缓存、限流。这个阶段是最大技术风险点，不通过不要继续业务模块。
3. 执行阶段 3，先让登录态跑通，因为后面所有模块都依赖 auth context。
4. 执行阶段 4 和阶段 5，先完成用户、settings、媒体和 storage，因为帖子/群组/聊天都依赖这些 mapper。
5. 执行阶段 6 和阶段 7，迁移主要内容域：帖子和群组。
6. 执行阶段 8 和阶段 9，迁移通知、聊天、WebSocket、presence。
7. 执行阶段 10，迁移审核后台和申诉闭环。
8. 执行阶段 11，迁移 SentimentFlow 代理。
9. 最后执行阶段 12，做 Docker/Nginx/前端切换。

不要在阶段 1 就引入全部业务模块，也不要在阶段 2 未通过 Oracle/Redis 验证时继续写大量 service。Rust 迁移最大的坑不是语法，而是 Oracle 阻塞驱动、DTO 兼容、缓存失效和实时事件边界。

## 10. 技术资料链接

这些链接用于执行阶段时核对 Rust 生态接口，不要求在文档中锁死具体 patch 版本：

- Axum 文档：`https://docs.rs/axum/latest/axum/`
- Oracle Rust driver 文档：`https://docs.rs/oracle/latest/oracle/`
- Redis Rust driver 文档：`https://docs.rs/redis/latest/redis/`
- jsonwebtoken 文档：`https://docs.rs/jsonwebtoken/latest/jsonwebtoken/`
