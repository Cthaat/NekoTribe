# NekoTribe Go 后端（原生业务开发中）

状态：已实现独立原生 HTTP 会话撤销、令牌刷新、当前会话退出，以及密码登录和双因素挑战的开发中路径；还包括 token codec、模型配置及提供方传输组件。会话列表和其余业务仍待实现，登录路径与 Nuxt 尚有以下差异，不能视作完整认证验收。

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
