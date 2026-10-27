# NekoTribe Rust 后端（兼容模式与原生会话切片）

本分支是独立 Rust 工程。缺省 `RUST_BACKEND_MODE=compat` 保留 Nuxt 代理；显式 `native` 注册登录/2FA 挑战、两条 DELETE 会话撤销、`PATCH /api/v2/auth/tokens/current` 刷新、`DELETE /api/v2/auth/tokens/current` 退出和进程健康检查，直接访问 Oracle，不注册其他业务、存储或 WebSocket 代理。完整原生业务迁移仍在进行中。

原生登录实现密码 bcrypt 校验（兼容 Nuxt 的72字节截断）、账号状态、受信设备与双因素挑战、Nuxt AES-GCM 密文和 TOTP/恢复码条件消费，并在会话落库后查询个人资料、最后设置 Cookie。需要的2FA表列先通过只读预检，缺失返回503；这尚未覆盖 Nuxt 的迁移账本、索引和约束全部检查。历史设备计数及站内新设备通知按用户和通知类型偏好持久化；实时消息推送和登录提醒邮件尚未实现。个人头像仅处理默认 `/storage` 路径，配置的自定义存储/CDN地址规范化仍缺失；资料日期按本机时区解释无时区 TIMESTAMP，数据库会话时区和跨机语义尚待真实 Oracle 验证。信任反向代理需显式 `TRUST_PROXY=true`；默认只记录连接对端地址，不采信转发头。Rust 自身未接入真实 Oracle、Redis、跨后端或两个客户端验收，本切片不得称为完整登录或完整后端。

## 原生 Token Codec 与会话撤销

`src/auth/tokens.rs` 提供独立 `TokenCodec::sign` / `verify`。签发使用 HS256，包含 Nuxt 的 `userId/userName/sessionId/type/iat/exp/jti`；调用方提供 Unix 秒时间与 session/jti。验签必须明确传入 access 或 refresh，分别选择对应密钥，只接受 HS256/384/512。`userId` 只接受正 JavaScript 安全整数（兼容数字字符串），sessionId/jti 必须是非空字符串。`verify` 的 `now` 参数用于零宽限时间验证：`exp <= now` 或 `nbf > now` 拒绝；不强制 exp 存在，也不拒绝未来 iat，以保持当前 Nuxt 库语义。

JWT 合法不代表数据库会话有效。native 模式的会话撤销 DELETE 每次验 access token 后 touch Oracle，核对用户、session、JTI、过期和撤销条件，成功才独立提交撤销。`{id}` 保留原始百分号编码；字面 `others` 撤销其他未撤销会话，包括到期会话。当前会话撤销成功才清两类 Cookie；数据库、提交或连接关闭错误返回安全错误，不授权后续撤销。会话列表及其他认证端点仍待实现。签名 key、Oracle/Redis 配置 Debug 脱敏，错误不携带 token、SQL 或底层连接细节。

公开退出接口优先使用 refresh Cookie 或正文，只有没有有效字符串形式的 refresh 凭据才选择 access Cookie 或严格 Bearer 头；非空但无效 refresh 不回退 access。通过签名验证后，SQL 同时匹配用户、会话、未撤销状态及当前 refresh hash 或 access jti；不读取其他会话、不要求数据库过期时间仍有效。无效、陈旧或不存在的凭据仍返回 `logout success` 并清理两个 Cookie。存储失败返回安全 500，提交结果可能未知；与并发刷新竞争时，如果刷新先完成，旧 refresh 的退出可能成功响应但不会撤销新凭据。真实 Oracle、跨端互通及两前端仍需验收。

刷新入口无需有效 access token，优先使用 refresh Cookie，否则读取 JSON 或 URL 编码正文。验签后以 session、user、旧 refresh hash、未撤销及未到期条件原子更新 Oracle，成功才返回新 token 和 Cookie；并发使用旧 token 只允许一次更新成功。`ACCESS_EXPIRES_IN`、`REFRESH_EXPIRES_IN` 默认为 900、2592000 秒，`NUXT_ACCESS_EXPIRES_IN` / `NUXT_REFRESH_EXPIRES_IN` 优先；原生模式要求正整数、refresh 严格大于 access 且不超过 2147483647 秒。仅 `COOKIE_SECURE=true` 设置 Secure。数据库提交或关闭失败、断连可能导致提交结果未知，不能自动重试旧 token。Nuxt 的异常 type、userId 和 TTL 校验更宽；两者未重新检查用户停用状态。Unix 秒精度签发与 Oracle TIMESTAMP 时区、真实 Oracle 和三后端互通仍需集中联测，详见 `contracts/requirements/auth-refresh.md`。

没有非空 refresh Cookie 时，原生刷新正文限制为 1 MiB；超限或解析失败按无凭据处理。Nuxt 当前正文没有相同限制。有非空 refresh Cookie 时无需读取正文。

`src/auth/session_repository.rs` 的生产实现复用 `OraclePool` 的 `spawn_blocking` 和命名参数执行，每次 touch/revoke 单独提交、显式关闭连接；不是一笔事务，也不保证撤回已获准的并发请求。native 启动需要 access/refresh keys 及显式 Oracle host/service/user/password，端口与池范围严格校验；不加载父目录 `.env`，不回退代理。监听前只读预检会话列，不创建或迁移 schema；优雅关闭等待 HTTP 请求结束。既有 OraclePool 是连接并发限制器，每次操作连接并关闭，pool_min 不代表预热或最少常驻连接。

native CORS 在鉴权前处理 OPTIONS，复用共同 origin、method/header、Vary、credentials 规则，含 Flutter 自定义头；会话撤销要求 access 凭据，刷新入口自行检查 refresh 凭据。`GET /api/health` 仅报告进程存活。原生错误直接使用 v2 envelope；Nuxt 外层差异见 `contracts/requirements/auth-session-revocation.md`。

`contracts/scenarios/auth-session-revocation.json` 的 29 个公开场景经真实 Axum HTTP/JWT 与隔离 session 存储验证，另测生产 SQL/bind 执行器、关闭错误、配置、CORS 与计数上游零调用；这些不是实际 Oracle 或完整 AUTH-S001..035 验收。未启动 Docker、实际应用、数据库或模型。真实 Oracle 19c/Free、多实例和双前端仍待集中验证。

本轮最终 WSL 默认测试共48项通过、2项真实 Oracle/Redis 连通测试忽略，`cargo build --locked -j 2` 和格式检查通过。证据见 `.codex-logs/session-native-all-green.log`、`session-final-build.log`；Cookie 引号与重复名称修复另有 `session-cookie-review-red.log` / `session-cookie-review-green.log`，重复 Cookie 字段修复见 `session-repeated-cookie-red.log` / `session-repeated-cookie-green.log`。

签名算法和 JWT 编解码使用精确锁定的 `jsonwebtoken =10.3.0`，禁用默认 PEM 功能，选择 `rust_crypto` provider；没有手写 HMAC 或 JWT 签名，也未在本模块实现密码哈希。官方来源：[Validation API](https://docs.rs/jsonwebtoken/10.3.0/jsonwebtoken/struct.Validation.html)、[decode 源码](https://github.com/Keats/jsonwebtoken/blob/v10.3.0/src/decoding.rs)、[provider 源码](https://github.com/Keats/jsonwebtoken/blob/v10.3.0/src/crypto/mod.rs)、[版本及 features](https://docs.rs/crate/jsonwebtoken/10.3.0/source/Cargo.toml)。库负责签名及算法白名单验证，时间 claim 由 codec 按注入时钟验证。

`contracts/scenarios/auth-tokens.json` revision 2 是 Nuxt 同一 25 项公开合成向量的工程内固定副本，测试只读取本工程文件，不 include 兄弟源码。`cargo test --locked --test auth_tokens_test -j 2` 包含 4 项测试函数，覆盖全部向量、签发回验及非法输入。Windows 首次构建因缺 MSVC `link.exe` 未执行断言；后续在既有 WSL Ubuntu 中使用工作区内独立安装的官方 Rust 1.95.0 实际执行通过。认证增量日志位于 `.codex-logs/20261027-rust-native-tokens.log`、`20261027-rust-unit.log`；最新全部默认测试结果见下节。未启动 Docker、应用服务或数据库，也未安装 Windows C++ 工具链；这不证明原生 Windows 编译或真实认证业务通过。数字字符串未完整实现 JavaScript Number 的 hex/boolean/array 宽转换，仍按共同需求审查。

## 模型配置组件

`src/ai/model_config.rs` 按 `contracts/requirements/ai-model-configuration.md` 实现严格校验、独立选择快照、RwLock 版本比较及原子替换；失败不安装部分配置。`contracts/scenarios/ai-model-config.json` 含三端相同的 52 个组件场景，另有并发、隔离和错误边界测试。Linux 默认测试共 31 项通过、2 个真实依赖连通测试忽略；日志为 `.codex-logs/20261027-model-config-52-full.log`。格式检查通过。

`src/ai/transport.rs` 已实现 OpenAI-compatible/Ollama JSON HTTP 传输、调用级密钥解析、超时/取消和安全错误，使用 loopback 提供方测试。配置与传输组件尚未接入应用 AI 路由，没有调用真实模型、能力探测、索引或完整产品流程。完整产品权限及切换验收见本地 `contracts/requirements/ai-product-scope.md`、`ai-model-switching.md`，不能以配置或传输组件通过宣称完整 AI 业务通过。

管理目录可执行 `node nuxt/scripts/parity.mjs check --workspace-root .` 核对公共需求/样例的 Rust/Go 副本；独立 Rust 编译和测试仍只读取本工程文件。

## 构建与验证

在本工程根目录运行：

```text
cargo fmt --all -- --check
cargo check --locked -j 2
cargo test --locked -j 2
cargo build --locked -j 2
```

Windows 需要 Rust MSVC 工具链及 Visual C++ 链接器。本次机器缺少 `link.exe`，原生 Windows check/test 未能通过；格式检查通过。当前源码的 Linux 默认测试结果见上文；真实 Oracle/Redis 测试的 ignored 不等于本轮已经验证。此前 Docker/独立克隆构建属于历史证据，不能替代本轮新代码验收。

真实 Oracle 连通还需要进程可加载的 Oracle Instant Client。只在显式配置的隔离测试服务上运行 `cargo test --locked -j 2 --test connectivity_test -- --ignored`。这两项测试只读取本工程根 `.env`，不会向父目录寻找配置。

## 配置与启动

参考 `env.example`，把所选变量注入启动进程；应用本身不自动加载 `.env`。PowerShell 示例：

```powershell
$env:HOST = '127.0.0.1'
$env:RUST_BACKEND_PORT = '30003'
$env:LEGACY_BACKEND_BASE_URL = 'http://127.0.0.1:30001'
cargo run --locked -j 2
```

Nuxt 上游不可用时，代理业务接口无法正常工作。Docker 内监听 8080，需按实际网络设置 `DOCKER_LEGACY_BACKEND_BASE_URL`；`docker build -t nekotribe-rust:local .` 仅构建本工程，不创建或初始化 Oracle、Redis、Nuxt。继承自旧混合分支的 Nuxt Compose 与发布工作流已经移除。

原生会话服务启动：在同一进程显式设置 `RUST_BACKEND_MODE=native`、与 Nuxt/Go 一致的对应 access/refresh key 及 Oracle 变量后运行同一 `cargo run`。需要可加载的 Oracle Instant Client；隔离单元/HTTP 测试不需要它。native 不读取 Docker/legacy 后备数据库地址，不注册 Nuxt fallback；未实现业务返回404。下列既有 Compose 与代理说明描述 compat 模式，不作为 native 部署或真实库验证证据。

本目录 `compose.yaml` 只定义 Rust 容器，构建上下文为本目录，不挂载或读取兄弟源码。未来需要实际部署时，可复制 `env.example` 为自行保管的配置文件，例如 `.env.deploy`，检查变量后执行：

```text
docker compose --env-file .env.deploy config --quiet
docker compose --env-file .env.deploy up -d --build
```

`RUST_PUBLISH_HOST` / `RUST_PUBLISH_PORT` 控制宿主机发布地址，默认 `127.0.0.1:30003`；容器固定监听 `0.0.0.0:8080`。`DOCKER_LEGACY_BACKEND_BASE_URL` 必须指向容器可访问的既有 Nuxt，默认通过 `host.docker.internal:30001` 访问宿主机；Nuxt 监听地址和防火墙也必须允许来自容器的连接。若使用已有 Docker 网络，请按实际网络配置服务地址及网络接入。Compose 的 `--env-file` 用于变量替换，仅 `environment` 列出的变量传入容器；当前代理启动不连接 Oracle/Redis，所以该文件没有数据库凭证传递或依赖服务定义，也不自动创建 schema。Nuxt 仍需自行配置其已有数据库、Redis 与上传存储。

历史 `.verification/docker-build.log` 已记录完整镜像构建结束（`Successfully built 42350cdba5fe`）；这是修改前的历史证据。本轮只做静态开发与格式检查，新增 Compose 和代理头过滤测试尚未执行，不能据此声称本轮镜像或联调已通过。

## HTTP、文件与实时通信边界

- compat 的规范内 v2 路由 OPTIONS 转发给 Nuxt；native 使用上述原生 CORS。规范外路径仍返回 404。
- 代理过滤标准逐跳头及 `Connection` 指定的头；上游 CORS 响应头与多条 `Set-Cookie` 保留。当前请求和响应仍整包缓冲，且 HTTP 客户端仍使用默认重定向策略；流式传输和重定向链上的 Cookie/CORS 行为尚未完成真实联调。
- 既有 SentimentFlow 非 OPTIONS 前缀例外暂时保留；该可选集成预检未覆盖，不表示已经联调。
- compat 的 `/storage/**`、`/uploads/**` 读取依赖 Nuxt 上游；native 返回404。Rust 自身不持有上传目录。
- 当前 Rust 没有 `/_ws` 路由。客户端必须单独配置 Nuxt 的公共 WebSocket 地址，或使用将 WebSocket 路由到 Nuxt 的统一入口；只改成 Rust 端口不能获得 WebSocket 支持。

## 规范与历史

编译期只读取 [contracts/v2.openapi.json](contracts/v2.openapi.json)，来源见 [manifest](contracts/manifest.json)。Nuxt `doc/` 是权威源；本工程持有固定版本副本，不需要兄弟目录源码即可构建运行。规范覆盖核对及同步由 T11–T13 单独推进。

目录拆分前的 `backend-rust/`、继承的 Nuxt 文件及历史迁移报告仍保存在提交 `ab45d491818ad6a3db3866adf2a2e136be80a49e` 的 Git 历史中。旧验收报告不代表本轮验证结果，后续原生业务迁移尚待实施。
