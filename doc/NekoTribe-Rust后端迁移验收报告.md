# NekoTribe Rust 后端迁移验收报告

> 日期：2026-05-23  
> 分支：`Rust`  
> 迁移依据：`doc/NekoTribe-Rust后端迁移执行文档.md`  
> 当前结论：已完成 Rust 后端工程骨架、Oracle/Redis 基础设施、Docker/Compose/Nginx 接入，并通过兼容代理保持现有 v2 API、`/uploads/**`、`/storage/**`、`/_ws` 与前端继续可用；但阶段 3-12 的业务模块尚未原生迁移到 Rust，不能宣称“全部后端功能已彻底改写为 Rust 原生实现”。

## 1. 阶段状态总览

| 阶段 | 范围 | 状态 | 当前验收结论 |
|---:|---|---|---|
| 1 | Rust 后端骨架、健康检查、v2 响应契约、错误、分页、安全头、日志 | 通过 | `backend-rust/` 已可独立编译运行，`GET /api/health` 和 v2 fallback 契约通过 |
| 2 | Oracle/Redis 基础设施、DB helper、限流、API 缓存、Oracle 查询缓存框架 | 通过/有环境备注 | 代码测试和 Redis 连通通过；Docker Rust 镜像已内置 Oracle Instant Client；Windows 本机缺少 Oracle Client，直接跑 Oracle ignored 测试失败 |
| 3 | Auth、JWT、Cookie、OTP、会话、2FA | 兼容代理可用，原生未完成 | `/api/v2/auth/**` 经 Rust 入口代理到现有 Nuxt/Nitro v2 后端，登录 smoke 通过 |
| 4 | 用户、账号设置、关系模块 | 兼容代理可用，原生未完成 | `/api/v2/users/me` 登录态 smoke 通过 |
| 5 | 存储和媒体模块 | 部分接入 | `/storage/**` 仍由 nginx 直出，`/uploads/**` 经 Rust 入口保留旧兼容响应 |
| 6 | 帖子、评论、标签、推荐反馈、举报入口 | 兼容代理可用，原生未完成 | `/api/v2/posts?limit=1` 登录态 smoke 通过 |
| 7 | 群组模块 | 兼容代理可用，原生未完成 | 路由由 Rust OpenAPI 匹配后代理到旧 v2 后端 |
| 8 | 通知模块 | 兼容代理可用，原生未完成 | HTTP 路由代理可用；通知业务仍在旧 v2 后端 |
| 9 | 聊天、WebSocket、在线状态 | 前端可用，Rust 原生未完成 | `/_ws` 仍由 nginx 转发到 Nuxt/Nitro，WebSocket smoke 可打开连接 |
| 10 | 审核、举报、处罚、申诉 | 兼容代理可用，原生未完成 | HTTP 路由代理可用，审核业务仍在旧 v2 后端 |
| 11 | SentimentFlow 代理和系统边界 | 兼容代理可用，原生未完成 | v2 SentimentFlow 前缀保留代理放行 |
| 12 | v1 兼容层、Docker/Nginx/部署切换 | 部分通过 | Compose 增加 `rust-backend`；nginx `/api/` 和 `/uploads/` 已转 Rust，`/`、`/_ws`、`/storage/` 保持现有服务路径 |

## 2. 本次新增/调整内容

### 2.1 Rust 后端工程

- 新增 `backend-rust/Cargo.toml`、`backend-rust/Dockerfile`。
- 新增 Rust 入口和分层目录：
  - `src/main.rs`
  - `src/app/*`
  - `src/config/*`
  - `src/httpx/*`
  - `src/middleware/*`
  - `src/db/*`
  - `src/cache/*`
  - `src/proxy/*`
- 新增测试：
  - `tests/contract_test.rs`
  - `tests/infrastructure_test.rs`
  - `tests/connectivity_test.rs`
  - `tests/proxy_test.rs`

### 2.2 已实现 Rust 能力

- `GET /api/health` 原生 Rust 实现。
- `/api/v2/**` 未匹配路由返回：

```json
{"code":40404,"message":"API route not found","data":null,"meta":null}
```

- v2 envelope helper：`code/message/data/meta`。
- `ApiError` 到 HTTP status 映射。
- 分页默认值和边界。
- 请求日志、panic recovery、`x-request-id`。
- 安全响应头：
  - `X-Content-Type-Options: nosniff`
  - `X-Frame-Options: DENY`
  - `Referrer-Policy: same-origin`
  - `Permissions-Policy: camera=(), microphone=(), geolocation=()`
- Oracle 配置、连接池包装、查询/事务 helper。
- Redis 配置、连接封装、cache key/tag 规则。
- API cache 与 Oracle query cache 的安全过滤规则。
- Rust 兼容代理：
  - 根据 `doc/v2.openapi.json` 识别已知 `/api/v2/**` 路由。
  - 保留 query、headers、method、body。
  - 代理到 `LEGACY_BACKEND_BASE_URL`，Docker 内默认 `http://app:3000`。
  - 未知 v2 路由不落到旧后端，直接返回 Rust 40404。

### 2.3 Compose/Nginx 接入

- `docker-compose.yml` 新增 `rust-backend` 服务。
- Rust 容器端口：`8080`。
- 主机端口：`${RUST_BACKEND_PORT:-30003}`。
- Docker 运行时内置 Oracle Instant Client `19.31 basiclite`。
- `nginx/nginx.compose.conf` 新增：
  - `upstream rust_backend`
  - `/api/` -> `rust-backend`
  - `/uploads/` -> `rust-backend`
- 保持：
  - `/` -> `app`
  - `/_ws` -> `app`
  - `/storage/` -> nginx alias

## 3. 验收环境

| 组件 | 实测状态 |
|---|---|
| Oracle | Docker 容器 `oracle19c` healthy，主机端口 `5501`，`SELECT 1 FROM dual` 通过 |
| Redis | Docker 容器 `nekotribe-redis-1` healthy，主机端口 `6379`，`PING` 通过 |
| Nuxt/Nitro legacy app | Docker 容器 `nekotribe-app-1` healthy，主机端口 `30001` |
| Rust backend | Docker 容器 `nekotribe-rust-backend-1` healthy，主机端口 `30003` |
| Nginx | Docker 容器 `nekotribe-nginx-dev` running，主机端口 `30002` |

## 4. 自动化验证结果

### 4.1 Rust 测试

命令：

```powershell
cargo test --manifest-path backend-rust\Cargo.toml
```

结果：

- 普通测试：19 passed。
- 外部连通性测试：2 ignored。
- 退出码：0。

### 4.2 Clippy

命令：

```powershell
cargo clippy --manifest-path backend-rust\Cargo.toml --all-targets -- -D warnings
```

结果：

- 通过。
- 退出码：0。

### 4.3 Docker 构建

命令：

```powershell
docker compose build rust-backend
```

结果：

- 镜像 `nekotribe-rust-backend:local` 构建通过。
- 运行阶段已安装 `oracle-instantclient19.31-basiclite`。

### 4.4 Compose 启动

命令：

```powershell
docker compose up -d rust-backend nginx
docker compose ps
```

结果：

- `nekotribe-rust-backend-1`：healthy。
- `nekotribe-app-1`：healthy。
- `nekotribe-redis-1`：healthy。
- `oracle19c`：healthy。

## 5. HTTP/前后端联动验收

### 5.1 Rust 直连入口

| 请求 | 结果 |
|---|---|
| `GET http://localhost:30003/api/health` | HTTP 200，返回 `status=ok` |
| `GET http://localhost:30003/api/v2/not-exists` | HTTP 404，返回 `code=40404` |
| `GET http://localhost:30003/api/v2/users/me` 未登录 | HTTP 401，旧 v2 错误体中包含 `data.code=40101` |
| `GET http://localhost:30003/api/v2/posts?limit=1` 未登录 | HTTP 401，旧 v2 错误体中包含 `data.code=40101` |

### 5.2 Nginx 入口

| 请求 | 结果 |
|---|---|
| `GET http://localhost:30002/api/health` | HTTP 200，确认 `/api/` 已转 Rust |
| `GET http://localhost:30002/api/v2/not-exists` | HTTP 404，返回 Rust `code=40404` |
| `GET http://localhost:30002/api/v2/users/me` 未登录 | HTTP 401，确认已由 Rust 代理到 v2 后端 |
| `GET http://localhost:30002/` 未登录 | HTTP 302 到 `/zh/auth/login` |
| `GET http://localhost:30002/storage/not-exists-smoke.png` | HTTP 404，nginx storage alias 可响应 |
| `GET http://localhost:30003/uploads/not-exists-smoke.png` | HTTP 410，保留旧 `/uploads` 兼容提示 |

### 5.3 登录态 smoke

执行方式：

1. 在 Oracle 中插入一次性 smoke 用户。
2. 通过 `http://localhost:30002/api/v2/auth/tokens` 登录。
3. 使用返回 cookie 访问登录态接口。
4. 删除 smoke 用户、会话、通知和 2FA 相关临时数据。

结果：

| 请求 | 结果 |
|---|---|
| `POST /api/v2/auth/tokens` | HTTP 200，`code=200`，`message=login success` |
| `GET /api/v2/users/me` | HTTP 200，`code=200` |
| `GET /api/v2/posts?limit=1` | HTTP 200，`code=200`，`meta.total=3` |

### 5.4 WebSocket smoke

命令使用 `ws` 连接：

```text
ws://localhost:30002/_ws
```

结果：

- 连接触发 `open`。
- 客户端关闭后返回 close 事件。
- 说明当前前端实时入口仍可经 nginx 到达 Nuxt/Nitro `/_ws`。

## 6. 数据与外部依赖验收

### 6.1 Redis

命令：

```powershell
cargo test --manifest-path backend-rust\Cargo.toml --test connectivity_test redis_ping_returns_pong -- --ignored --nocapture
docker compose exec redis sh -lc 'redis-cli -a "$REDIS_PASSWORD" ping'
```

结果：

- Rust Redis ignored 测试：1 passed。
- Docker Redis：`PONG`。

### 6.2 Oracle

命令：

```powershell
SELECT 1 AS total FROM dual;
```

结果：

- Docker Oracle SQLPlus：返回 `TOTAL = 1`。
- Rust 容器内：`/usr/lib/oracle/19.31/client64/lib/libclntsh.so` 存在。
- Windows 本机直接执行 Rust Oracle ignored 测试失败：
  - `DPI-1047: Cannot locate a 64-bit Oracle Client library`
  - 结论：这是本机 Oracle Client 环境缺失，不是 Docker Oracle 或 Rust 镜像缺失。

## 7. 未完成项和风险

当前实现是“Rust API 入口 + 基础设施 + 兼容代理”，不是阶段 3-12 的全量 Rust 原生业务重写。主要未完成项：

1. `auth/users/posts/groups/notifications/chat/moderation/sentiment-flow` 等业务仍由 Nuxt/Nitro TypeScript 后端处理。
2. `/_ws` 仍由 Nuxt/Nitro 提供，Rust 尚未实现 WebSocket/session/presence/fanout。
3. `/storage/**` 仍由 nginx alias 直出，Rust 尚未接管对象存储静态服务。
4. v2 代理错误体会保留 legacy Nitro 包装；例如未登录接口外层是 Nitro error body，内部 `data` 才是 v2 envelope。
5. Windows 本机缺少 Oracle Instant Client，不能在宿主机直接通过 Rust Oracle ignored 测试；Docker 运行时已解决。
6. 后续若要真正移除 Nuxt/Nitro 后端，必须按文档继续完成阶段 3-12 的原生 Rust handler/service/repository 迁移。

## 8. 后续原生迁移验收门槛

在宣称“后端彻底重构为 Rust”前，必须完成并通过：

```powershell
cargo fmt --manifest-path backend-rust\Cargo.toml --all
cargo test --manifest-path backend-rust\Cargo.toml
cargo clippy --manifest-path backend-rust\Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path backend-rust\Cargo.toml --test connectivity_test -- --ignored --nocapture
docker compose build rust-backend
docker compose up -d rust-backend nginx
```

并至少完成以下端到端主流程：

- 注册 OTP -> 注册 -> 登录 -> refresh -> logout。
- `/api/v2/users/me`、用户资料、用户设置、关系、屏蔽。
- 上传头像、上传媒体、`/storage/**` 静态访问。
- 发帖 -> 评论 -> 点赞 -> 收藏 -> 删除。
- 创建群组 -> 入群 -> 群组发帖 -> 邀请 -> 成员角色调整。
- 群聊、私聊、presence、通知实时推送。
- 通知列表、未读数、已读、删除、恢复。
- 举报 -> 审核处理 -> 处罚 -> 申诉。
- SentimentFlow 配置、代理、训练/预测相关接口。
- `/api/v2/not-exists`、旧 `/uploads/**`、错误 envelope、分页 meta、权限 401/403/404/409/422。

## 9. 当前可交付结论

本次交付已使 Docker/Nginx 环境中的 `/api/` 从 Rust 服务进入，并通过 Rust 代理保持现有前端和 v2 API 可运行；健康检查、未知路由、认证登录态、帖子列表、Redis、Oracle Docker、WebSocket 入口均完成 smoke 验收。

但根据迁移文档的阶段定义，原生 Rust 业务迁移只完成了阶段 1-2 的基础能力，阶段 3-12 仍需继续迁移。当前不能把 Nuxt/Nitro 后端容器移除，也不能把本报告作为“全量 Rust 原生后端完成”的最终验收。
