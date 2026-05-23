# NekoTribe Go Backend Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Implement this document task-by-task. Do not skip stages. After each stage, run that stage's verification commands and update the checklist before continuing.

**Goal:** 将当前 Nuxt/Nitro TypeScript 后端迁移为可独立运行的 Go 后端，并保持现有前端、Oracle 数据库、Redis、WebSocket、存储路径和 v2 API 契约不变。

**Architecture:** 第一版 Go 后端只迁移后端运行时，不重建业务数据库，不重写前端契约。Go 服务使用 `net/http` + `chi` 暴露 `/api/v2/**`、`/_ws`、`/storage/**` 和 `/api/health`，使用 Oracle 19c 作为主库，Redis 承担限流、缓存和实时 Pub/Sub。

**Tech Stack:** Go 1.22+、`net/http`、`github.com/go-chi/chi/v5`、`database/sql`、`github.com/godror/godror`、`github.com/redis/go-redis/v9`、`github.com/golang-jwt/jwt/v5`、`golang.org/x/crypto/bcrypt`、WebSocket 库优先 `nhooyr.io/websocket` 或 `github.com/gorilla/websocket`、标准库 `log/slog`。

---

> 适用日期：2026-05-23  
> 适用仓库：`C:\Code\NekoTribe`  
> 输出位置：`doc/NekoTribe-Go后端迁移执行文档.md`  
> 使用方式：把本文档按阶段交给 AI。每次只执行一个阶段，阶段验收通过后再进入下一阶段。不要一次性重写全部后端。

## 0. 迁移总原则

### 0.1 必须保持不变的外部契约

Go 后端第一版必须兼容当前前端，不允许先改前端来迁就后端。

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

- DTO 字段保持 snake_case，例如 `user_id`、`created_at`、`avatar_url`，不要改成 Go 默认的 camelCase 或 PascalCase。
- 认证 Cookie 名称保持 `access_token`、`refresh_token`。
- Cookie 属性保持 `HttpOnly`、`SameSite=Lax`、`Path=/`，`Secure` 由 `COOKIE_SECURE=true` 控制。
- 前端仍可以通过 `Authorization: Bearer <token>` 或 `access_token` Cookie 鉴权；优先读取 Cookie，再读取 Bearer。
- 除非进入 v1 兼容阶段，否则 Go 第一版默认只迁移 v2。当前 v1 API 受 `ENABLE_V1_API` 控制，默认禁用。

### 0.2 必须保留的数据库策略

当前业务规则大量依赖 Oracle 19c 的表、序列、触发器、视图和 PL/SQL 函数。Go 迁移不能把第一版改成 MySQL/PostgreSQL，也不要用 ORM 自动建表覆盖现有 schema。

必须以 `doc/neko_tribe-oracle-v2.sql` 为数据库基线。当前基线统计如下：

- 52 张 `n_` 业务表
- 22 个 `v_` 视图
- 20 个 `fn_` PL/SQL 函数
- 34 个 `seq_` 序列
- 78 个触发器

Go 第一版继续直接使用这些对象。SQL 中的 Oracle 特性必须保留：

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

### 0.3 推荐 Go 技术栈

建议创建独立目录 `backend-go/`，不要把 Go 文件散放到现有 Nuxt `server/` 目录。

推荐组合：

| 能力 | Go 方案 | 迁移理由 |
|---|---|---|
| HTTP 路由 | `github.com/go-chi/chi/v5` | 轻量、标准 `net/http` 风格，适合逐个迁移路由 |
| Oracle | `database/sql` + `github.com/godror/godror` | 直接平移 Oracle SQL，避免 ORM 改写语义 |
| Redis | `github.com/redis/go-redis/v9` | 覆盖普通命令、Pub/Sub、TTL |
| JWT | `github.com/golang-jwt/jwt/v5` | 兼容现有 JWT payload 和 jti |
| 密码 | `golang.org/x/crypto/bcrypt` | 对齐当前 bcrypt hash |
| 邮件 | `github.com/wneessen/go-mail` 或标准 SMTP 包装 | 实现 OTP、登录提醒、账号邮件 |
| WebSocket | `nhooyr.io/websocket` 或 `github.com/gorilla/websocket` | 保持 `/_ws` 协议 |
| 日志 | 标准库 `log/slog` | Go 原生日志结构化能力 |
| 配置 | 自写 env loader 或 `caarlos0/env` | 避免过度框架化 |
| 测试 | `testing`、`httptest`、必要时 `testcontainers-go` | 每阶段可验收 |

Oracle 驱动注意事项：

- `godror` 通常需要 Oracle Instant Client 或可用的 Oracle Client 运行时。
- Windows 本地开发要把 Instant Client 目录加入 `PATH`。
- Docker 镜像要包含 Oracle client 依赖，且 Go Oracle 驱动通常需要 `CGO_ENABLED=1`。
- 如果 AI 选择纯 Go Oracle 驱动，必须先验证全部 SQL 特性、CLOB、TIMESTAMP、事务、连接池行为，再替换 `godror`。第一版不建议冒这个风险。

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

Go 迁移要先做横切能力，再迁移业务模块。否则每个模块都会重复造响应、鉴权、分页、Oracle 执行、Redis 缓存、日志、错误处理。

## 1. Go 后端目标结构

建议生成如下目录：

```text
backend-go/
  go.mod
  go.sum
  cmd/
    server/
      main.go
  internal/
    app/
      app.go
      routes.go
      shutdown.go
    config/
      config.go
      env.go
    httpx/
      response.go
      errors.go
      pagination.go
      request.go
      json.go
      context.go
    middleware/
      request_id.go
      logging.go
      security_headers.go
      recover.go
      rate_limit.go
      auth.go
      cache.go
    db/
      oracle.go
      query.go
      tx.go
      rows.go
      nullable.go
    cache/
      redis.go
      api_cache.go
      oracle_query_cache.go
      tags.go
    auth/
      jwt.go
      cookies.go
      password.go
      otp.go
      two_factor.go
      sessions.go
      mail.go
    storage/
      config.go
      provider.go
      local.go
      s3.go
      http.go
      media.go
    ws/
      hub.go
      session.go
      redis_bridge.go
      handler.go
      protocol.go
    modules/
      shared/
        models.go
        mappers.go
      users/
        handler.go
        service.go
        repository.go
        dto.go
      posts/
        handler.go
        service.go
        repository.go
        dto.go
      groups/
        handler.go
        service.go
        repository.go
        dto.go
      chat/
        handler.go
        service.go
        repository.go
        dto.go
      notifications/
        handler.go
        service.go
        repository.go
        dto.go
      moderation/
        handler.go
        service.go
        repository.go
        dto.go
      media/
        handler.go
        service.go
        repository.go
        dto.go
      integrations/
        sentiment_flow.go
  tests/
    contract/
      health_test.go
      auth_test.go
      posts_test.go
      ws_test.go
  Dockerfile
  README.md
```

### 1.1 文件职责边界

- `cmd/server/main.go`：只负责加载配置、初始化 app、启动 HTTP server、优雅退出。
- `internal/app/routes.go`：集中注册所有 HTTP 路由和 `/_ws`。
- `internal/httpx`：封装 v2 响应体、错误码、分页、JSON 解析、请求上下文。
- `internal/middleware`：迁移当前 Nitro middleware/plugins 的横切逻辑。
- `internal/db`：封装 Oracle 连接池、命名参数、事务、CLOB/TIMESTAMP/NULL 转换。
- `internal/cache`：迁移 `api-cache.ts` 与 `oracle-query-cache.ts`。
- `internal/auth`：JWT、Cookie、密码、OTP、2FA、会话、邮件。
- `internal/storage`：迁移本地/S3 存储、媒体校验、文件读取、Range 请求。
- `internal/ws`：迁移 WebSocket 会话管理、房间、用户推送、Redis 订阅。
- `internal/modules/*`：每个业务模块包含 handler/service/repository/dto，避免一个巨型文件。

### 1.2 Go 公共响应结构

所有 handler 只能通过公共方法输出 v2 响应。不要在业务 handler 手写不同形状的 JSON。

```go
package httpx

type Meta struct {
    Page     *int `json:"page,omitempty"`
    PageSize *int `json:"page_size,omitempty"`
    Total    *int `json:"total,omitempty"`
    HasNext  *bool `json:"has_next,omitempty"`
    Limit    *int `json:"limit,omitempty"`
}

type Response[T any] struct {
    Code    int    `json:"code"`
    Message string `json:"message"`
    Data    T      `json:"data"`
    Meta    *Meta  `json:"meta"`
}
```

错误码必须对齐当前 `server/utils/v2.ts`：

| HTTP | v2 code | 语义 |
|---|---:|---|
| 400 | 40001 | 请求参数错误 |
| 401 | 40101 | 未认证或 token 无效 |
| 403 | 40301 | 权限不足 |
| 404 | 40401 | 业务资源不存在 |
| 404 | 40404 | v2 路由不存在 |
| 409 | 40901 | 资源冲突 |
| 422 | 42201 | 业务规则不允许 |
| 500 | 50001 | 服务端错误 |

### 1.3 Go 配置映射

Go 后端必须读取当前 `.env.example` 中已有变量，避免迁移后前端/Compose 配置整体失效。

| 当前变量 | Go 配置字段 | 默认/说明 |
|---|---|---|
| `APP_PORT` | `HTTPPort` | Docker 对外端口，Go 容器内建议监听 `8080` 或 `3000` |
| `ACCESS_SECRET` | `AccessSecret` | JWT access secret |
| `ACCESS_EXPIRES_IN` | `AccessExpiresSeconds` | 默认 900 |
| `REFRESH_SECRET` | `RefreshSecret` | JWT refresh secret |
| `REFRESH_EXPIRES_IN` | `RefreshExpiresSeconds` | 默认 2592000 |
| `COOKIE_SECURE` | `CookieSecure` | `true` 时 Cookie Secure 与 HSTS |
| `TRUST_PROXY` | `TrustProxy` | 控制是否信任代理 IP 头 |
| `ENABLE_V1_API` | `EnableV1API` | 默认 false |
| `MODERATION_ADMIN_ACCOUNTS` | `ModerationAdminAccounts` | 默认 `v2_admin` |
| `MODERATION_ALLOW_ALL` | `ModerationAllowAll` | 仅本地调试可 true |
| `ORACLE_HOST` | `OracleHost` | 本机开发通常 `localhost` |
| `ORACLE_PORT` | `OraclePort` | 本机开发通常 `5501` |
| `ORACLE_SERVICE_NAME` | `OracleServiceName` | `ORCLPDB1` |
| `ORACLE_USER` | `OracleUser` | `neko_app` |
| `ORACLE_PASSWORD` | `OraclePassword` | 与 SQL baseline 保持一致 |
| `ORACLE_POOL_MIN` | `OraclePoolMin` | 默认 2 |
| `ORACLE_POOL_MAX` | `OraclePoolMax` | 默认 10 |
| `REDIS_URL` | `RedisURL` | 优先级高于 host/port |
| `REDIS_HOST` | `RedisHost` | 默认 localhost |
| `REDIS_PORT` | `RedisPort` | 默认 6379 |
| `REDIS_DB` | `RedisDB` | 默认 0 |
| `REDIS_PASSWORD` | `RedisPassword` | 内置 Redis 密码 |
| `SMTP_HOST` | `SMTPHost` | OTP/登录提醒 |
| `SMTP_PORT` | `SMTPPort` | 当前代码按 465 secure SMTP |
| `SMTP_USER` | `SMTPUser` | 发件人 |
| `SMTP_PASS` | `SMTPPass` | 授权码 |
| `STORAGE_TYPE` | `StorageType` | `local` 或 `s3` |
| `STORAGE_PATH` / `STORAGE_ROOT_DIR` | `StoragePath` | 本地文件根目录 |
| `STORAGE_PUBLIC_BASE` | `StoragePublicBase` | 默认 `/storage` |
| `STORAGE_CDN_BASE_URL` | `StorageCDNBaseURL` | 可空 |
| `BASE_URL` | `BaseURL` | 可空 |
| `SENTIMENTFLOW_ENABLED` | `SentimentFlowEnabled` | 代理开关 |
| `SENTIMENTFLOW_BASE_URL` | `SentimentFlowBaseURL` | 外部服务地址 |
| `SENTIMENTFLOW_TIMEOUT_MS` | `SentimentFlowTimeoutMS` | 默认 10000 |
| `NLS_LANG` | `NLSLang` | Oracle 字符集 |

Docker 模式要额外支持 `DOCKER_ORACLE_HOST`、`DOCKER_ORACLE_PORT`、`DOCKER_REDIS_URL`、`DOCKER_REDIS_HOST`、`DOCKER_REDIS_PORT`、`DOCKER_STORAGE_PATH`，用于 Compose 内部服务名。

## 2. 分阶段迁移计划

每个阶段都必须做到：

- 新增或修改的 Go 文件经过 `gofmt ./...`。
- 运行 `go test ./...`。
- 运行本阶段指定的 curl 或 WebSocket 验收。
- 阶段完成后不要顺手重构其他阶段。
- 每个阶段可以单独提交一次，提交信息建议 `feat(go-backend): stage N ...`。

### 阶段 1：创建 Go 后端骨架和公共契约

**目标**

创建可启动的 Go 服务，实现 `/api/health`、v2 响应结构、统一错误、分页、路由兜底、安全响应头和请求日志。

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

**要创建的 Go 文件**

- `backend-go/go.mod`
- `backend-go/cmd/server/main.go`
- `backend-go/internal/config/config.go`
- `backend-go/internal/app/app.go`
- `backend-go/internal/app/routes.go`
- `backend-go/internal/httpx/response.go`
- `backend-go/internal/httpx/errors.go`
- `backend-go/internal/httpx/pagination.go`
- `backend-go/internal/httpx/request.go`
- `backend-go/internal/middleware/request_id.go`
- `backend-go/internal/middleware/logging.go`
- `backend-go/internal/middleware/security_headers.go`
- `backend-go/internal/middleware/recover.go`

**实现要求**

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

- `WriteOK(w, data, message, meta)` 默认 message 为 `success`。
- `WriteNull(w, message)` 返回 `data:null`、`meta:null`。
- `APIError` 包含 `HTTPStatus`、`Code`、`Message`。
- `RecoverMiddleware` 捕获 panic，输出 `50001`，生产环境不把 stack 放入响应。
- `PageFromRequest` 读取 `page`、`page_size`，默认 `1/20`，最大 `page_size=100`，生成 `start_row` 和 `end_row`，对齐当前 `v2Page`。
- 请求日志必须脱敏这些 query/header：`access_token`、`refresh_token`、`token`、`password`、`new_password`、`confirm_password`、`authorization`、`cookie`、`secret`、`client_secret`、`code`。
- 响应头保持：
  - `X-Content-Type-Options: nosniff`
  - `X-Frame-Options: DENY`
  - `Referrer-Policy: same-origin`
  - `Permissions-Policy: camera=(), microphone=(), geolocation=()`
  - `COOKIE_SECURE=true` 时增加 HSTS。

**验收**

```powershell
cd backend-go
go test ./...
go run ./cmd/server
```

新开终端：

```powershell
curl.exe http://127.0.0.1:8080/api/health
curl.exe -i http://127.0.0.1:8080/api/v2/not-exists
```

必须看到 `/api/health` 为 `status=ok`，未匹配 v2 路由为 HTTP 404 且 `code=40404`。

**给 AI 的阶段提示词**

```text
请只执行《NekoTribe-Go后端迁移执行文档》的阶段 1。创建 backend-go Go 项目骨架，实现 /api/health、v2 响应结构、统一错误、分页、请求日志、安全响应头和 /api/v2/** 兜底 40404。不要迁移业务接口，不要连接 Oracle/Redis。完成后运行 gofmt、go test ./...，并用 curl 验证 /api/health 与 /api/v2/not-exists。
```

### 阶段 2：基础设施层 Oracle、Redis、限流和缓存框架

**目标**

让 Go 后端能连接 Oracle 和 Redis，完成连接池、DB helper、事务、IP 限流、API 响应缓存和 Oracle 查询缓存的框架。

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

**要创建的 Go 文件**

- `backend-go/internal/db/oracle.go`
- `backend-go/internal/db/query.go`
- `backend-go/internal/db/tx.go`
- `backend-go/internal/db/rows.go`
- `backend-go/internal/db/nullable.go`
- `backend-go/internal/cache/redis.go`
- `backend-go/internal/cache/tags.go`
- `backend-go/internal/cache/api_cache.go`
- `backend-go/internal/cache/oracle_query_cache.go`
- `backend-go/internal/middleware/rate_limit.go`
- `backend-go/internal/middleware/cache.go`

**Oracle 实现要求**

- DSN 由 `ORACLE_HOST`、`ORACLE_PORT`、`ORACLE_SERVICE_NAME`、`ORACLE_USER`、`ORACLE_PASSWORD` 拼出。
- Docker 模式优先读取 `DOCKER_ORACLE_HOST`、`DOCKER_ORACLE_PORT`。
- poolMin/poolMax 对齐 `.env.example`：默认 2/10。
- `QueryRows(ctx, sql, args)` 返回 `[]map[string]any`，列名统一大写，便于平移当前 mapper。
- `QueryOne(ctx, sql, args)` 无数据返回 `nil`。
- `Exec(ctx, sql, args)` 返回 affected rows。
- `NextID(ctx, "seq_post_id")` 执行 `SELECT seq_post_id.NEXTVAL AS id FROM dual`。
- `Count(ctx, sql, args)` 读取 `TOTAL`。
- CLOB 必须转字符串。当前 TS 代码多处使用 `DBMS_LOB.SUBSTR(..., 4000, 1)`，Go 平移时优先保留 SQL 侧转换。
- TIMESTAMP 返回给 DTO 时统一格式化为 ISO 字符串。
- 业务层多步写入必须用事务，例如媒体上传、发帖、群组发帖、聊天消息。

**Redis 实现要求**

- 支持 `REDIS_URL` 优先，其次 `REDIS_HOST`、`REDIS_PORT`、`REDIS_DB`、`REDIS_PASSWORD`。
- Redis 连接失败时，限流、缓存、Pub/Sub 要能降级，不能让普通请求直接崩溃。
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
- 通过 path、query、auth user、tag version 生成稳定 key。
- 非 GET 成功后按路径标签递增版本，避免写后读到旧数据。
- OTP、2FA challenge、token refresh 等敏感接口不缓存。

Oracle 查询缓存对应 `server/utils/oracle-query-cache.ts`：

- prefix：`nt:oracle-query-cache`。
- 只缓存安全 `SELECT` / `WITH` 查询。
- 跳过含有 `NEXTVAL`、`FOR UPDATE`、`password_hash`、`access_token`、`refresh_token`、`access_jti`、`verification_code`、`sessions` 的 SQL。
- cache id 包含 normalized SQL、binds、options、viewer、tag versions。
- 命中热 key 时延长 TTL。
- mutation SQL 成功后按涉及表/域名递增 tag version。
- `n_auth_sessions.last_accessed_at` 这类会话心跳更新不要导致全局缓存大面积失效。

**验收**

```powershell
cd backend-go
go test ./...
go run ./cmd/server
curl.exe http://127.0.0.1:8080/api/health
```

再增加一个内部测试：执行 `SELECT 1 AS total FROM dual`，确认 Oracle 可连；执行 Redis `PING`，确认 Redis 可连。Redis 不可用时测试也要覆盖降级分支。

**给 AI 的阶段提示词**

```text
请只执行阶段 2。基于当前 server/utils/oracle.ts、redis.ts、api-cache.ts、oracle-query-cache.ts、rate-limit.ts，在 backend-go 中实现 Oracle/Redis 基础设施、DB helper、事务、限流、缓存框架。不要迁移业务模块。保留 Redis key/channel 前缀和 Oracle SQL 规则。完成后运行 gofmt、go test ./...，并验证 Oracle SELECT 1、Redis PING、/api/health。
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
- secret 存库前加密，迁移 Go 时必须保留加密字段：`secret_encrypted`、`secret_iv`、`secret_auth_tag`。
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
请只执行阶段 3。迁移 v2 auth：JWT、Cookie、OTP、注册、登录、refresh、logout、sessions、2FA setup/confirm/disable、2FA challenge。严格参考 server/middleware/auth.ts 和 server/services/v2/auth.ts。保持响应 code/message/data/meta、Cookie 名称和 Oracle 表结构。完成后运行 gofmt、go test ./...，并用 curl 验证登录、refresh、logout、sessions。
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
请只执行阶段 4。迁移公共 v2 DTO mapper、用户资料、账号设置、关注/拉黑/静音、账号处置、用户统计和推荐用户。严格参考 server/models/v2.ts 与 server/services/v2/users.ts。保持 snake_case DTO、Oracle 视图/函数、settings AI 字段和 presence 更新。完成后运行 gofmt、go test ./...，并验证 /users/me、settings、follow、block。
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
请只执行阶段 5。迁移 storage、media upload/delete、avatar upload、/storage/** 文件读取和 /uploads/** 410。参考 server/storage 与 server/services/v2/media.ts。保留 MIME、大小、Range、默认头像、事务失败清理规则。完成后运行 gofmt、go test ./...，并用 multipart curl 验证上传、读取、删除。
```

### 阶段 6：帖子、评论、标签、推荐反馈和举报入口

**目标**

迁移帖子 feed、发帖、改帖、删帖、点赞、收藏、评论、回复、转发、标签搜索、趋势、统计、推荐反馈和普通用户举报入口。

**输入文件**

- `server/services/v2/posts.ts`
- `server/models/v2.ts`
- `server/services/v2/notifications.ts`
- `doc/neko_tribe-oracle-v2.sql`

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

- `Post` 结构必须包含 author、media、tags、mentions、stats、viewer_state。
- feed 查询继续使用 `v_post_feed_item` 和 `fn_can_view_post(:viewer_id, v.post_id)=1`。
- 内容字段用 `DBMS_LOB.SUBSTR(content, 4000, 1)` 转字符串。
- `visibility` 只允许 `public`、`followers`、`mentioned`、`private`。
- 发帖类型由引用字段决定：
  - 无引用：`post`
  - `reply_to_post_id`：`reply`
  - `repost_of_post_id`：`repost`
  - `quoted_post_id`：`quote`
- 三个引用字段最多只能传一个。
- 非 repost 时，content 和 media_ids 至少有一个。
- media_ids 去重并限制数量，按当前 TS 逻辑执行。
- tag 写入使用 `MERGE INTO n_tags` 或 `INSERT ... WHERE NOT EXISTS`，保持 lower name 唯一。
- mention 写入 `n_post_mentions`，发通知。
- 点赞、评论、回复、提及、转发要创建通知，但不能给自己重复发无意义通知。
- 删除帖子是软删除：`n_posts.is_deleted=1`。
- 删除评论也是软删除或按当前 SQL 逻辑处理，不要物理误删关联统计。
- 推荐反馈接口返回 `{ "accepted": true }`。

**缓存要求**

- 发帖、改帖、删帖、点赞、收藏、评论、标签变动后必须让 `posts`、`users`、`tags`、`media`、`notifications` 相关缓存失效。
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
请只执行阶段 6。迁移 posts/comments/tags/recommendations/reports 模块。严格参考 server/services/v2/posts.ts 与 server/models/v2.ts，保留 Oracle SQL、视图、函数、通知副作用和缓存失效。完成后运行 gofmt、go test ./...，并验证发帖、改帖、删帖、点赞、评论、标签。
```

### 阶段 7：群组模块

**目标**

迁移群组、成员、通知偏好、群组帖子、群组评论、邀请、所有权转移和审计日志。

**输入文件**

- `server/services/v2/groups.ts`
- `server/models/v2.ts`
- `server/services/v2/notifications.ts`
- `doc/neko_tribe-oracle-v2.sql`

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
- `v2EnsureGroupFeatureSchema` 当前会请求时补列/补表；Go 迁移时应把这些 DDL 固化到 baseline 或启动前 schema check，不建议在普通请求里执行 DDL。

**验收**

- 创建群组后自己是 owner。
- public group 可加入，private/approval group 按状态返回。
- 创建群组帖子后成员收到通知。
- moderator/admin 权限能 pin/delete，普通 member 不能。
- 邀请码创建、校验、接受/拒绝流程可用。
- 审计日志能看到管理操作。

**给 AI 的阶段提示词**

```text
请只执行阶段 7。迁移 groups 模块，包括群组 CRUD、成员、权限、群组帖子/评论/点赞、邀请、通知偏好、所有权转移、审计日志。参考 server/services/v2/groups.ts。保留 Oracle 函数权限判断、DTO 字段、通知副作用和缓存失效。完成后运行 gofmt、go test ./...，并验证创建群组、入群、发群组帖子、邀请和审计日志。
```

### 阶段 8：通知模块

**目标**

迁移通知存储、列表、读取状态、删除、恢复和实时通知事件发布。

**输入文件**

- `server/services/v2/notifications.ts`
- `server/models/v2.ts`
- `server/utils/redis.ts`

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
请只执行阶段 8。迁移 notifications 模块和通知事件发布。参考 server/services/v2/notifications.ts。保留 n_notifications、metadata_json CLOB 字符串化、用户通知偏好和 Redis user channel 事件。完成后运行 gofmt、go test ./...，并验证列表、已读、批量已读、删除、恢复。
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
请只执行阶段 9。迁移 chat REST、direct message、WebSocket /_ws、ws session manager、Redis Pub/Sub、presence。参考 server/routes/_ws.ts、server/utils/wsSession.ts、server/services/v2/chat.ts、presence.ts。保留认证顺序、Redis channels、事件 JSON、95 秒离线延迟、聊天权限和通知副作用。完成后运行 gofmt、go test ./...，并用两个客户端验证群聊、私聊、presence。
```

### 阶段 10：审核、举报、处罚和申诉模块

**目标**

迁移内容审核队列、举报、审核动作、批量动作、用户处罚、审核设置和申诉处理。

**输入文件**

- `server/services/v2/moderation.ts`
- `server/services/v2/users.ts`
- `server/models/v2.ts`
- `.env.example`

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
请只执行阶段 10。迁移 moderation、reports、account statements、appeals。参考 server/services/v2/moderation.ts 和 users.ts。重点保留 requireModerationAccess 的账号白名单规则、枚举、审核动作副作用、默认设置和账号处置/申诉流程。完成后运行 gofmt、go test ./...，并验证非审核账号 403、审核账号可处理举报。
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
请只执行阶段 11。迁移 SentimentFlow config 和 proxy。参考 server/utils/sentiment-flow.ts 与 server/api/v2/integrations/sentiment-flow。保留 enabled/baseUrl/timeout、path 安全检查、header blocklist、redirect 限制和 502/503/504 错误格式。完成后运行 gofmt、go test ./...，并验证 disabled、enabled、非法 path、timeout。
```

### 阶段 12：v1 兼容层和部署切换

**目标**

明确旧 `/api/v1/**` 策略，完成 Docker/Nginx/前端联调，让 Go 后端可以替换 Nitro 后端。

**输入文件**

- `server/api/v1/**`
- `server/middleware/auth.ts`
- `docker-compose.yml`
- `Dockerfile`
- `nginx/nginx.compose.conf`
- `.env.example`
- `README.md`

**v1 策略**

推荐第一版 Go 后端：

- 默认 `ENABLE_V1_API=false`。
- `ANY /api/v1/**` 返回 HTTP 410。
- 响应可使用 v1 风格或简单 JSON，但要说明 legacy disabled。
- 只有当前端仍有真实 v1 调用时，才逐个迁移 v1。不要主动迁移全部 v1 增加风险。

**部署切换策略**

推荐两阶段切换：

1. 并行运行：
   - Nuxt 前端仍运行现有服务。
   - Go 后端监听 `8080`。
   - Nginx 将 `/api/**`、`/_ws`、`/storage/**` 转发到 Go。
   - 其他页面和前端资源转发到 Nuxt。
2. 完全替换后端：
   - 删除或停用 Nuxt Nitro server API。
   - 前端仅作为静态/SSR 前端。
   - Go 服务成为唯一 API、WS、storage 服务。

**Docker 要求**

- 新增 `backend-go/Dockerfile`。
- Go 镜像要包含 Oracle client 依赖。
- 容器内监听端口建议 `8080`。
- Compose 中增加 `go-backend` 服务。
- Go 后端依赖 `redis` healthy 和 `db-init` completed。
- storage volume 继续挂载同一目录。
- healthcheck 使用 `GET /api/health`。

**Nginx 路由要求**

- `/api/` -> Go backend
- `/_ws` -> Go backend，并支持 WebSocket upgrade
- `/storage/` -> Go backend 或 Nginx 静态目录，必须和当前行为一致
- `/uploads/` -> Go backend 返回 410
- 前端页面 -> Nuxt/frontend

**验收**

- `docker compose config` 通过。
- `docker compose up -d go-backend` 后 healthcheck healthy。
- 前端页面调用 `/api/v2/users/me` 命中 Go。
- 浏览器 WebSocket 连接 `/_ws` 命中 Go。
- 上传文件后 `/storage/**` 可访问。
- `/api/v1/users/me` 默认返回 410。

**给 AI 的阶段提示词**

```text
请只执行阶段 12。添加 Go 后端 Dockerfile、Compose 服务、Nginx 转发和 v1 410 兼容层。不要迁移 v1 业务实现。确保 /api/**、/_ws、/storage/** 进入 Go，前端页面仍可访问。完成后运行 docker compose config，并做 /api/health、/api/v2/users/me、/_ws、/uploads/** 验收。
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

Go 第一版不负责重新设计 schema。以 `doc/neko_tribe-oracle-v2.sql` 为唯一 baseline。

迁移时建议：

- 不用 ORM 自动迁移。
- 不使用 GORM AutoMigrate。
- 如果使用迁移工具，只记录 baseline 已存在，不自动创建或修改表。
- 将当前请求时 DDL 固化为明确迁移脚本：
  - `n_media_assets.description`
  - `n_user_settings` 的 AI 情感分析字段
  - `n_groups.category`
  - `n_group_tags`
  - `n_group_notification_preferences`
  - 2FA 相关表和序列
- 如果 baseline 已包含这些对象，Go 启动只做轻量 schema check，不在普通请求里执行 DDL。

### 4.2 SQL 平移规则

- SQL 参数使用 Oracle named bind，例如 `:user_id`。
- Go 中封装 `sql.Named("user_id", value)`，业务层不要到处手写绑定转换。
- 当前 TS 代码中 `v2Rows` 默认 outFormat object；Go 也要返回列名到值的映射。
- CLOB 字段优先在 SQL 中 `DBMS_LOB.SUBSTR`，避免 Go JSON 序列化 Lob。
- NUMBER(1) 转 bool 时按 `0=false`、非 0=true`。
- NULL 字段使用 `sql.NullString`、`sql.NullInt64` 或自定义 helper，不要把 NULL 误转为空字符串，除非现有 DTO 就要求空字符串。
- `created_at`、`updated_at` 返回 ISO 字符串；不要返回 Go 默认时间格式不一致的字符串。
- 多步写入必须事务化，失败后 rollback。
- 文件写入 + DB 写入要有补偿清理。

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

Go 迁移不能把 Redis 简化成“只做缓存”。当前 Redis 至少有这些职责：

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
- Cache value 需要能 JSON marshal/unmarshal，不保存 driver-specific object。
- Cache key 要包含 viewer，否则不同用户的 relationship/viewer_state 会串数据。
- Mutation 后通过 tag version 失效，不要逐 key 扫描删除。

## 6. 测试和验收总清单

### 6.1 自动化测试建议

至少写这些测试：

- `httpx` 响应和错误码测试。
- pagination 默认值、最大值、非法值测试。
- JWT sign/verify、access/refresh secret 分离测试。
- Cookie 属性测试。
- OTP bcrypt 校验测试。
- 2FA TOTP drift 测试。
- Oracle helper named bind、NULL、TIMESTAMP、CLOB 映射测试。
- Redis cache key/tag version 测试。
- `/api/v2/**` fallback 40404 测试。
- `/uploads/**` 410 测试。
- `/storage/**` Range 解析测试。
- WebSocket message parse 和 room session 测试。
- moderation access 白名单测试。
- SentimentFlow path traversal 防护测试。

### 6.2 手动回归主流程

每次完成阶段 3 以后，建议用真实前端或 curl 跑这些主流程：

1. 注册 OTP -> 校验 OTP -> 注册。
2. 登录 -> 获取 `/users/me` -> refresh -> logout。
3. 修改资料、头像、settings。
4. 发帖 -> 上传媒体 -> 点赞 -> 评论 -> 收藏 -> 删除。
5. 搜索用户、关注、拉黑、静音。
6. 创建群组 -> 加入群组 -> 发群组帖子 -> 评论 -> 邀请。
7. 打开聊天 -> 加入频道 -> 发消息 -> 编辑 -> reaction -> 私聊。
8. 查看通知 -> 单条已读 -> 批量已读 -> 删除 -> 恢复。
9. 创建举报 -> 审核账号处理 -> 用户查看处置记录 -> 申诉。
10. 启用 SentimentFlow 后代理 `/models` 和 `/predict/`。

### 6.3 前端联调要求

前端不应该感知迁移：

- 原始页面不改 API 路径。
- `NUXT_PUBLIC_API_BASE` 留空时同源访问仍可用。
- WebSocket 仍从 `/_ws` 建连。
- HTTPS 页面必须使用 `wss://`，不要把 `ws://0.0.0.0` 暴露给浏览器。
- Cookie 登录态要跨刷新保持。
- 401 时前端现有清理逻辑能工作。
- 文件预览、头像、帖子媒体都能从 `/storage/**` 读取。

## 7. AI 执行总提示词模板

每次给 AI 执行时，使用下面模板，把 `{阶段编号}` 替换成具体阶段。

```text
你现在在 C:\Code\NekoTribe。请阅读 doc/NekoTribe-Go后端迁移执行文档.md，只执行阶段 {阶段编号}，不要提前执行后续阶段。

硬性要求：
1. 保持当前前端 API 契约不变：/api/v2/**、/_ws、/storage/**、/api/health。
2. v2 响应必须是 code/message/data/meta。
3. DTO JSON 字段必须是 snake_case。
4. 继续使用 Oracle 19c baseline doc/neko_tribe-oracle-v2.sql，不要改数据库类型。
5. Redis key/channel/cache 前缀必须按文档保留。
6. 不要重构无关前端。
7. 每个阶段完成后运行 gofmt ./...、go test ./...，再运行阶段验收命令。
8. 如果发现当前代码和文档不一致，以当前代码为准，并把差异补充回文档。

完成后请汇报：
- 修改/新增文件
- 已实现接口
- 验收命令和结果
- 未完成或需要下一阶段处理的事项
```

## 8. 迁移风险清单

- Oracle Client / CGO 依赖：Go 容器如果没装好 Oracle client，所有 DB 连接会失败。
- DTO 字段名：Go struct 默认导出字段是 PascalCase，必须写 `json:"snake_case"`。
- CLOB 序列化：不要把 Oracle Lob 对象直接返回 JSON。
- JWT payload：`jti`、`sessionId`、`type` 漏掉会导致 WebSocket 和 refresh 失败。
- Cookie Secure：本地 HTTP 开发如果误设 `COOKIE_SECURE=true`，浏览器不会保存 Cookie。
- Redis 降级：Redis 失败不能让普通读写全部失败，但 WebSocket 跨实例会退化。
- 缓存失效：写入后如果只清详情，不清 feed/tag/user，会出现旧数据。
- WebSocket 多实例：必须通过 Redis Pub/Sub 同步事件，不能只发本机内存 session。
- Presence 离线：最后连接关闭要延迟 95 秒，避免刷新页面造成频繁上下线。
- Moderation 权限：不能误用群组 admin 作为审核后台权限。
- SentimentFlow 代理：必须阻止 path traversal、绝对 URL、跨 base redirect。
- 请求时 DDL：当前 TS 里有一些 ensure schema，Go 第一版要明确处理，不要在高并发请求中反复 DDL。

## 9. 推荐实施顺序

严格按顺序：

1. 阶段 1：Go 骨架和公共契约。
2. 阶段 2：Oracle/Redis/缓存/限流。
3. 阶段 3：认证和安全。
4. 阶段 4：用户和账号。
5. 阶段 5：存储和媒体。
6. 阶段 6：帖子评论标签。
7. 阶段 7：群组。
8. 阶段 8：通知。
9. 阶段 9：聊天和 WebSocket。
10. 阶段 10：审核。
11. 阶段 11：SentimentFlow。
12. 阶段 12：v1 策略和部署切换。

阶段 1 到 3 是基础，不通过不要继续。阶段 4 到 11 可以在基础稳定后由多个 AI 分支并行迁移，但合并时必须统一 DTO、缓存、事务和错误处理。阶段 12 只能在主要业务接口验收通过后执行。
