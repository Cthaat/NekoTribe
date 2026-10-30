# NekoTribe Go 后端（原生业务开发中）

原生本地媒体上传、公开文件读取和删除路径已接入，仍需真实 Oracle、共享对象及私密附件权限验收。图片尺寸使用本地解析；音视频通过 `FFPROBE_PATH` 指定的程序或 PATH 中的 `ffprobe` 尝试提取时长和尺寸。探测失败时，标准 PCM WAV 可通过文件头补算时长，其他无法解析的元数据为空。Linux 使用可寻址文件句柄，Windows 使用管道；Windows PCM WAV 上传已隔离验证，更多格式仍需验证。S3 尚未实现，见 `contracts/requirements/storage-local-files.md` 和 `media-upload.md`。

AVIF 尺寸从最多 4 MiB 的文件前缀读取，按主图关联的 `ispe` 属性选择，遇到不支持或损坏的结构返回空值；多种属性关联和旋转等变换尚需更多真实样例验证。

原生 PATCH/PUT 帖子部分更新已接入，省略保留、明确空关系清空；行锁及全部关系写入在同一连接事务中完成，失败回滚。53 条共同请求向量及隔离事务/HTTP 检查通过，真实 Oracle、并发及双客户端仍待验收。规则见 `contracts/requirements/post-update.md`。

原生 `DELETE /api/v2/posts/{id}` 已按公共规则接入作者专属软删除、并发条件更新和安全错误；17 条共同输入在隔离路由中通过。不会物理删除帖子或媒体。真实 Oracle、触发器、缓存及客户端仍待验收，见 `contracts/requirements/post-delete.md`。

原生 `POST /api/v2/posts` 与 `POST /api/v2/posts/{id}/retweets` 已接入请求解析、引用可见性、帖子/关系事务、提交后通知及完整帖子响应；发帖不增加浏览量。80 条请求向量与 Nuxt 对照通过，另有事务、通知错误和 Redis 降级隔离测试。小数关系 ID 保留原值绑定，避免截断后关联到其他实体。真实 Oracle/Redis、跨后端和客户端仍待验收；非法 JSON 响应与请求体大小限制等已知框架差异见 `contracts/requirements/post-create-request.md`。

模型传输现支持工具提议与工具结果的多轮历史编码，24 个共同合成场景及本机回环测试覆盖两种适配器；这不执行工具，也不代表 Agent、真实模型或业务验收完成。详见 `contracts/requirements/ai-tool-history.md`。

原生 `POST /api/v2/posts/{id}/likes` 已接入点赞写入、可见性检查、首次点赞通知存储、完整通知及作者映射和 Redis 发布；重复点赞不重复通知。Redis 发布器与订阅端读取相同环境变量，通知关闭推送时仍按偏好存储。点赞、通知和推送不是单个事务，通知失败可能在点赞提交后返回错误，Redis 不可用时实时推送降级。当前只通过隔离驱动和发布替身测试，真实 Oracle 触发器、并发、Redis、客户端及跨后端联调仍待验收。

状态：已实现独立原生 HTTP 会话列表与撤销、令牌刷新、当前会话退出、密码登录、双因素挑战、验证码创建/校验及注册的开发中路径；还包括 token codec、模型配置及提供方传输组件。其余业务仍待实现，现有路径与 Nuxt 尚有差异，不能视作完整认证验收。

原生 `PATCH /api/v2/users/me` 已按共同规范接入资料部分更新，通过隔离路由与 SQL 绑定场景；真实 Oracle 和跨后端缓存仍待验收。

媒体结构只读检查已复用共享迁移目录，帖子详情与部分列表已有原生实现；真实数据库与完整业务验收仍待进行。

原生 `/_ws` 已接入通知事件订阅和心跳，连接时验证 access token、会话和浏览器来源，并在投递前再次检查会话。`REDIS_URL`、`REDIS_HOST`、`REDIS_PORT`、`REDIS_DB`、`REDIS_PASSWORD` 用于选择共享 Redis；TLS 可使用 `rediss://`。浏览器跨域来源必须列入 `CORS_ALLOWED_ORIGINS`，反向代理外部来源也应显式配置。该连接目前仅处理通知事件与心跳，群聊、私信、在线状态和真实 Redis/Oracle 联调尚未完成。

原生 `GET /api/v2/users/{id}` 已接入公开资料、关系和在线状态隐私；共同隔离场景通过，真实 Oracle、时区和客户端联调仍待验收。

原生 `GET /api/v2/users/me` 已复用会话验证、自身资料查询和公共头像地址映射；当前只经过合成场景及替身检查，实际 Oracle 视图、跨后端数据更新和两个客户端仍待联测。

密码重置已接入独立路由与 Oracle repository，复用现有 OTP 校验和 bcrypt。17 条合成场景及模拟数据库绑定检查不等于真实 Oracle 或跨后端验收；同一事务消费验证码、更新密码并撤销已存在的会话；旧密码并发登录、双因素挑战及已建立的实时连接仍需处理。

注册先检查已验证且未过期的注册验证码，再查重、插入用户并读取资料；INSERT 独立提交，后续资料读取失败仍可能保留用户。真实 Oracle 触发器、并发注册和跨后端登录仍需联测。

验证码邮件使用 `SMTP_HOST`、`SMTP_PORT`、`SMTP_USER` 和 `SMTP_PASS`，以隐式 TLS 验证服务器证书；`NUXT_SMTP_*` 变量优先。配置可以留空让服务启动，但邮件发送会失败。短信验证码当前返回 501。真实邮件服务器、Oracle 和跨后端流程仍需联测；登录提醒邮件另待实现。

## 当前构建与验证

使用 Go 1.26.9 以上；本轮 Windows 实测 Go 1.27.3，SDK 从 Go 官方下载页取得并核对官方 SHA-256，未修改系统 PATH。固定依赖 `github.com/golang-jwt/jwt/v5 v5.3.1`，采用其验签与签发 API；算法白名单、JSON Number 和时钟行为依据[固定版本源码](https://github.com/golang-jwt/jwt/blob/v5.3.1/parser_option.go)。Oracle 使用官方纯 Go `github.com/oracle/go-oracledb/v26 v26.4.0` 公共连接器与 database/sql，不需要 C++ 或 Oracle Instant Client；隔离测试不需要真实数据库。

```text
go mod download
go test ./...
go vet ./...
go build ./...
```

`internal/auth/tokens.go` 以分开的 access/refresh 密钥验证指定类型，支持 HS256 签发、HS256/384/512 验签。时间使用注入的整秒时钟，原始 exp/nbf 数值保留小数精度，避免库 NumericDate 默认截断差异；缺少 exp 和未来 iat 按 Nuxt 现有库语义处理。安全整数 userId、sessionId/jti 和脱敏错误有明确检查，密钥不通过格式化输出。

本地 `contracts/scenarios/auth-tokens.json` revision 2 为三后端相同的 25 个公开合成样例；测试只读取本工程副本。另有 `auth-session-revocation.json` 的 29 个实际 HTTP/JWT 场景，Oracle 边界替换为隔离存储；生产 repository 的命名绑定、独立提交及错误另由 database/sql 测试 driver 验证。未连接真实 Oracle，不表示完整认证或真实库已验收。Hex/boolean/array 等 JavaScript Number 宽转换仍属共同认证需求的规则审查范围，不声称已完整复刻。

## 独立会话服务

把 `env.example` 的变量显式注入进程，然后运行 `go run ./cmd/server`；进程不加载本地或父目录 `.env`。HOST 默认 `127.0.0.1`，`GO_BACKEND_PORT` 优先 `PORT`，默认 `30006`。两类签名 key 和 Oracle host/service/user/password 必须非空；端口与池范围严格校验。监听前执行只读 session 列预检，不创建或迁移数据。启动需要显式配置的真实 Oracle，隔离测试只使用 loopback HTTP 与测试存储。

`DELETE /api/v2/auth/sessions/{id}` 与 `/others` 每次先验 access token，再直接 touch Oracle 会话，成功后独立提交撤销。`id` 保留原始百分号编码，`others` 字面优先；当前会话撤销成功清两类 Cookie，随后请求被数据库拒绝。错误返回安全 v2 envelope；原生 CORS 先处理 OPTIONS，精确来源及 Flutter 头策略与共同规范一致。未实现路由、存储、WebSocket 均不代理 Nuxt。`GET /api/health` 仅表示进程存活。

`PATCH /api/v2/auth/tokens/current` 验证 refresh Cookie 或正文，并在同一条 Oracle 条件更新中轮换 access jti、refresh 哈希和期限；提交成功才返回新令牌及 Cookie。默认期限分别为 900 秒和 2592000 秒，可通过 `ACCESS_EXPIRES_IN`、`REFRESH_EXPIRES_IN` 配置（若设置了相应 `NUXT_` 前缀值则优先），生产 HTTPS 设置 `COOKIE_SECURE=true`。期限须为 1 至 2147483647 秒，且刷新期限必须长于访问期限；Go 在启动时拒绝无效配置，这是相对 Nuxt 的 AUTH-907 安全收紧。正文支持 JSON 与 URL 编码表单，限 1 MiB；非标准 JWT claim 的兼容差异见 `contracts/requirements/auth-refresh.md`。正常连接下隔离模拟验证了旧令牌重放和并发仅一次成功，真实 Oracle 的事务、驱动和跨后端互通仍需验证。提交或网络故障可能产生未知结果，不能假设旧令牌仍可用。

`DELETE /api/v2/auth/tokens/current` 是公开退出入口，优先使用 refresh Cookie 或正文；没有 refresh 时使用 access Cookie 或严格 Bearer 头。它依据当前 refresh 哈希或 access jti 对用户和会话执行单条条件撤销；无效或过时凭据不撤销会话，正常情况下仍清除两类 Cookie 并返回成功。该接口不校验数据库中的会话到期时间。刷新与旧凭据退出并发时，若刷新先提交，退出可能返回成功但不会撤销新令牌；提交故障也可能使数据库结果未知。此路径目前只验证隔离存储和模拟驱动，真实 Oracle 与多后端仍待联测。

`POST /api/v2/auth/tokens` 直接查询 Oracle 用户并校验 bcrypt（按 Nuxt 的 72 字节限制），生成 session 和完整令牌响应。启用双因素时支持可信设备、创建挑战、`POST /api/v2/auth/two-factor/challenges` 与 `/challenges/{id}` 完成 TOTP 或恢复码，以及 remember-me 设备；密钥使用当前必填 refresh secret 的 SHA-256 与 Nuxt AES-GCM 数据格式互通。挑战、恢复码和 session 更新独立提交，提交或后续步骤故障可能留下已消费凭据或已创建 session，不承诺事务回滚。profile 查询成功后才发送 Cookie。

登录和双因素挑战使用随 Go 可执行程序内嵌的共享 schema catalog，在同一数据库连接上只读检查当前 schema owner、可选迁移账本及其记录、两条序列、四张表的列和约束以及三个索引；密码通过后、挑战创建前及完成挑战读取密钥前都会检查，缺失或不兼容时返回 503。检查结果不缓存，也不自动迁移；检查连接和后续业务连接是独立会话。当前已通过共享模拟字典场景，但真实 Oracle 元数据及运行时表现仍待联测。新设备提醒会根据 `login_alerts` 和通知类型偏好持久化通知，但 Redis/WebSocket 推送和 SMTP 邮件尚未实现。IP 默认取连接地址；仅显式启用 `TRUST_PROXY`（`1/true/yes/on`）时读取 `X-Forwarded-For`，只应在可信反向代理后使用。设备裁剪按 Unicode 字符而非 JavaScript UTF-16 单元；登录资料的头像地址按 STORAGE_PUBLIC_BASE、BASE_URL 与 STORAGE_CDN_BASE_URL 映射；相同配置和常用路径有共同隔离样例，非标准 URL 与真实跨机文件读取仍待验证。请求正文上限 1 MiB 与 Nuxt 有差异。这些都是待补齐项，不表示业务等价或真实 Oracle 已通过。Nuxt 的 2FA 派生存在 access-secret/fallback 路径，而此原生模式要求 refresh secret 非空，故只覆盖该正常配置路径。

HTTP 设置头/读写/闲置超时，退出先停止 HTTP 再关闭数据库。`ORACLE_POOL_MAX` 限制 database/sql 打开连接数，`ORACLE_POOL_MIN` 设置最大闲置连接数，不承诺预热或最少常驻连接。touch 与 revoke 是两次提交，不能撤回已获准的并发请求；真实 Oracle 19c/Free、多实例与双前端验收仍待执行。

## 模型配置组件

`internal/ai/model_config.go` 按 `contracts/requirements/ai-model-configuration.md` 校验提供方/模型/用途绑定，返回独立选择快照；`Replace` 用版本比较和互斥锁原子发布，失败保留旧配置。模型名称自由配置，凭据仅引用环境变量名。`internal/ai/transport.go` 已实现 OpenAI-compatible/Ollama JSON HTTP 传输、调用级密钥解析、超时和取消及安全错误，使用 loopback 提供方验证；尚未注册到应用 AI 路由，也未调用真实模型、探测能力或重建索引。

`contracts/scenarios/ai-model-config.json` 的 52 个共享组件场景已通过，补充测试覆盖配置隔离和并发。`go test ./...`、`go vet ./...` 通过。产品权限和完整验收要求位于 `contracts/requirements/ai-product-scope.md`、`ai-model-switching.md`，相关产品场景仍为 not-run；不能把配置选择成功当作真实模型切换通过。

公共需求和场景副本由 Nuxt 的 `specifications/parity.json` 固定 LF SHA-256；在管理目录执行 `node nuxt/scripts/parity.mjs check --workspace-root .` 可检查 Rust/Go 是否遗漏最新副本。独立克隆的 Go 编译/测试只读取本工程，不需要兄弟源码。

本工作区位于 `C:/Code/NekoTribe/go`，分支为 `codex/go`，与 Nuxt、Rust、Flutter 共用 `../nuxt/.git`。继承的 Nuxt 应用文件已从此分支移除，原历史仍保留在 Git 中。

## 契约来源

`contracts/v2.openapi.json` 是 `../nuxt/doc/v2.openapi.json` 的内容一致的 LF 规范化副本。当前只实现上述会话撤销、刷新及退出切片，不能据契约副本声称其他接口已实现。

- 来源仓库路径：`doc/v2.openapi.json`
- OpenAPI：`3.0.1`；API 版本：`2.0.0`

当前契约版本、审计修订、LF SHA-256、Git blob 和来源提交以 `contracts/manifest.json` 为准。manifest 的 `differsFromCommittedSource` 明确区分工作树修订与已提交来源，不将未提交内容冒称为旧提交。`contracts/runtime-addresses.md` 同步记录地址、鉴权、实时连接、存储与数据隔离约定。更新时从 Nuxt 审核后的来源同步，不能在各语言工作区独立定义不兼容接口。

在 Nuxt 项目执行 `node scripts/contracts.mjs check` 可离线验证本项目，无需任何兄弟工作区；只有显式执行 `node scripts/contracts.mjs check --workspace-root C:/Code/NekoTribe` 才检查四目录副本。审核来源后用 `node scripts/contracts.mjs sync --workspace-root C:/Code/NekoTribe` 同步；sync 需要本地 Git，check 仅依赖 Node 内置模块，不访问网络或启动服务。

## 后续实现边界

- 后续 Go 实现需遵循统一 v2 API 的路径、认证与权限、请求响应结构、错误行为和数据语义；用同一套契约与集成用例验证兼容性。发现契约缺口先统一修订，不能把预留接口描述当作已实现行为。
- Nuxt、Rust 和未来 Go 可以面向同一业务数据模型，但运行实例、连接配置、凭证与测试环境必须明确隔离。集成测试使用独立数据库、schema 或专用测试数据，不向现有业务库写入测试数据。
- 数据库结构迁移须统一管理并协调执行，禁止多个后端在启动时各自修改共享 schema。上线切换和多实例写入策略需另行设计与验收。
- `../data/oracle-data`、`../storage`、`../SentimentFlow` 与 `../sentimentflow-models` 属于保留的运行/附属目录；本预留工作区不创建、复制、初始化或清理这些数据。将来需要访问时使用显式配置，并保持现有挂载路径。
- 不提交真实 `.env`、密钥、数据库文件或上传内容；不提供假服务、占位健康检查或未经验证的启动说明。
