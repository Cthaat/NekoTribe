# NekoTribe Rust 后端

原生公开媒体和头像已接入 `STORAGE_TYPE=s3`，支持上传、文件读取和删除。真实 S3、Oracle 及跨后端共享对象待统一验收。当前边界见 [媒体存储契约](contracts/requirements/media-upload.md)。

原生模式已接入本地公开文件读取、媒体上传和删除的开发中路径，规则见 `contracts/requirements/storage-local-files.md` 和 `media-upload.md`。图片尺寸可读取。音视频使用 `FFPROBE_PATH` 指定的工具，留空时从 PATH 查找。源码镜像从 Oracle Linux 仓库安装工具并执行 `ffprobe -version`。未读取到时长时标准 PCM WAV 可通过文件头补算，其余无法解析的元数据为空。Linux 使用可寻址文件句柄，Windows 使用上传暂存文件。原生构建、私密附件权限、跨后端存储及真实依赖仍待统一验收。

原生 PATCH/PUT 帖子部分更新已接入，省略保留、明确空关系清空；行锁及全部关系写入在同一连接事务中完成，失败回滚。53 条共同请求向量及隔离事务/HTTP 检查通过，真实 Oracle、并发及双客户端仍待验收。规则见 `contracts/requirements/post-update.md`。

原生 `DELETE /api/v2/posts/{id}` 已按公共规则接入作者专属软删除、并发条件更新和安全错误；17 条共同输入在隔离路由中通过。不会物理删除帖子或媒体。真实 Oracle、触发器、缓存及客户端仍待验收，见 `contracts/requirements/post-delete.md`。

原生 `POST /api/v2/posts` 和 `POST /api/v2/posts/{id}/retweets` 已接入请求解析、引用权限、单连接事务、媒体/标签/提及写入、提交后通知及完整帖子映射。最终读取不增加浏览量，原生路径不回退 Nuxt。80 条共同请求向量及事务、通知、响应错误边界已通过隔离测试；真实 Oracle、Redis、并发及双客户端仍待验收。通知或最终读取失败可能发生在帖子已提交之后，不得自动重试创建；非法 JSON 和 1 MiB 正文限制与 Nuxt 的差异见 `contracts/requirements/post-create-request.md`。

模型传输现支持工具提议与工具结果的多轮历史编码，24 个共同合成场景及本机回环测试覆盖两种适配器；这不执行工具，也不代表 Agent、真实模型或业务验收完成。详见 `contracts/requirements/ai-tool-history.md`。

原生 `POST /api/v2/posts/{id}/likes` 已接入点赞写入、可见性检查、首次点赞通知存储、完整通知及作者映射和 Redis 发布；重复点赞不重复通知。Redis 发布器按同一配置惰性连接，点赞与通知不是单个事务，通知错误可能在点赞提交后返回 500，Redis 失败时实时推送降级。当前仅通过隔离仓储与模拟 Redis 测试，真实 Oracle 触发器、并发、Redis、客户端和跨后端联调仍待验收。

本分支是独立 Rust 工程，默认原生启动并直接连接共享 Oracle、Redis 和媒体存储。旧 Nuxt 代理通过 `RUST_BACKEND_MODE=compat` 单独启用。两种模式的运行验收分别记录。

原生 `/_ws` 提供个人通知、共享在线状态事件订阅和心跳：连接时验证 access token、Oracle 会话与浏览器来源；投递前和定期检查会话，撤销或过期后断开。使用 `REDIS_URL`、`REDIS_HOST`、`REDIS_PORT`、`REDIS_DB`、`REDIS_PASSWORD` 配置共享 Redis，支持 `rediss://`；浏览器跨域来源和反向代理外部来源需显式加入 `CORS_ALLOWED_ORIGINS`。在线状态事件已通过隔离测试；连接、断线和心跳驱动的完整状态生命周期、群聊、私信、真实 Redis/Oracle 联调仍未完成。

原生 `PATCH /api/v2/users/me` 已按共同规范接入资料部分更新，通过隔离路由与 SQL 绑定场景；真实 Oracle 和跨后端缓存仍待验收。

媒体结构只读检查已复用共享迁移目录；帖子详情、部分列表和收藏等已有原生切片，真实 Oracle 与完整业务验收仍待进行。

原生 `GET /api/v2/users/{id}` 已接入公开资料、关系和在线状态隐私；共同隔离场景通过，真实 Oracle、时区和客户端联调仍待验收。

原生 `GET /api/v2/users` 和 `GET /api/v2/users/recommendations` 共用搜索、推荐与分页契约。真实 Oracle 和客户端联调待验收。

原生 `GET /api/v2/users/me` 已复用会话验证、自身资料查询和公共头像地址映射；当前只经过合成场景及替身检查，实际 Oracle 视图、跨后端数据更新和两个客户端仍待联测。

原生模式还接入密码重置，通过现有 OTP repository 校验验证码并使用绑定参数更新密码；17 条合成场景及模拟数据库检查不等于真实 Oracle 或跨后端验收。同一事务消费验证码、更新密码并撤销已存在的会话；旧密码并发登录、双因素挑战及已建立的实时连接仍需处理。

注册先检查已验证且未过期的注册验证码，再查重、插入用户并读取资料；INSERT 独立提交，后续资料读取失败仍可能保留用户。真实 Oracle 触发器、并发注册和跨后端登录仍需联测。

验证码邮件使用 `SMTP_HOST`、`SMTP_PORT`、`SMTP_USER` 和 `SMTP_PASS`，以隐式 TLS 验证服务器证书；`NUXT_SMTP_*` 变量优先。配置可以留空让服务启动，但邮件发送会失败。短信验证码当前返回 501。真实邮件服务器、Oracle 和跨后端流程仍需联测；登录提醒邮件另待实现。

原生登录实现密码 bcrypt 校验（兼容 Nuxt 的72字节截断）、账号状态、受信设备与双因素挑战、Nuxt AES-GCM 密文和 TOTP/恢复码条件消费，并在会话落库后查询个人资料、最后设置 Cookie。登录与挑战入口的每次 SELECT-only 双因素元数据检查都在一个连接内完成，按共同 catalog 对 schema owner、表列、约束、索引、序列和存在时的迁移账本/全部记录做校验；检查后的业务操作使用独立连接。账本不存在本身不阻止登录，与 Nuxt 的现状一致。元数据错误返回503；当前公共场景和采集器以隔离替身测试，真实 Oracle 行为与时区仍待验收。历史设备计数及站内新设备通知按用户和通知类型偏好持久化；实时消息推送和登录提醒邮件尚未实现。登录资料的头像地址按 STORAGE_PUBLIC_BASE、BASE_URL 与 STORAGE_CDN_BASE_URL 映射；相同配置和常用路径有共同隔离样例，非标准 URL 与真实跨机文件读取仍待验证；资料日期按本机时区解释无时区 TIMESTAMP，数据库会话时区和跨机语义尚待真实 Oracle 验证。信任反向代理需显式 `TRUST_PROXY=true`；默认只记录连接对端地址，不采信转发头。Rust 自身未接入真实 Oracle、Redis、跨后端或两个客户端验收，本切片不得称为完整登录或完整后端。

## 原生 Token Codec 与会话撤销

`src/auth/tokens.rs` 提供独立 `TokenCodec::sign` / `verify`。签发使用 HS256，包含 Nuxt 的 `userId/userName/sessionId/type/iat/exp/jti`；调用方提供 Unix 秒时间与 session/jti。验签必须明确传入 access 或 refresh，分别选择对应密钥，只接受 HS256/384/512。`userId` 只接受正 JavaScript 安全整数（兼容数字字符串），sessionId/jti 必须是非空字符串。`verify` 的 `now` 参数用于零宽限时间验证：`exp <= now` 或 `nbf > now` 拒绝；不强制 exp 存在，也不拒绝未来 iat，以保持当前 Nuxt 库语义。

JWT 合法不代表数据库会话有效。native 模式的会话撤销 DELETE 每次验 access token 后 touch Oracle，核对用户、session、JTI、过期和撤销条件，成功才独立提交撤销。`{id}` 保留原始百分号编码；字面 `others` 撤销其他未撤销会话，包括到期会话。当前会话撤销成功才清两类 Cookie；数据库、提交或连接关闭错误返回安全错误，不授权后续撤销。密码重置和其他认证端点仍待实现。签名 key、Oracle/Redis 配置 Debug 脱敏，错误不携带 token、SQL 或底层连接细节。

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

原生模式已接入 AI 会话创建、读取、用户消息追加及历史读取路由；使用既有登录会话认证，群及审核用途再次检查当前权限，响应禁止缓存。审核账号由 `MODERATION_ADMIN_ACCOUNTS` 与 `MODERATION_ALLOW_ALL` 配置，须与其他后端一致。当前隔离测试不能代替真实 Oracle、跨后端或客户端验收。

`src/ai/model_config.rs` 按 `contracts/requirements/ai-model-configuration.md` 实现严格校验、独立选择快照、RwLock 版本比较及原子替换；失败不安装部分配置。`contracts/scenarios/ai-model-config.json` 含三端相同的 52 个组件场景，另有并发、隔离和错误边界测试。Linux 默认测试共 31 项通过、2 个真实依赖连通测试忽略；日志为 `.codex-logs/20261027-model-config-52-full.log`。格式检查通过。

`src/ai/transport.rs` 已实现 OpenAI-compatible/Ollama JSON HTTP 传输、调用级密钥解析、超时/取消和安全错误，使用 loopback 提供方测试。native 的写作生成接口已接入该传输：设置 `AI_MODEL_CONFIG_JSON`，按配置中的 `apiKeyEnv` 名称单独注入密钥，配置变更后重启进程；空配置时生成接口不可用。现有 compat Compose 只提供 Nuxt 代理，并不配置 native 服务。尚未调用真实模型、完成能力探测、索引或完整产品流程；完整产品权限及切换验收见本地 `contracts/requirements/ai-product-scope.md`、`ai-model-switching.md`。

管理目录可执行 `node nuxt/scripts/parity.mjs check --workspace-root .` 核对公共需求/样例的 Rust/Go 副本；独立 Rust 编译和测试仍只读取本工程文件。

## 构建与验证

在本工程根目录运行：

```text
cargo fmt --all -- --check
cargo check --locked -j 2
cargo test --locked -j 2
cargo build --locked -j 2
```

Windows 上从源码原生构建时使用 Rust MSVC 工具链及 Visual C++ 链接器。Windows x64 发布包也可从 Linux 或 WSL 使用 LLVM-MinGW 交叉构建，详见 [交叉构建命令](../nuxt/docs/deployment.md#复制预编译后端到另一台机器)。该发布包已在 Windows 上通过离线配置检查，真实 Oracle/Redis 和业务流程仍待验收。Linux 默认测试结果见上文。

真实 Oracle 连通还需要进程可加载的 Oracle Instant Client。只在显式配置的隔离测试服务上运行 `cargo test --locked -j 2 --test connectivity_test -- --ignored`。这两项测试只读取本工程根 `.env`，不会向父目录寻找配置。

## 配置与启动

### Windows 或 Linux 直接运行

按 `env.example` 向进程注入 Oracle、Redis 和签名配置，安装进程可加载的 Oracle Instant Client，再运行 `cargo run --locked` 或预编译的 `nekotribe-backend`。服务默认监听 `127.0.0.1:30003`，使用 `HOST` 调整监听地址，`RUST_BACKEND_PORT` 优先于 `PORT`。原生启动在监听前只读检查 Oracle 结构。

在 Rust 工作树根目录可运行 `node scripts/start-native.mjs rust --env-file .env.rust`。追加 `--check` 只检查启动参数，传入 `--binary PATH` 可启动预编译程序。从同一目录运行 `node scripts/package-native.mjs rust --build --out native-rust-release` 可独立编译和打包。也可在四工作树的父目录通过 `nuxt/scripts/` 调用同一套工具。

从 `env.example` 准备本目录的私有 `.env.rust` 后，Windows 可双击 `start.cmd`，Linux 可运行 `sh start.sh`。追加 `--check` 可在启动前离线检查配置，追加 `--env-file PATH` 选择其他配置文件。进程环境仍然优先。

使用预编译发布包时，在包目录准备私有 `.env.rust`，然后运行 `node start-native.mjs --check` 和 `node start-native.mjs`。启动器会从同目录的清单读取平台和程序名。

共用 Oracle schema 由同一套显式迁移工具维护。可以在 Nuxt 部署包中执行迁移命令，Rust 原生模式的启动不依赖 Nuxt 进程。[Oracle 迁移命令](../nuxt/docs/deployment.md#nuxt-独立-node-部署包)

### Docker 部署

从 `env.example` 准备私有 `.env.rust`，把 Oracle 和 Redis 地址改为容器可访问的地址。执行 `docker compose --env-file .env.rust up -d --build`。也可显式选择 `-f compose.native.yaml`。默认宿主机发布在 `127.0.0.1:30003`，容器监听 `0.0.0.0:8080`。用 `RUST_PUBLISH_HOST` 和 `RUST_PUBLISH_PORT` 调整发布地址，用 `NEKO_STORAGE_SOURCE` 指定宿主机媒体目录。

若要保留旧 Nuxt 代理部署，使用 `docker compose -f compose.compat.yaml up -d --build`。通过 `DOCKER_LEGACY_BACKEND_BASE_URL` 指定容器可访问的 Nuxt 上游，默认是 `http://host.docker.internal:30001`。

历史 `.verification/docker-build.log` 已记录完整镜像构建结束（`Successfully built 42350cdba5fe`）；这是修改前的历史证据。本轮只做静态开发与格式检查，新增 Compose 和代理头过滤测试尚未执行，不能据此声称本轮镜像或联调已通过。

## HTTP、文件与实时通信边界

- compat 的规范内 v2 路由 OPTIONS 转发给 Nuxt；native 使用上述原生 CORS。规范外路径仍返回 404。
- 代理过滤标准逐跳头及 `Connection` 指定的头；上游 CORS 响应头与多条 `Set-Cookie` 保留。当前请求和响应仍整包缓冲，且 HTTP 客户端仍使用默认重定向策略；流式传输和重定向链上的 Cookie/CORS 行为尚未完成真实联调。
- 既有 SentimentFlow 非 OPTIONS 前缀例外暂时保留；该可选集成预检未覆盖，不表示已经联调。
- compat 的 `/storage/**`、`/uploads/**` 读取依赖 Nuxt 上游；native 的 `/storage/**` 按配置读取本地或 S3 的公开对象，私密附件仍待补齐。
- native 的 `/_ws` 提供通知、在线状态事件接收与心跳；群聊、私信和完整在线状态生命周期尚未完成。

## 规范与历史

编译期只读取 [contracts/v2.openapi.json](contracts/v2.openapi.json)，来源见 [manifest](contracts/manifest.json)。Nuxt `doc/` 是权威源；本工程持有固定版本副本，不需要兄弟目录源码即可构建运行。规范覆盖核对及同步由 T11–T13 单独推进。

目录拆分前的 `backend-rust/`、继承的 Nuxt 文件及历史迁移报告仍保存在提交 `ab45d491818ad6a3db3866adf2a2e136be80a49e` 的 Git 历史中。旧验收报告不代表本轮验证结果，后续原生业务迁移尚待实施。
