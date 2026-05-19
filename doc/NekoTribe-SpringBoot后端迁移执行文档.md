# NekoTribe 后端迁移到 Spring Boot 执行文档

> 适用日期：2026-05-19  
> 适用仓库：`C:\Code\NekoTribe`  
> 目标：把当前 Nuxt/Nitro TypeScript 后端迁移为可独立运行的 Spring Boot 后端，并保持前端 API 契约基本不变。  
> 使用方式：把本文档按阶段交给 AI，每次只执行一个阶段。每个阶段完成后运行该阶段验收，再进入下一阶段。

## 0. 迁移总原则

### 0.1 必须保持不变的外部契约

新 Spring Boot 后端必须优先兼容当前前端，不允许先改前端来迁就后端。

- v2 API 基础路径保持 `/api/v2/**`。
- WebSocket 路径保持 `/_ws`。
- 健康检查保持 `/api/health`。
- 静态存储访问保持 `/storage/**`，旧 `/uploads/**` 返回 410。
- SentimentFlow 代理路径保持 `/api/v2/integrations/sentiment-flow/**`。
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

- DTO 字段使用 snake_case，例如 `user_id`、`created_at`、`avatar_url`，不要改成 camelCase 返回给前端。
- 认证 Cookie 名称保持 `access_token`、`refresh_token`。
- 除非明确进入 v1 兼容阶段，否则默认只迁移 v2。当前 v1 API 已被 `ENABLE_V1_API` 控制，默认禁用。

### 0.2 必须保留的数据库策略

当前项目的业务规则大量依赖 Oracle 19c 的表、序列、触发器、视图和 PL/SQL 函数。迁移时不要重建数据库模型，也不要先把 Oracle 改成 MySQL/PostgreSQL。

必须以 `doc/neko_tribe-oracle-v2.sql` 为数据库基线。该文件由 Compose 的 `db-init` 服务挂载执行，是当前 v2 开发数据库的主基线。

当前基线大致包含：

- 52 张 `n_` 业务表
- 22 个 `v_` 视图
- 20 个 `fn_` PL/SQL 函数
- 多个 `seq_` 序列
- 多个统计、更新时间、主键填充触发器

Spring Boot 第一版应继续直接使用这些表、视图、函数和序列。不要在第一版用 JPA 自动建表覆盖已有 schema。

### 0.3 推荐技术栈

建议创建一个独立目录，例如 `backend-springboot/`。

推荐：

- Java 21
- Spring Boot 3.x
- Maven 或 Gradle 均可，优先 Maven，便于 AI 分阶段生成
- Spring Web
- Spring Security
- Spring Validation
- Spring JDBC
- Oracle JDBC
- Spring Data Redis
- Spring WebSocket
- Spring Mail
- Spring Actuator
- Jackson
- jjwt 或 Nimbus JOSE JWT
- BCryptPasswordEncoder
- Flyway 或 Liquibase，只做 baseline 管理，不要自动改写已有表

第一版数据访问建议使用 `NamedParameterJdbcTemplate`，不要急着用 JPA。理由是当前 TypeScript 后端中大量 SQL 依赖 Oracle 特性：

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

用 JDBC 平移 SQL 的风险最低。

## 1. 当前后端结构阅读结论

### 1.1 当前后端核心目录

```text
server/
  api/
    health.get.ts
    v1/                         # 旧接口，默认被 ENABLE_V1_API 控制
    v2/                         # 当前主 API，约 150 个路由文件
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

### 1.2 当前后端横切能力

Spring Boot 迁移时必须先做这些公共能力，再迁移业务模块。

| 当前能力 | TypeScript 文件 | Spring Boot 目标 |
|---|---|---|
| v2 统一响应 | `server/utils/v2.ts` | `common.ApiResponse<T>`、`common.Meta` |
| v2 统一异常 | `v2Throw`、`v2BadRequest` 等 | `ApiException`、`GlobalExceptionHandler` |
| 分页 | `v2Page`、`v2PageMeta` | `PageRequestParam`、`PageMetaFactory` |
| Oracle 连接池 | `server/utils/oracle.ts` | HikariCP + Oracle JDBC |
| DB helper | `v2Rows`、`v2One`、`v2Execute` | `JdbcQueryHelper` |
| JWT 鉴权 | `server/middleware/auth.ts` | `OncePerRequestFilter` |
| Cookie token | `v2SetAuthCookies` | `CookieService` |
| Redis 限流 | `server/middleware/rate-limit.ts` | `RateLimitFilter` |
| 请求日志 | `logging.ts`、plugins 03/04 | `RequestLoggingFilter` |
| 安全响应头 | plugin 05 | `SecurityHeadersFilter` |
| API 响应缓存 | `api-cache.ts` | `ApiResponseCacheService` |
| Oracle 查询缓存 | `oracle-query-cache.ts` | 可选 `JdbcTemplate` 包装层 |
| Redis Pub/Sub | `server/utils/redis.ts` | `RedisMessageListenerContainer` + `StringRedisTemplate` |
| WebSocket 会话 | `wsSession.ts`、`routes/_ws.ts` | `TextWebSocketHandler` + `WsSessionRegistry` |
| 文件存储 | `server/storage/*` | `StorageService`、`LocalStorageProvider`、预留 S3 |
| SentimentFlow 代理 | `integrations/sentiment-flow` | `SentimentFlowProxyController` |

## 2. 新 Spring Boot 项目结构

建议 AI 按下面结构创建代码，不要把所有逻辑塞进 Controller。

```text
backend-springboot/
  pom.xml
  src/main/java/com/nekotribe/backend/
    NekoTribeBackendApplication.java
    common/
      ApiResponse.java
      ApiMeta.java
      ApiException.java
      ErrorCode.java
      GlobalExceptionHandler.java
      PageParam.java
      PageMetaFactory.java
      RequestContext.java
    config/
      AppProperties.java
      OracleConfig.java
      RedisConfig.java
      JacksonConfig.java
      SecurityConfig.java
      WebSocketConfig.java
    security/
      AuthPayload.java
      JwtService.java
      AuthFilter.java
      AuthContext.java
      CookieService.java
      PasswordService.java
    infrastructure/
      db/
        JdbcQueryHelper.java
        OraclePagination.java
        OracleSequenceService.java
      cache/
        ApiResponseCacheService.java
        OracleQueryCacheService.java
      redis/
        RedisPublisher.java
        RedisSubscriber.java
      logging/
        RequestLoggingFilter.java
      ratelimit/
        RateLimitFilter.java
      headers/
        SecurityHeadersFilter.java
    storage/
      StorageService.java
      StorageProvider.java
      LocalStorageProvider.java
      S3StorageProvider.java
      StorageController.java
    modules/
      auth/
      users/
      posts/
      media/
      groups/
      chat/
      notifications/
      presence/
      moderation/
      integrations/
    websocket/
      WsMessage.java
      WsSessionRegistry.java
      NekoWebSocketHandler.java
      RedisWsBridge.java
  src/main/resources/
    application.yml
    db/migration/
      V1__oracle_baseline_placeholder.sql
```

包命名建议：

- Controller：只解析路径和请求体，不写 SQL。
- Service：承载业务流程和事务。
- Repository：放 SQL 和数据库映射。
- DTO：输入输出结构，字段使用 snake_case。
- Mapper：把 Oracle 行映射为 DTO。

## 3. 全局配置映射

当前 Nuxt 配置来源在 `nuxt.config.ts` 和 `.env.example`。Spring Boot 的 `application.yml` 至少要覆盖这些字段。

```yaml
server:
  port: ${SERVER_PORT:30001}

spring:
  datasource:
    url: jdbc:oracle:thin:@//${ORACLE_HOST:localhost}:${ORACLE_PORT:5501}/${ORACLE_SERVICE_NAME:ORCLPDB1}
    username: ${ORACLE_USER:neko_app}
    password: ${ORACLE_PASSWORD:NekoApp2026#}
    driver-class-name: oracle.jdbc.OracleDriver
    hikari:
      minimum-idle: ${ORACLE_POOL_MIN:2}
      maximum-pool-size: ${ORACLE_POOL_MAX:10}
  data:
    redis:
      host: ${REDIS_HOST:127.0.0.1}
      port: ${REDIS_PORT:6379}
      database: ${REDIS_DB:0}
      password: ${REDIS_PASSWORD:}
  mail:
    host: ${SMTP_HOST:}
    port: ${SMTP_PORT:465}
    username: ${SMTP_USER:}
    password: ${SMTP_PASS:}

nekotribe:
  auth:
    access-secret: ${ACCESS_SECRET:}
    access-expires-in-seconds: ${ACCESS_EXPIRES_IN:900}
    refresh-secret: ${REFRESH_SECRET:}
    refresh-expires-in-seconds: ${REFRESH_EXPIRES_IN:2592000}
    cookie-secure: ${COOKIE_SECURE:false}
  redis:
    url: ${REDIS_URL:}
  storage:
    type: ${STORAGE_TYPE:local}
    path: ${STORAGE_PATH:./storage}
    public-base: ${STORAGE_PUBLIC_BASE:/storage}
    public-base-url: ${BASE_URL:}
    cdn-base-url: ${STORAGE_CDN_BASE_URL:}
  moderation:
    admin-accounts: ${MODERATION_ADMIN_ACCOUNTS:v2_admin}
    allow-all: ${MODERATION_ALLOW_ALL:false}
  legacy:
    enable-v1-api: ${ENABLE_V1_API:false}
  sentiment-flow:
    enabled: ${SENTIMENTFLOW_ENABLED:false}
    base-url: ${SENTIMENTFLOW_BASE_URL:http://localhost:8846/api}
    timeout-ms: ${SENTIMENTFLOW_TIMEOUT_MS:10000}
```

注意：

- `ACCESS_SECRET` 和 `REFRESH_SECRET` 必须存在。不要在代码里硬编码。
- `ORACLE_PASSWORD` 必须和 `doc/neko_tribe-oracle-v2.sql` 创建的 `neko_app` 密码一致。
- Docker 模式中应用容器应使用 `DOCKER_ORACLE_HOST=oracle19c`、`DOCKER_ORACLE_PORT=1521`；宿主机开发模式使用 `localhost:5501`。

## 4. 分阶段迁移计划

每一阶段都可以单独交给 AI。不要让 AI 一次性生成完整大项目，否则容易漏业务规则。

### 阶段 1：创建 Spring Boot 骨架和公共契约

#### 目标

生成可启动的 Spring Boot 项目，完成统一响应、异常、分页、Jackson snake_case、基础健康检查。

#### 输入文件

- `server/utils/v2.ts`
- `server/api/health.get.ts`
- `server/types/v2.d.ts`
- `app/types/v2.ts`

#### 要生成的类

```text
common/ApiResponse.java
common/ApiMeta.java
common/ApiException.java
common/ErrorCode.java
common/GlobalExceptionHandler.java
common/PageParam.java
common/PageMetaFactory.java
config/JacksonConfig.java
modules/health/HealthController.java
```

#### 实现要求

- `ApiResponse.ok(data)` 默认 `code=200`、`message=success`、`meta=null`。
- 错误响应必须仍包在 v2 结构里：

```json
{
  "code": 40101,
  "message": "请先登录",
  "data": null,
  "meta": null
}
```

- 错误码保持：
  - 40001：请求参数错误
  - 40101：未认证或 token 无效
  - 40301：权限不足
  - 40401：资源不存在
  - 40901：资源冲突
  - 42201：业务规则不允许
  - 50001：服务器内部错误
- `PageParam` 默认 `page=1`、`page_size=20`，上限 `page<=10000`、`page_size<=100`。
- `/api/health` 返回：

```json
{
  "status": "ok",
  "service": "nekotribe",
  "timestamp": "ISO时间"
}
```

#### 验收

- `mvn test` 通过。
- 启动后访问 `/api/health` 返回 200。
- Controller 返回字段是 snake_case，而不是 camelCase。

#### 给 AI 的提示词

```text
根据《NekoTribe 后端迁移到 Spring Boot 执行文档》的阶段 1，在 backend-springboot 中创建 Spring Boot 项目骨架。只做公共响应、异常、分页、Jackson snake_case 和 /api/health，不实现业务模块。必须保持 v2 响应结构和错误码。完成后运行 mvn test。
```

### 阶段 2：基础设施层

#### 目标

完成 Oracle、Redis、请求日志、安全响应头、限流、基础缓存接口。

#### 输入文件

- `server/plugins/01-redisClient.ts`
- `server/plugins/02-oracle.ts`
- `server/plugins/03-log.ts`
- `server/plugins/04-global-hooks.ts`
- `server/plugins/05-security-headers.ts`
- `server/middleware/rate-limit.ts`
- `server/utils/oracle.ts`
- `server/utils/redis-config.ts`
- `server/utils/logging.ts`
- `server/utils/api-cache.ts`
- `server/utils/oracle-query-cache.ts`

#### 要生成的类

```text
config/AppProperties.java
config/OracleConfig.java
config/RedisConfig.java
infrastructure/db/JdbcQueryHelper.java
infrastructure/db/OracleSequenceService.java
infrastructure/logging/RequestLoggingFilter.java
infrastructure/headers/SecurityHeadersFilter.java
infrastructure/ratelimit/RateLimitFilter.java
infrastructure/cache/ApiResponseCacheService.java
infrastructure/cache/OracleQueryCacheService.java
infrastructure/redis/RedisPublisher.java
infrastructure/redis/RedisSubscriber.java
```

#### 实现要求

`JdbcQueryHelper` 必须提供：

- `List<Map<String,Object>> rows(String sql, MapSqlParameterSource params)`
- `Optional<Map<String,Object>> one(...)`
- `int update(...)`
- `long count(...)`
- 类型转换：`number`、`string`、`boolean`、`dateString`、`jsonValue`

`OracleSequenceService` 必须支持：

```java
long nextVal(String sequenceName)
```

注意 sequenceName 只能从白名单里选，不能让外部请求直接拼接。

`RateLimitFilter` 规则保持：

- key：`rate_limit:{ip}`
- 10 秒窗口
- 100 次限制
- Redis 异常时只记录日志，不阻断请求
- 跳过 `/_nuxt`、`/__`、静态资源

`RequestLoggingFilter` 要实现：

- 生成或透传 `x-request-id`
- 记录 method/path/query/ip/userAgent
- query 中 token、password、secret、code 等敏感字段脱敏

`SecurityHeadersFilter` 要设置：

- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `Referrer-Policy: same-origin`
- `Permissions-Policy: camera=(), microphone=(), geolocation=()`
- `COOKIE_SECURE=true` 时加 HSTS

缓存第一版可以先做接口和基本 Redis 操作，业务迁移后再细化。

#### 验收

- 应用能连上 Oracle。
- Redis 未启动时 API 不应直接崩溃。
- 连续请求超过限流阈值返回 429。
- 响应头包含安全头。

#### 给 AI 的提示词

```text
执行阶段 2。实现 Oracle、Redis、日志、安全响应头、限流、JdbcQueryHelper、序列服务和缓存服务骨架。不要实现业务模块。必须兼容当前 Nuxt 后端的环境变量和 Redis 降级行为。完成后提供 /api/health 的运行结果和一个 Oracle SELECT 1 FROM dual 的验证接口或测试。
```

### 阶段 3：认证和安全模块

#### 目标

迁移 v2 认证，包括 OTP、注册、登录、2FA、刷新、登出、会话管理、鉴权过滤器。

#### 输入文件

- `server/middleware/auth.ts`
- `server/services/v2/auth.ts`
- `server/api/v2/auth/**`
- `server/types/v2.d.ts`
- `doc/Token无感刷新实现文档.md`

#### 认证接口清单

| 方法 | 路径 | 当前处理函数 |
|---|---|---|
| POST | `/api/v2/auth/otp` | `v2CreateOtp` |
| POST | `/api/v2/auth/otp/verification` | `v2VerifyOtp` |
| POST | `/api/v2/auth/registration` | `v2Register` |
| POST | `/api/v2/auth/tokens` | `v2Login` |
| PATCH | `/api/v2/auth/tokens/current` | `v2RefreshCurrentToken` |
| DELETE | `/api/v2/auth/tokens/current` | `v2LogoutCurrent` |
| POST | `/api/v2/auth/password-reset` | `v2PasswordReset` |
| POST | `/api/v2/auth/two-factor/challenges` | `v2CompleteTwoFactorLogin` |
| POST | `/api/v2/auth/two-factor/challenges/{id}` | `v2CompleteTwoFactorLogin` |
| GET | `/api/v2/auth/sessions` | `v2ListSessions` |
| DELETE | `/api/v2/auth/sessions/{id}` | `v2RevokeSession` |
| DELETE | `/api/v2/auth/sessions/others` | `v2RevokeOtherSessions` |
| POST | `/api/v2/users/me/two-factor/setup` | `v2StartTwoFactorSetup` |
| POST | `/api/v2/users/me/two-factor/confirm` | `v2ConfirmTwoFactorSetup` |
| DELETE | `/api/v2/users/me/two-factor` | `v2DisableTwoFactor` |

#### 公开路由

这些路由不需要 access token：

- `/api/v2/auth/otp`
- `/api/v2/auth/otp/verification`
- `/api/v2/auth/registration`
- `/api/v2/auth/tokens`
- `/api/v2/auth/tokens/current`
- `/api/v2/auth/two-factor/challenges`
- `/api/v2/auth/two-factor/challenges/{id}`
- `/api/v2/auth/password-reset`

注意：`PATCH /api/v2/auth/tokens/current` 通过 refresh cookie 工作，即使没有 access token 也要能进入 Controller。

#### JWT 规则

Access token：

- secret：`ACCESS_SECRET`
- 默认有效期：900 秒
- payload：

```json
{
  "userId": 1000,
  "userName": "alice",
  "sessionId": "sess_xxx",
  "type": "access"
}
```

- `jti` 必须设置为 `access_jti`

Refresh token：

- secret：`REFRESH_SECRET`
- 默认有效期：30 天
- payload：

```json
{
  "userId": 1000,
  "userName": "alice",
  "sessionId": "sess_xxx",
  "type": "refresh"
}
```

#### Cookie 规则

设置：

- `access_token`
- `refresh_token`
- `HttpOnly=true`
- `SameSite=Lax`
- `Path=/`
- `Secure` 取 `COOKIE_SECURE`
- maxAge 分别取 access/refresh 过期秒数

登出时删除同名 cookie，path 必须为 `/`。

#### 数据库表

认证模块涉及：

- `n_users`
- `n_auth_otp_events`
- `n_auth_sessions`
- `n_user_settings`
- `n_user_two_factor_secrets`
- `n_user_two_factor_recovery_codes`
- `n_user_two_factor_trusted_devices`
- `n_auth_two_factor_challenges`

#### 关键业务规则

- 密码使用 BCrypt，强度与现有代码一致，默认 10。
- OTP 有效期 300 秒，验证码只存 BCrypt hash。
- 注册必须校验 `agree_to_terms=true`。
- 注册前必须校验邮箱注册 OTP 已验证。
- 登录使用 `email OR username` 查找。
- 登录时必须检查 `is_active=1` 且 `status='active'`。
- 登录成功写入 `n_auth_sessions`：
  - `session_id=sess_{uuid}`
  - `access_jti`
  - `refresh_token_hash=sha256(refreshToken)`
  - `device_info` 来自 `x-device-info`，默认 `unknown`
  - `device_fingerprint` 来自 `x-device-fingerprint`，默认 `unknown`
  - `ip_address`
  - `user_agent`
  - `access_token_expires_at`
  - `refresh_token_expires_at`
- access 请求每次通过鉴权后更新 `n_auth_sessions.last_accessed_at`。
- refresh 时必须校验：
  - session 存在
  - user_id 匹配
  - refresh hash 匹配
  - 未 revoked
  - refresh 未过期
- refresh 成功后轮换 access_jti 和 refresh_token_hash。
- 2FA 使用 TOTP：
  - period 30 秒
  - 6 位数字
  - drift 允许前后 1 个窗口
  - secret 使用 AES-GCM 加密存储
  - recovery codes 存 BCrypt hash
  - trusted device 默认 30 天
- 新设备登录时，如果用户开启 login_alerts，要创建 `login_alert` 通知，并在 email notification 开启时发送邮件。

#### 验收

- 注册 OTP、注册、登录、刷新、登出、会话列表都能跑通。
- 登录后浏览器自动拥有 `access_token`、`refresh_token`。
- 使用 access token 访问受保护接口时会更新 `n_auth_sessions.last_accessed_at`。
- access 过期后 refresh 可换新 token。
- refresh 被 revoke 后不能继续换 token。
- 2FA 开启、确认、登录挑战、恢复码、可信设备流程可用。

#### 给 AI 的提示词

```text
执行阶段 3。迁移 v2 认证和安全模块。严格保持 cookie 名称、JWT payload、session 表写入、公开路由、错误码和响应结构。优先用 NamedParameterJdbcTemplate 平移 SQL。不要实现用户资料、帖子、群组等其他模块。完成后给出注册/登录/刷新/登出的 curl 验收命令。
```

### 阶段 4：用户、账号设置、关系模块

#### 目标

迁移用户资料、当前用户、邮箱、头像、设置、账号声明、关注/取关、屏蔽、静音、推荐用户、用户统计。

#### 输入文件

- `server/services/v2/users.ts`
- `server/models/v2.ts`
- `server/api/v2/users/**`
- `server/types/v2.d.ts`
- `server/storage/**`

#### 用户接口清单

| 方法 | 路径 | 当前处理函数 |
|---|---|---|
| GET | `/api/v2/users` | `v2SearchUsers` |
| GET | `/api/v2/users/recommendations` | `v2RecommendedUsers` |
| GET | `/api/v2/users/{id}` | `v2GetUserById` |
| GET | `/api/v2/users/{id}/analytics` | `v2GetUserAnalytics` |
| GET | `/api/v2/users/{id}/analytics/daily` | `v2GetUserDailyAnalytics` |
| GET | `/api/v2/users/{id}/posts` | `v2ListPosts(mode=user)` |
| GET | `/api/v2/users/{id}/followers` | `v2RelationshipList(followers)` |
| POST | `/api/v2/users/{id}/followers` | `v2FollowUser` |
| DELETE | `/api/v2/users/{id}/followers` | `v2UnfollowUser` |
| GET | `/api/v2/users/{id}/following` | `v2RelationshipList(following)` |
| GET | `/api/v2/users/{id}/mutual-following` | `v2RelationshipList(mutual-following)` |
| GET | `/api/v2/users/me` | `v2GetMe` |
| PATCH | `/api/v2/users/me` | `v2PatchMe` |
| DELETE | `/api/v2/users/me` | `v2DeleteMe` |
| PUT | `/api/v2/users/me/avatar` | `v2UpdateAvatar` |
| PATCH | `/api/v2/users/me/email` | `v2ChangeEmail` |
| GET | `/api/v2/users/me/settings` | `v2GetSettings` |
| PATCH | `/api/v2/users/me/settings` | `v2PatchSettings` |
| GET | `/api/v2/users/me/posts` | `v2ListPosts(mode=me)` |
| GET | `/api/v2/users/me/likes` | `v2ListPosts(mode=likes)` |
| GET | `/api/v2/users/me/bookmarks` | `v2ListPosts(mode=bookmarks)` |
| GET | `/api/v2/users/me/groups` | `v2MyGroups` |
| GET | `/api/v2/users/me/group-invites` | `v2MyGroupInvites` |
| GET | `/api/v2/users/me/blocks` | `v2RelationshipList(blocks)` |
| POST | `/api/v2/users/me/blocks/{target_id}` | `v2BlockUser` |
| DELETE | `/api/v2/users/me/blocks/{target_id}` | `v2UnblockUser` |
| GET | `/api/v2/users/me/mutes` | `v2RelationshipList(mutes)` |
| POST | `/api/v2/users/me/mutes/{target_id}` | `v2MuteUser` |
| DELETE | `/api/v2/users/me/mutes/{target_id}` | `v2UnmuteUser` |
| GET | `/api/v2/users/me/account-statements` | `v2ListAccountStatements` |
| PATCH | `/api/v2/users/me/account-statements/{id}` | `v2PatchAccountStatement` |
| POST | `/api/v2/users/me/account-statements/{id}/appeals` | `v2CreateStatementAppeal` |

#### 数据库对象

主要使用：

- `n_users`
- `n_user_stats`
- `n_user_settings`
- `n_user_follows`
- `n_user_blocks`
- `n_user_mutes`
- `n_account_statements`
- `n_statement_appeals`
- `n_media_assets`
- `v_user_profile_public`
- `v_user_profile_self`
- `v_user_analytics`
- `fn_get_user_relationship`

#### DTO 重点

`V2PublicUser`：

- `user_id`
- `username`
- `display_name`
- `avatar_url`
- `bio`
- `location`
- `website`
- `is_verified`
- `followers_count`
- `following_count`
- `posts_count`
- `likes_count`
- `relationship`
- `online_status`
- `last_seen_at`

`V2SelfUser` 额外包含：

- `email`
- `phone`
- `birth_date`
- `email_verified_at`
- `is_active`
- `status`
- `created_at`
- `updated_at`

`V2UserSettings` 必须包含现有 AI 偏好字段：

- `ai_sentiment_enabled`
- `ai_sentiment_model_id`
- `ai_sentiment_return_probabilities`
- `ai_sentiment_include_metadata`
- `ai_sentiment_top_k`

#### 关键业务规则

- `PATCH /users/me` 只更新传入字段。
- `birth_date` 使用 `YYYY-MM-DD`，数据库写入 `TO_DATE`。
- 删除账号是软删除和匿名化：
  - 用户 `is_active=0`
  - 用户状态变更
  - 帖子/评论软删除
  - 会话 revoke
  - cookie 清除
- 修改邮箱必须验证 `change_email` OTP。
- `two_factor_enabled` 不能通过 settings PATCH 修改，只能通过 2FA 流程。
- 修改 `show_online_status` 后要发布 presence update。
- 头像上传必须和存储服务、`n_media_assets`、`n_users.avatar_media_id` 一起事务处理。
- 关注不能关注自己。
- 屏蔽会取消双方关注关系。
- 静音可以带 `expires_at`。

#### 验收

- 当前用户资料能查询和更新。
- 设置读取、更新后字段完整，包括 AI 偏好。
- 修改 `show_online_status` 后 WebSocket 能收到 presence 更新。
- 关注、取关、屏蔽、取消屏蔽、静音、取消静音行为正确。
- 账号声明列表、状态更新、申诉可用。

#### 给 AI 的提示词

```text
执行阶段 4。迁移 users/account/settings/relationship 模块。严格保持 DTO 字段名、分页 meta、账号删除匿名化、邮箱 OTP 校验、头像上传事务、show_online_status 后发布 presence。不要实现 posts/groups/chat/moderation 的业务，只允许调用已经存在或先用接口占位的服务。
```

### 阶段 5：存储和媒体模块

#### 目标

迁移文件存储、头像上传、媒体上传、媒体删除、`/storage/**` 文件读取。

#### 输入文件

- `server/storage/**`
- `server/services/v2/media.ts`
- `server/api/v2/media/**`
- `server/routes/storage/[...segments].get.ts`
- `server/routes/uploads/[...segments].get.ts`

#### 接口清单

| 方法 | 路径 | 当前行为 |
|---|---|---|
| POST | `/api/v2/media` | multipart 上传媒体 |
| DELETE | `/api/v2/media/{id}` | 删除媒体 |
| GET | `/storage/**` | 读取本地存储文件，支持 Range |
| GET | `/uploads/**` | 返回 410 |

#### 存储规则

- 默认本地存储路径：`./storage`
- 默认公开基础路径：`/storage`
- 默认头像 key：`default-avatar.png`
- 头像支持：`image/jpeg`、`image/png`、`image/gif`
- 头像最大：10MB
- 帖子媒体支持：
  - 图片：avif/gif/jpeg/png/webp
  - 音频：mp3/ogg/wav
  - 视频：mp4/ogg/webm
- 媒体最大：500MB
- key 规则：
  - 头像：`avatars/{userId}/{yyyy}/{MM}/{uuid}.{ext}`
  - 帖子媒体：`posts/{images|videos|audio|files}/{userId}/{yyyy}/{MM}/{uuid}.{ext}`
- 必须防止路径穿越。
- 本地读取支持：
  - `Accept-Ranges: bytes`
  - `Cache-Control: public, max-age=31536000, immutable`
  - ETag
  - Last-Modified
  - Range 请求返回 206
- S3 Provider 当前只是预留，第一版可以返回 501，但接口要保留。

#### 媒体上传数据库规则

写入 `n_media_assets`：

- `media_id = seq_media_id.NEXTVAL`
- `owner_user_id`
- `media_type`
- `file_name`
- `storage_key`
- `public_url`
- `file_size`
- `mime_type`
- `width`
- `height`
- `duration`
- `thumbnail_url`
- `alt_text`
- `description`
- `status='ready'`

上传文件成功但 DB 失败时必须清理新文件；DB 成功后删除旧头像失败只记录日志。

#### 验收

- multipart 上传图片成功。
- 上传非法格式返回 400。
- `/storage/{key}` 能访问文件。
- Range 请求返回 206。
- 删除媒体会删除 DB 记录和物理文件。
- `/uploads/xxx` 返回 410。

#### 给 AI 的提示词

```text
执行阶段 5。迁移 storage/media 模块。实现本地存储、路径安全、文件类型校验、图片元数据、视频音频元数据可先用 ffprobe 或留清晰接口，必须支持 /storage/** Range 读取和 /uploads/** 410。媒体上传写入 n_media_assets，失败时清理文件。
```

### 阶段 6：帖子、评论、标签、推荐反馈模块

#### 目标

迁移核心内容流，包括帖子列表、创建、修改、删除、回复、转发、点赞、收藏、评论、标签、统计。

#### 输入文件

- `server/services/v2/posts.ts`
- `server/models/v2.ts`
- `server/api/v2/posts/**`
- `server/api/v2/comments/**`
- `server/api/v2/tags/**`
- `server/api/v2/recommendations/feedback.post.ts`

#### 接口清单

| 方法 | 路径 | 当前处理函数 |
|---|---|---|
| GET | `/api/v2/posts` | `v2ListPosts(mode=all)` |
| POST | `/api/v2/posts` | `v2CreatePost` |
| GET | `/api/v2/posts/trending` | `v2ListPosts(mode=trending)` |
| GET | `/api/v2/posts/{id}` | `v2GetPost` |
| PUT | `/api/v2/posts/{id}` | `v2UpdatePost` |
| DELETE | `/api/v2/posts/{id}` | `v2DeletePost` |
| GET | `/api/v2/posts/{id}/analytics` | `v2PostAnalytics` |
| GET | `/api/v2/posts/{id}/likes` | `v2PostLikesUsers` |
| POST | `/api/v2/posts/{id}/likes` | `v2LikePost(true)` |
| DELETE | `/api/v2/posts/{id}/likes` | `v2LikePost(false)` |
| POST | `/api/v2/posts/{id}/bookmarks` | `v2BookmarkPost(true)` |
| DELETE | `/api/v2/posts/{id}/bookmarks` | `v2BookmarkPost(false)` |
| GET | `/api/v2/posts/{id}/comments` | `v2ListComments` |
| POST | `/api/v2/posts/{id}/comments` | `v2CreateComment` |
| GET | `/api/v2/posts/{id}/replies` | `v2ListPosts(mode=replies)` |
| GET | `/api/v2/posts/{id}/retweets` | `v2ListPosts(mode=retweets)` |
| POST | `/api/v2/posts/{id}/retweets` | `v2CreateRetweet` |
| DELETE | `/api/v2/comments/{id}` | `v2DeleteComment` |
| POST | `/api/v2/comments/{id}/likes` | `v2LikeComment(true)` |
| DELETE | `/api/v2/comments/{id}/likes` | `v2LikeComment(false)` |
| GET | `/api/v2/tags` | `v2SearchTags` |
| GET | `/api/v2/tags/trending` | `v2SearchTags(trendingOnly=true)` |
| GET | `/api/v2/tags/{name}/posts` | `v2ListPosts(mode=tag)` |
| GET | `/api/v2/tags/{name}/analytics` | `v2TagAnalytics` |
| POST | `/api/v2/recommendations/feedback` | `v2RecommendationFeedback` |

#### 数据库对象

主要使用：

- `n_posts`
- `n_post_stats`
- `n_post_media`
- `n_media_assets`
- `n_post_likes`
- `n_post_bookmarks`
- `n_comments`
- `n_comment_stats`
- `n_comment_likes`
- `n_tags`
- `n_post_tags`
- `n_post_mentions`
- `v_post_feed_item`
- `v_post_comment_list_item`
- `v_post_analytics`
- `v_tag_analytics`
- `fn_can_view_post`
- `fn_get_user_relationship`

#### 关键业务规则

- 所有帖子接口都需要登录。
- 帖子列表支持：
  - `page`
  - `page_size`
  - `sort=newest|oldest|popular`
  - `timeline=home|mentions`
  - `q`
  - mode：all、trending、user、me、bookmarks、likes、tag、replies、retweets
- `v2PostSelectSql` 的核心过滤必须保留：

```sql
WHERE fn_can_view_post(:viewer_id, v.post_id) = 1
```

- 查询 CLOB content 时使用 `DBMS_LOB.SUBSTR(content, 4000, 1)` 或 Java CLOB 转 String，确保 JSON 序列化不爆。
- 创建普通帖时，非 repost 必须有 content 或 media。
- `media_ids` 最多 4 个。
- `tag_names` 去重，最多 20 个，去掉开头 `#`。
- `mention_user_ids` 去重，最多 50 个。
- 创建 reply、repost、mention、like、comment 时要调用通知服务创建通知。
- 修改帖子只能作者本人。
- 删除帖子是软删除：`n_posts.is_deleted=1`。
- `GET /posts/{id}` 会增加 `n_post_stats.views_count`。
- 评论支持 parent/root comment。
- 删除评论是软删除：`n_comments.is_deleted=1`。
- 推荐反馈当前是轻量 stub：校验 `resource_type`、`resource_id`、`action` 后返回 `{ accepted: true }`。

#### 验收

- 首页列表、个人列表、收藏列表、点赞列表、标签列表能分页返回。
- 创建帖子后媒体、标签、提及关系完整。
- 点赞/取消点赞计数正确，触发通知。
- 收藏/取消收藏状态正确。
- 评论、回复、删除评论、评论点赞可用。
- 帖子详情会增加浏览量。
- 删除帖子后列表不再出现。

#### 给 AI 的提示词

```text
执行阶段 6。迁移 posts/comments/tags/recommendation feedback。必须平移 Oracle SQL、视图、fn_can_view_post、DBMS_LOB.SUBSTR、分页、通知触发和软删除规则。不要重写数据库结构，不要改 API 字段名。完成后给出创建帖子、列表、点赞、评论、删除的验收命令。
```

### 阶段 7：群组模块

#### 目标

迁移群组、成员、权限、群组帖子、群组评论、邀请、通知偏好、审计日志。

#### 输入文件

- `server/services/v2/groups.ts`
- `server/models/v2.ts`
- `server/api/v2/groups/**`
- `doc/NekoTribe-V2-群组聊天接口文档.md`
- `data/oracle-init/01_groups_tables.sql`
- `data/oracle-init/04_groups_functions.sql`
- `data/oracle-init/05_groups_views.sql`

#### 群组接口清单

| 方法 | 路径 | 当前处理函数 |
|---|---|---|
| GET | `/api/v2/groups` | `v2ListGroups` |
| POST | `/api/v2/groups` | `v2CreateGroup` |
| GET | `/api/v2/groups/popular` | `v2PopularGroups` |
| GET | `/api/v2/groups/{id}` | `v2GetGroupById` |
| PATCH | `/api/v2/groups/{id}` | `v2PatchGroup` |
| DELETE | `/api/v2/groups/{id}` | `v2DeleteGroup` |
| GET | `/api/v2/groups/by-slug/{slug}` | `v2GetGroupBySlug` |
| GET | `/api/v2/groups/{id}/notification-preference` | `v2GetGroupNotificationPreference` |
| PUT | `/api/v2/groups/{id}/notification-preference` | `v2PutGroupNotificationPreference` |
| GET | `/api/v2/groups/{id}/members` | `v2GroupMembers` |
| POST | `/api/v2/groups/{id}/members/current` | `v2JoinGroup` |
| DELETE | `/api/v2/groups/{id}/members/current` | `v2LeaveGroup` |
| PUT | `/api/v2/groups/{id}/members/{user_id}/approval-status` | `v2ApproveMember` |
| DELETE | `/api/v2/groups/{id}/members/{user_id}` | `v2RemoveMember` |
| PATCH | `/api/v2/groups/{id}/members/{user_id}/role` | `v2ChangeMemberRole` |
| PATCH | `/api/v2/groups/{id}/members/{user_id}/roles` | 兼容 role patch |
| PUT | `/api/v2/groups/{id}/members/{user_id}/mute-status` | `v2MuteMember` |
| DELETE | `/api/v2/groups/{id}/members/{user_id}/mute-status` | `v2UnmuteMember` |
| PUT | `/api/v2/groups/{id}/ownership` | `v2TransferOwnership` |
| GET | `/api/v2/groups/{id}/posts` | `v2GroupPosts` |
| POST | `/api/v2/groups/{id}/posts` | `v2CreateGroupPost` |
| GET | `/api/v2/groups/{id}/posts/{post_id}` | `v2GetGroupPost` |
| DELETE | `/api/v2/groups/{id}/posts/{post_id}` | `v2DeleteGroupPost` |
| PUT | `/api/v2/groups/{id}/posts/{post_id}/pin-status` | `v2SetGroupPostPin` |
| POST | `/api/v2/groups/{id}/posts/{post_id}/likes` | `v2LikeGroupPost(true)` |
| DELETE | `/api/v2/groups/{id}/posts/{post_id}/likes` | `v2LikeGroupPost(false)` |
| GET | `/api/v2/groups/{id}/posts/{post_id}/comments` | `v2GroupComments` |
| POST | `/api/v2/groups/{id}/posts/{post_id}/comments` | `v2CreateGroupComment` |
| DELETE | `/api/v2/groups/{id}/posts/{post_id}/comments/{comment_id}` | `v2DeleteGroupComment` |
| POST | `/api/v2/groups/{id}/posts/{post_id}/comments/{comment_id}/likes` | `v2LikeGroupComment(true)` |
| DELETE | `/api/v2/groups/{id}/posts/{post_id}/comments/{comment_id}/likes` | `v2LikeGroupComment(false)` |
| POST | `/api/v2/groups/{id}/invites` | `v2CreateGroupInvite` |
| GET | `/api/v2/groups/{id}/invites` | `v2GroupInvites` |
| GET | `/api/v2/groups/invite-codes/{code}` | `v2InviteCodeInfo` |
| POST | `/api/v2/groups/invites/{invite_id}/responses` | `v2RespondInvite` |
| GET | `/api/v2/groups/{id}/audit-logs` | `v2AuditLogs` |

#### 数据库对象

主要使用：

- `n_groups`
- `n_group_tags`
- `n_group_members`
- `n_group_notification_preferences`
- `n_group_posts`
- `n_group_comments`
- `n_group_invites`
- `n_group_audit_logs`
- `n_group_post_likes`
- `n_group_comment_likes`
- `v_group_details`
- `v_user_groups`
- `v_popular_groups`
- `v_group_member_details`
- `v_group_timeline`
- `v_group_post_details`
- `v_group_comment_details`
- `v_group_invite_details`
- `v_group_audit_log_details`
- `fn_has_group_permission`
- `fn_can_view_group`
- `fn_can_post_in_group`
- `fn_is_invite_valid`

#### 关键业务规则

- category 只允许：`tech`、`game`、`music`、`art`、`life`、`study`、`work`、`other`。
- privacy 只允许：`public`、`private`、`secret`。
- post_permission 只允许：`all`、`admin_only`、`moderator_up`。
- role 只允许：`owner`、`admin`、`moderator`、`member`。
- 群组创建后：
  - 创建 `n_groups`
  - 生成 slug：`{name-normalized}-{groupId}`
  - 创建 owner 成员记录
  - 写入 tags，最多 8 个
- 加入群组：
  - public 且无需审批：status active
  - private 或 join_approval：status pending
  - secret 必须邀请码
  - invite_code 有效时 status active
  - 使用邀请加入时更新 `n_group_invites.used_count`
- 退出群组：owner 不能退出。
- 管理成员、置顶、删除别人群组帖子等必须用 `fn_has_group_permission` 判断。
- 群组帖子删除是软删除，写 `deleted_by` 和 `delete_reason`。
- 群组邀请：
  - 指定 invitee 时不生成公开 code
  - 不指定 invitee 时生成 code
  - 默认过期小时 168
  - 默认 max_uses 1
- 重要事件要写通知：
  - 群组邀请
  - 群组帖子
  - 群组评论

#### 验收

- 创建群组后 owner 成员存在。
- 列表能按 q/privacy/category 过滤。
- 邀请码加入、私有群审批、secret 群限制正确。
- 群组成员角色变更和静音权限正确。
- 群组发帖、评论、点赞、置顶、删除正确。
- 审计日志能分页查询。

#### 给 AI 的提示词

```text
执行阶段 7。迁移 groups 模块。必须保留 Oracle 群组函数和视图，尤其 fn_has_group_permission、fn_can_view_group、fn_can_post_in_group。实现群组、成员、邀请、群组帖子、群组评论、通知偏好、审计日志。不要改现有 DTO 字段名和响应 envelope。
```

### 阶段 8：聊天、WebSocket、在线状态模块

#### 目标

迁移群组聊天、频道、消息、消息反应、私聊、WebSocket 认证、Redis Pub/Sub、在线状态。

#### 输入文件

- `server/services/v2/chat.ts`
- `server/services/v2/presence.ts`
- `server/routes/_ws.ts`
- `server/utils/redis.ts`
- `server/utils/wsSession.ts`
- `server/api/v2/chat/**`
- `app/composables/useRealtimeSocket.ts`

#### REST 接口清单

| 方法 | 路径 | 当前处理函数 |
|---|---|---|
| GET | `/api/v2/chat/groups` | `v2ListChatGroups` |
| GET | `/api/v2/chat/groups/{id}/channels` | `v2ListChatChannels` |
| POST | `/api/v2/chat/groups/{id}/channels` | `v2CreateChatChannel` |
| GET | `/api/v2/chat/groups/{id}/members` | `v2ListChatMembers` |
| PATCH | `/api/v2/chat/channels/{channel_id}` | `v2UpdateChatChannel` |
| DELETE | `/api/v2/chat/channels/{channel_id}` | `v2DeleteChatChannel` |
| GET | `/api/v2/chat/channels/{channel_id}/messages` | `v2ListChatMessages` |
| POST | `/api/v2/chat/channels/{channel_id}/messages` | `v2CreateChatMessage` |
| PUT | `/api/v2/chat/channels/{channel_id}/read-status` | `v2SetChatReadStatus` |
| PUT | `/api/v2/chat/channels/{channel_id}/mute-status` | `v2SetChatChannelMuteStatus` |
| PATCH | `/api/v2/chat/messages/{message_id}` | `v2UpdateChatMessage` |
| DELETE | `/api/v2/chat/messages/{message_id}` | `v2DeleteChatMessage` |
| PUT | `/api/v2/chat/messages/{message_id}/pin-status` | `v2SetChatMessagePinStatus` |
| POST | `/api/v2/chat/messages/{message_id}/reactions` | `v2CreateChatReaction` |
| DELETE | `/api/v2/chat/messages/{message_id}/reactions` | `v2DeleteChatReaction` |
| GET | `/api/v2/chat/direct-conversations` | `v2ListDirectConversations` |
| POST | `/api/v2/chat/direct-conversations` | `v2CreateDirectConversation` |
| GET | `/api/v2/chat/direct-conversations/{conversation_id}/messages` | `v2ListDirectMessages` |
| POST | `/api/v2/chat/direct-conversations/{conversation_id}/messages` | `v2CreateDirectMessage` |

#### WebSocket 契约

路径：`/_ws`

认证 token 提取顺序：

1. query：`token`
2. header：`Authorization: Bearer ...`
3. cookie：`access_token`

认证后必须校验 `n_auth_sessions`：

- `user_id`
- `session_id`
- `access_jti`
- `revoked_at IS NULL`
- `access_token_expires_at > CURRENT_TIMESTAMP`

客户端消息：

```json
{ "type": "chat_join_channel", "data": { "channelId": 1 } }
{ "type": "chat_leave_channel", "data": { "channelId": 1 } }
{ "type": "ping" }
```

服务端消息统一：

```json
{
  "type": "chat_message",
  "data": {},
  "timestamp": 1710000000000
}
```

Redis 频道保持：

- `ws:broadcast`
- `ws:user:{userId}`
- `ws:room:{roomId}`
- `ws:chat:channel:{channelId}`
- `ws:presence`
- `ws:system`

本机房间 ID 保持：

- `chat:channel:{channelId}`

#### 数据库对象

主要使用：

- `n_chat_channels`
- `n_chat_messages`
- `n_chat_message_media`
- `n_chat_message_reactions`
- `n_chat_channel_reads`
- `n_chat_channel_mutes`
- `n_direct_conversations`
- `n_direct_messages`
- `n_direct_conversation_reads`
- `n_group_members`
- `n_groups`
- `n_auth_sessions`
- `n_user_settings`

#### 关键业务规则

- 群组聊天只允许 active/muted 成员访问。
- 管理频道需要 owner/admin/moderator。
- 系统会自动确保默认频道存在。
- 私有频道只有管理员可见。
- 发消息必须有 content 或 media。
- 聊天附件必须属于当前用户且 `status='ready'`。
- 发群聊消息必须事务写入：
  - `n_chat_messages`
  - `n_chat_message_media`
  - 更新 `n_chat_channels.last_message_id`、`last_message_at`、`message_count`
- 发消息后发布 `chat_message` 到本地会话和 Redis。
- 编辑后发布 `chat_message_updated`。
- 删除后发布 `chat_message_deleted`。
- reaction 变更后发布 `chat_reaction_updated`。
- 读取频道消息第一页后自动更新 read status。
- 私聊 conversation 使用 user_low_id/user_high_id 去重。
- 在线状态基于：
  - 当前 WebSocket session
  - `n_auth_sessions.last_accessed_at >= now - 90s`
  - `n_user_settings.show_online_status=0` 时返回 hidden
- WS 断开后延迟 95 秒再发布 offline，避免刷新页面造成闪烁。

#### 验收

- WebSocket 未认证连接会收到错误并关闭。
- 登录后连接 `/_ws` 成功。
- join 无权限频道返回错误。
- 同频道两个用户能实时收到消息。
- Redis 开启时两个 Spring Boot 实例之间能同步消息。
- ping 会更新 session 活跃时间并返回 pong。
- presence_update 能广播。
- 私聊消息能实时推送给目标用户。

#### 给 AI 的提示词

```text
执行阶段 8。迁移 chat/presence/WebSocket。必须使用原始 WebSocket JSON 协议，不要改成 STOMP，除非同时保持现有 JSON 协议兼容。保持 /_ws、token 提取顺序、Redis 频道名、消息 type、房间 ID、presence 90 秒窗口和 95 秒离线延迟。完成后给出两个用户实时聊天的手动测试步骤。
```

### 阶段 9：通知模块

#### 目标

迁移通知列表、已读、批量已读、删除、恢复，以及通知创建后的实时推送。

#### 输入文件

- `server/services/v2/notifications.ts`
- `server/models/v2.ts`
- `server/api/v2/notifications/**`

#### 接口清单

| 方法 | 路径 | 当前处理函数 |
|---|---|---|
| GET | `/api/v2/notifications` | `v2ListNotifications` |
| PUT | `/api/v2/notifications/read-status` | `v2BatchSetNotificationReadStatus` |
| PUT | `/api/v2/notifications/{id}/read-status` | `v2SetNotificationReadStatus` |
| DELETE | `/api/v2/notifications/{id}` | `v2DeleteNotification` |
| PUT | `/api/v2/notifications/{id}/restore-status` | `v2RestoreNotification` |

#### 数据库对象

主要使用：

- `n_notifications`
- `n_notification_preferences`
- `n_user_settings`
- `v_user_profile_public`

#### 关键业务规则

- `v2CreateNotification` 是内部服务，其他模块会调用。
- actor 和 user 相同则不创建通知。
- 用户不存在或 inactive 不创建通知。
- `n_notification_preferences.is_enabled=0` 时不存储该类型通知。
- `n_user_settings.push_notification_enabled=0` 时存储但不实时推送。
- `metadata_json` 是 CLOB 风险点，查询时要转字符串：

```sql
DBMS_LOB.SUBSTR(metadata_json, 4000, 1) AS metadata_json
```

- 实时推送到：
  - 本机 `sendWsToUser`
  - Redis `ws:user:{userId}`
- 通知列表支持：
  - `type`
  - `unread_only`
  - `show_deleted`
  - 分页

#### 验收

- 列表分页正确。
- 单条已读/未读推送 `notification_read_status_updated`。
- 批量已读推送 `notifications_read_status_updated`。
- 删除推送 `notification_deleted`。
- 恢复推送 `notification_restored`。
- 帖子点赞、评论、关注、群组邀请等调用通知服务后能进入通知列表。

#### 给 AI 的提示词

```text
执行阶段 9。迁移 notifications 模块和内部通知创建服务。必须保留 n_notification_preferences、push_notification_enabled、metadata_json CLOB 字符串化、WebSocket+Redis 双通道推送。完成后用一个帖子点赞或手动创建通知验证实时通知。
```

### 阶段 10：审核、举报、处罚、申诉模块

#### 目标

迁移内容审核、举报、审核统计、批量操作、用户处罚、审核设置、申诉处理。

#### 输入文件

- `server/services/v2/moderation.ts`
- `server/api/v2/moderation/**`
- `server/api/v2/reports/index.post.ts`
- `doc/NekoTribe未实现功能盘点.md`

#### 接口清单

| 方法 | 路径 | 当前处理函数 |
|---|---|---|
| GET | `/api/v2/moderation/content` | `v2ListModerationContent` |
| POST | `/api/v2/moderation/content/{post_id}/actions` | `v2ModeratePost` |
| POST | `/api/v2/moderation/content/bulk-actions` | `v2BulkModeratePosts` |
| GET | `/api/v2/moderation/stats` | `v2GetModerationStats` |
| POST | `/api/v2/reports` | `v2CreateReport` |
| GET | `/api/v2/moderation/reports` | `v2ListModerationReports` |
| PATCH | `/api/v2/moderation/reports/{report_id}` | `v2PatchModerationReport` |
| GET | `/api/v2/moderation/users` | `v2ListModerationUsers` |
| POST | `/api/v2/moderation/users/{user_id}/actions` | `v2ModerateUser` |
| GET | `/api/v2/moderation/settings` | `v2GetModerationSettings` |
| PATCH | `/api/v2/moderation/settings` | `v2PatchModerationSettings` |
| GET | `/api/v2/moderation/appeals` | `v2ListModerationAppeals` |
| PATCH | `/api/v2/moderation/appeals/{appeal_id}` | `v2PatchModerationAppeal` |

#### 权限规则

除 `POST /api/v2/reports` 外，审核接口必须调用 `requireModerationAccess`。

规则：

- 先必须登录。
- 用户必须 `is_active=1` 且 `status='active'`。
- `MODERATION_ALLOW_ALL=true` 时允许所有登录用户。
- 否则检查 `MODERATION_ADMIN_ACCOUNTS`，逗号分隔，可匹配 username 或 email。
- 如果未配置，默认 allowlist 是 `v2_admin`。
- 不要使用群组 admin/moderator 角色替代审核权限。
- 无权限返回 `40301`，message 为 `需要审核权限`。

#### 数据库对象

主要使用：

- `n_moderation_reports`
- `n_moderation_cases`
- `n_moderation_actions`
- `n_moderation_user_restrictions`
- `n_moderation_settings`
- `n_statement_appeals`
- `n_account_statements`
- `n_posts`
- `n_users`
- `n_user_stats`
- `n_post_stats`

#### 关键业务规则

report reason 只允许：

- `spam`
- `harassment`
- `hate`
- `violence`
- `adult`
- `misinformation`
- `copyright`
- `other`

priority 只允许：

- `low`
- `normal`
- `high`
- `urgent`

target type 只允许：

- `post`
- `comment`
- `user`
- `group_post`
- `group_comment`

审核内容 action：

- `approve`
- `reject`
- `flag`
- `remove`
- `restore`
- `claim`
- `release`

用户处罚 action：

- `ban`
- `unban`
- `mute`
- `unmute`
- `note`

默认设置：

- `auto_hide_report_threshold=10`
- `require_note_on_reject=true`
- `allow_moderator_claim=true`
- `default_mute_hours=24`

事务要求：

- 举报创建后必须同步 case 统计，整体事务提交。
- 审核内容操作要同时更新 `n_posts`、`n_moderation_cases`、`n_moderation_reports`、`n_moderation_actions`。
- 批量审核必须整体事务。
- 用户 ban/unban/mute/unmute 要同时更新 users/restrictions/actions/case。
- 申诉处理要更新 `n_statement_appeals` 并记录 action。

#### 验收

- 非审核用户访问 `/api/v2/moderation/content` 返回 40301。
- allowlist 用户能访问审核队列。
- 举报帖子后会创建 report 和 case。
- approve/remove 会软删除帖子。
- reject/restore 会恢复帖子。
- ban 会把用户 `status=suspended`、`is_active=0`。
- unban 会恢复 active。
- 审核设置可读写。
- 申诉可审批或拒绝。

#### 给 AI 的提示词

```text
执行阶段 10。迁移 moderation/reports/appeals 模块。必须严格实现 requireModerationAccess，MODERATION_ADMIN_ACCOUNTS 默认 v2_admin，MODERATION_ALLOW_ALL 仅用于开发。保留所有审核枚举、默认设置、事务、action 记录和帖子/用户状态联动。
```

### 阶段 11：SentimentFlow 代理和系统边界

#### 目标

迁移 SentimentFlow 外部服务代理、配置接口、健康检查、404 v2 fallback。

#### 输入文件

- `server/utils/sentiment-flow.ts`
- `server/api/v2/integrations/sentiment-flow/config.get.ts`
- `server/api/v2/integrations/sentiment-flow/[...path].ts`
- `server/api/v2/[...path].ts`
- `server/api/health.get.ts`

#### 接口清单

| 方法 | 路径 | 当前行为 |
|---|---|---|
| GET | `/api/v2/integrations/sentiment-flow/config` | 返回 enabled/baseUrlConfigured/proxyBasePath/timeoutMs |
| ANY | `/api/v2/integrations/sentiment-flow/**` | 代理到 SentimentFlow |
| ANY | `/api/v2/**` 未匹配 | 返回 40404 |
| GET | `/api/health` | 健康检查 |

#### SentimentFlow 规则

- `SENTIMENTFLOW_ENABLED=false` 时代理返回 503。
- `SENTIMENTFLOW_BASE_URL` 未配置时返回 500。
- 默认 base URL：`http://localhost:{SENTIMENTFLOW_HOST_PORT or SENTIMENTFLOW_CONTAINER_PORT or 8846}/api`
- timeout 默认 10000ms，范围 1000 到 120000。
- 禁止上游 path traversal：
  - 不允许绝对 URL
  - 不允许 `.`、`..`
  - 不允许跳出 base path
- 代理请求不转发：
  - host
  - connection
  - content-length
  - transfer-encoding
  - upgrade
  - keep-alive
  - proxy-authenticate
  - proxy-authorization
  - authorization
  - te
  - trailer
  - cookie
- 上游重定向最多 5 次，且不能跳出配置 baseUrl。
- GET/HEAD 不带 body。
- 超时返回 504。
- 上游失败返回 502。

#### 验收

- disabled 时返回 503。
- config 接口返回当前配置状态。
- 非法路径返回 400。
- 上游不可达返回 502 或 504。
- 未匹配 v2 path 返回：

```json
{
  "code": 40404,
  "message": "API route not found",
  "data": null,
  "meta": null
}
```

#### 给 AI 的提示词

```text
执行阶段 11。迁移 SentimentFlow config 和代理，以及 v2 fallback 404。严格保留代理安全规则、blocked headers、redirect 限制、timeout、错误响应结构。不要改前端调用路径。
```

### 阶段 12：v1 兼容层

#### 目标

可选迁移 v1 旧接口。如果前端已经完全走 v2，可以只实现禁用逻辑；如果仍有页面依赖 v1，再逐个迁移。

#### 输入文件

- `server/api/v1/**`
- `server/middleware/auth.ts`
- `server/utils/auth.ts`

#### 当前 v1 状态

当前 v1 API 有约 59 个路由，涉及：

- `account`
- `analytics`
- `auth`
- `follow`
- `hashtags`
- `interactions`
- `notifications`
- `system`
- `tweets`
- `users`

当前鉴权中间件中，v1 只有在 `ENABLE_V1_API=true` 时启用，否则返回 410。

#### 建议策略

第一版 Spring Boot：

- 默认 `nekotribe.legacy.enable-v1-api=false`
- `/api/v1/**` 返回 410
- 如果前端有遗留调用，再单独迁移对应 v1 路由

如果必须迁移 v1：

- v1 响应结构不是 v2 envelope，而是：

```json
{
  "success": true,
  "message": "...",
  "data": {},
  "code": 200,
  "timestamp": "ISO时间"
}
```

- v1 使用旧 `n_user_sessions` 和部分旧表/视图命名，例如 `n_likes`、`n_bookmarks`、`v_comprehensive_timeline`，需要确认这些对象在当前 Oracle 中仍存在。
- v1 登录和刷新逻辑与 v2 不同，不要混在 v2 session 服务里。

#### 给 AI 的提示词

```text
执行阶段 12。先实现 /api/v1/** 默认 410，并用配置 nekotribe.legacy.enable-v1-api 控制。不要迁移全部 v1 业务，除非我明确指定某个 v1 路由。v1 响应结构和 v2 不同，不能混用。
```

## 5. 数据库迁移细节

### 5.1 Baseline 管理

Spring Boot 项目可以使用 Flyway，但第一版不要让 Flyway 重写现有 `doc/neko_tribe-oracle-v2.sql`。推荐：

1. 保留当前 Compose `db-init` 流程继续初始化 Oracle。
2. Spring Boot 只连接已有 schema。
3. 后续新增字段再用 Flyway 增量脚本。

如果必须用 Flyway 管理 baseline：

- 把 `doc/neko_tribe-oracle-v2.sql` 作为 `V1__baseline.sql`。
- 确保只在空库运行。
- 非空库使用 `baselineOnMigrate=true`。
- 不要拆掉其中的函数、视图、触发器。

### 5.2 Oracle SQL 平移规则

TypeScript 当前写法：

```ts
await v2Rows(connection, sql, binds)
```

Spring Boot 平移：

```java
List<Map<String, Object>> rows = jdbc.queryForList(sql, params);
```

序列：

```sql
SELECT seq_post_id.NEXTVAL AS id FROM dual
```

Spring Boot：

```java
long postId = sequenceService.nextVal("seq_post_id");
```

分页保持 Oracle `ROW_NUMBER()` 包裹写法，不要改成 MySQL `LIMIT`。

CLOB：

- 优先在 SQL 中继续 `DBMS_LOB.SUBSTR(col, 4000, 1) AS col`。
- 如果确实要返回完整 CLOB，在 Java 中显式转 String，不能直接让 Jackson 序列化 `Clob`。

事务：

- TypeScript 中凡是 `v2Execute(..., false)` 加 `commit/rollback` 的地方，Spring Boot 必须加 `@Transactional`。
- 单条简单更新可以使用默认事务。
- 文件上传场景：DB 失败要清理文件，文件删除失败只记录日志。

### 5.3 请求时 DDL 的处理

当前代码里有一些请求时自动补 schema 的逻辑：

- `v2EnsureMediaDescriptionColumn`
- `v2EnsureSettingsSchema`
- `v2EnsureTwoFactorSchema`
- `v2EnsureGroupFeatureSchema`
- `ensureModerationSchema`

Spring Boot 迁移不建议继续在普通请求中执行 DDL。推荐：

- 把这些 DDL 对齐到 `doc/neko_tribe-oracle-v2.sql` 或 Flyway 增量。
- Service 中只做业务，不做建表。
- 如果担心旧库缺字段，可以做启动时 schema check，但不要在每次请求中建表。

## 6. v2 DTO 总表

下面是必须创建的核心 DTO 分组。字段名以 `server/types/v2.d.ts` 和 `app/types/v2.ts` 为准。

### 6.1 Common

- `ApiResponse<T>`
- `ApiMeta`
- `AuthPayload`
- `RelationshipDto`

### 6.2 Auth

- `AuthOtpPayload`
- `AuthOtpData`
- `AuthOtpVerificationPayload`
- `AuthOtpVerificationData`
- `RegistrationPayload`
- `LoginPayload`
- `TokenData`
- `LoginSuccessData`
- `TwoFactorLoginChallengeData`
- `TwoFactorLoginPayload`
- `TwoFactorSetupPayload`
- `TwoFactorSetupData`
- `TwoFactorConfirmPayload`
- `TwoFactorConfirmData`
- `TwoFactorDisablePayload`
- `TwoFactorStatusData`
- `PasswordResetPayload`
- `SessionItem`

### 6.3 Users

- `PublicUser`
- `SelfUser`
- `UpdateUserPayload`
- `ChangeEmailPayload`
- `ChangeEmailData`
- `AvatarData`
- `UserSettings`
- `UpdateSettingsPayload`
- `AccountStatement`
- `UpdateStatementPayload`
- `StatementStatusData`
- `StatementAppealPayload`
- `StatementAppealData`

### 6.4 Posts

- `MediaAsset`
- `PostStats`
- `ViewerPostState`
- `Post`
- `CreatePostPayload`
- `RetweetPayload`
- `LikePostData`
- `BookmarkPostData`
- `CommentStats`
- `CommentViewerState`
- `Comment`
- `CreateCommentPayload`
- `LikeCommentData`
- `PostAnalytics`
- `TagItem`
- `TagAnalytics`
- `RecommendationFeedbackPayload`
- `RecommendationFeedbackData`

### 6.5 Groups

- `Group`
- `GroupMembership`
- `CreateGroupPayload`
- `UpdateGroupPayload`
- `JoinGroupPayload`
- `GroupMember`
- `GroupMemberStatusData`
- `GroupPost`
- `CreateGroupPostPayload`
- `GroupComment`
- `CreateGroupCommentPayload`
- `GroupCommentLikeData`
- `CreateGroupInvitePayload`
- `GroupInvite`
- `CreateGroupInviteData`
- `InviteCodeData`
- `InviteResponsePayload`
- `InviteResponseData`
- `GroupNotificationPreference`
- `GroupAuditLog`

### 6.6 Chat

- `ChatGroup`
- `ChatChannel`
- `ChatMember`
- `ChatMessage`
- `ChatReactionSummary`
- `ChatMessageReply`
- `CreateChatChannelPayload`
- `UpdateChatChannelPayload`
- `CreateChatMessagePayload`
- `UpdateChatMessagePayload`
- `ChatReactionPayload`
- `ChatMessagePinPayload`
- `ChatReadStatusData`
- `ChatChannelMuteData`
- `DirectConversation`
- `DirectMessage`
- `CreateDirectConversationPayload`
- `CreateDirectMessagePayload`

### 6.7 Notifications and Moderation

- `Notification`
- `NotificationReadPayload`
- `NotificationBatchReadPayload`
- `NotificationReadData`
- `NotificationBatchReadData`
- `ModerationReport`
- `ModerationContentItem`
- `ModerationStats`
- `ModerationActionPayload`
- `ModerationUserItem`
- `ModerationUserActionPayload`
- `ModerationSetting`
- `ModerationSettingsPayload`
- `CreateReportPayload`
- `ModerationAppeal`

## 7. 缓存迁移要求

### 7.1 v2 API 响应缓存

当前 `server/utils/api-cache.ts` 对 GET `/api/v2/**` 做响应缓存。

Spring Boot 第一版如果时间紧，可以先不启用响应缓存，但必须保留接口位置和后续扩展点。完整迁移时按下面规则实现。

Redis key 前缀：

- `nt:api-cache`
- `nt:api-cache-hits`
- `nt:api-cache-tag`

只缓存：

- GET
- `/api/v2/**`
- 2xx 响应

不缓存：

- 非 GET
- auth token refresh 这类 cache neutral mutation

scope：

- 未登录：`anonymous`
- 登录：`user:{userId}`
- `/api/v2/auth/sessions`：按 session 细分

TTL：

- chat/notifications/auth sessions：20s，max 120s
- moderation：45s，max 240s
- trending posts/popular groups/trending tags：300s，max 900s
- 单个 posts/groups/users：120s，max 600s
- posts/groups/users/tags 列表：90s，max 480s
- 默认：60s，max 300s

写路径：

- 非 GET mutation 成功后按 tags bump version。
- OTP、two-factor challenge、token refresh 属于 cache neutral mutation。

### 7.2 Oracle 查询缓存

当前 `server/utils/oracle-query-cache.ts` 包装 `connection.execute`，对安全 SELECT/WITH 进行透明缓存。

完整迁移时建议实现为 `CachedJdbcQueryHelper`，规则：

只缓存：

- `SELECT`
- `WITH`
- 有 rows 的结果
- 可 JSON 序列化的结果

跳过：

- `NEXTVAL`
- `FOR UPDATE`
- 包含敏感字段或表：
  - `password_hash`
  - `access_token`
  - `refresh_token`
  - `access_jti`
  - `refresh_jti`
  - `verification_code`
  - `n_auth_sessions`
  - `n_user_sessions`
- mutation SQL

Redis key 前缀：

- `nt:oracle-query-cache`
- `nt:oracle-query-cache-hits`
- `nt:oracle-query-cache-tag`

mutation 后按 SQL 表名和领域 tag 失效，并联动 API response cache tag。

## 8. 全部 v2 路由迁移索引

AI 每完成一个模块，要对照本表勾选，避免漏接口。

### 8.1 Auth

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

### 8.2 Users

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

### 8.3 Posts, Comments, Tags

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

### 8.4 Media and Storage

- `POST /api/v2/media`
- `DELETE /api/v2/media/{id}`
- `GET /storage/**`
- `GET /uploads/**`

### 8.5 Groups

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

### 8.6 Chat

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

### 8.7 Notifications

- `GET /api/v2/notifications`
- `PUT /api/v2/notifications/read-status`
- `PUT /api/v2/notifications/{id}/read-status`
- `DELETE /api/v2/notifications/{id}`
- `PUT /api/v2/notifications/{id}/restore-status`

### 8.8 Moderation

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

### 8.9 Integrations and Fallback

- `GET /api/health`
- `GET /api/v2/integrations/sentiment-flow/config`
- `ANY /api/v2/integrations/sentiment-flow/**`
- `ANY /api/v2/**` fallback 40404
- `ANY /api/v1/**` optional 410 or legacy compatibility

## 9. 测试和验收总清单

### 9.1 自动化测试建议

至少写这些测试：

- `ApiResponseTest`
- `GlobalExceptionHandlerTest`
- `JwtServiceTest`
- `AuthFilterTest`
- `AuthServiceTest`
- `UserServiceTest`
- `PostServiceTest`
- `GroupServiceTest`
- `ChatServiceTest`
- `NotificationServiceTest`
- `ModerationAccessTest`
- `StorageServiceTest`
- `SentimentFlowProxyTest`

数据库相关测试可以分两层：

- Unit test：mock repository。
- Integration test：连接本地 Compose Oracle 和 Redis。

### 9.2 手动回归主流程

每个阶段最终至少跑：

1. 启动 Oracle、Redis、Spring Boot。
2. `GET /api/health`。
3. 注册 OTP。
4. 注册用户。
5. 登录并得到 cookies。
6. `GET /api/v2/users/me`。
7. 修改设置。
8. 上传头像。
9. 上传媒体。
10. 创建帖子。
11. 获取帖子列表和详情。
12. 点赞帖子。
13. 评论帖子。
14. 创建群组。
15. 创建群组帖子。
16. 加入聊天频道。
17. WebSocket 收发群聊消息。
18. 创建举报。
19. 审核员查看审核队列。
20. 删除通知和恢复通知。

### 9.3 前端联调要求

Spring Boot 启动后，前端只应改 API base URL，不应改业务字段。

重点观察：

- 登录失败时是否显示真实 `账号或密码错误`，而不是 refresh token 错误。
- 未登录时通知轮询是否停止。
- `/api/v2/notifications` 不再出现 CLOB 序列化错误。
- WebSocket URL 不能是 `ws://0.0.0.0:30001/_ws`，前端应使用可访问 host。
- 上传后的 `public_url` 能被浏览器访问。
- 聊天气泡、通知、在线状态能够实时刷新。

## 10. AI 执行总提示词模板

每次给 AI 开始一个阶段时，可以使用下面模板。

```text
你正在把 C:\Code\NekoTribe 当前 Nuxt/Nitro 后端迁移到 Spring Boot。

必须遵守：
1. 以《doc/NekoTribe-SpringBoot后端迁移执行文档.md》为准。
2. 当前阶段只做【阶段 X：阶段名称】，不要提前做其他阶段。
3. 保持 /api/v2/** 响应 envelope：code/message/data/meta。
4. DTO 输出字段必须是 snake_case。
5. 数据库必须使用现有 Oracle schema：doc/neko_tribe-oracle-v2.sql。
6. 第一版使用 NamedParameterJdbcTemplate 平移 SQL，不要用 JPA 自动建表。
7. 保持 Cookie 名称 access_token、refresh_token。
8. 保持 WebSocket 路径 /_ws 和 JSON 消息协议。
9. 修改后必须运行测试或给出明确的本地验收命令。

当前要执行的阶段：
【把这里替换成阶段号和阶段标题】

请先阅读该阶段列出的输入文件，再实现代码。完成后输出：
- 改了哪些文件
- 已实现哪些接口
- 运行了哪些测试
- 还剩哪些风险或待验证点
```

## 11. 迁移风险清单

- 不要把 v2 的 snake_case DTO 改成 Java 默认 camelCase。
- 不要把当前 Oracle schema 改成 JPA 自动生成。
- 不要漏掉 `n_auth_sessions.access_jti` 校验，否则 access token revoke 语义会弱化。
- 不要直接 JSON 序列化 Oracle CLOB。
- 不要把 WebSocket 改成只支持 STOMP。
- 不要把审核权限误写成群组 moderator/admin。
- 不要让 `SENTIMENTFLOW_ENABLED=false` 时仍然访问上游服务。
- 不要在普通请求中继续自动执行 DDL。
- 不要让 Redis 不可用导致全站不可用，除非是明确依赖 Redis 的实时跨实例能力。
- 不要漏掉 mutation 后缓存失效，否则帖子、通知、群组会出现旧数据。

## 12. 推荐实施顺序

实际执行顺序建议：

1. 阶段 1：公共契约
2. 阶段 2：基础设施
3. 阶段 3：认证
4. 阶段 5：存储和媒体
5. 阶段 4：用户和关系
6. 阶段 9：通知
7. 阶段 6：帖子评论标签
8. 阶段 7：群组
9. 阶段 8：聊天和 WebSocket
10. 阶段 10：审核
11. 阶段 11：SentimentFlow 和 fallback
12. 阶段 12：v1 兼容

这样排序的原因是：认证、存储、用户、通知是帖子/群组/聊天/审核的共同依赖，先完成它们能减少后续返工。

