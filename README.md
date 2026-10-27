# NekoTribe Go 后端（原生业务开发中）

状态：已建立独立 Go 模块和原生 token codec，尚未实现 HTTP 业务服务、完整登录/会话/数据库接线。不能把库测试通过当作完整后端可用，也没有占位健康服务或启动命令。

## 当前构建与验证

使用 Go 1.26 以上；本轮 Windows 实测 Go 1.27.3，SDK 从 Go 官方下载页取得并核对官方 SHA-256，未修改系统 PATH。固定依赖 `github.com/golang-jwt/jwt/v5 v5.3.1`，采用其验签与签发 API；算法白名单、JSON Number 和时钟行为依据[固定版本源码](https://github.com/golang-jwt/jwt/blob/v5.3.1/parser_option.go)。本模块不需要 C++、Oracle 客户端或运行数据库。

```text
go mod download
go test ./...
go vet ./...
go build ./...
```

`internal/auth/tokens.go` 以分开的 access/refresh 密钥验证指定类型，支持 HS256 签发、HS256/384/512 验签。时间使用注入的整秒时钟，原始 exp/nbf 数值保留小数精度，避免库 NumericDate 默认截断差异；缺少 exp 和未来 iat 按 Nuxt 现有库语义处理。安全整数 userId、sessionId/jti 和脱敏错误有明确检查，密钥不通过格式化输出。

本地 `contracts/scenarios/auth-tokens.json` revision 2 为三后端相同的 25 个公开合成样例；测试只读取本工程副本。Windows 包测试与 vet 已通过，另已用 Nuxt JWT 库核对 Go 签发的 access/refresh 格式；这不是实际 HTTP、会话撤销或数据库业务验收。JWT 签名有效后仍须核对真实数据库会话、过期、撤销及 refresh hash 轮换。Hex/boolean/array 等 JavaScript Number 宽转换仍属共同认证需求的规则审查范围，不声称已完整复刻。

## 模型配置组件

`internal/ai/model_config.go` 按 `contracts/requirements/ai-model-configuration.md` 校验提供方/模型/用途绑定，返回独立选择快照；`Replace` 用版本比较和互斥锁原子发布，失败保留旧配置。模型名称自由配置，凭据仅引用环境变量名；本组件不读取环境、不联网，也没有实现提供方 HTTP 适配器、模型能力探测、索引或完整 AI 接口。

`contracts/scenarios/ai-model-config.json` 的 52 个共享组件场景已通过，补充测试覆盖配置隔离和并发。`go test ./...`、`go vet ./...` 通过。产品权限和完整验收要求位于 `contracts/requirements/ai-product-scope.md`、`ai-model-switching.md`，相关产品场景仍为 not-run；不能把配置选择成功当作真实模型切换通过。

公共需求和场景副本由 Nuxt 的 `specifications/parity.json` 固定 LF SHA-256；在管理目录执行 `node nuxt/scripts/parity.mjs check --workspace-root .` 可检查 Rust/Go 是否遗漏最新副本。独立克隆的 Go 编译/测试只读取本工程，不需要兄弟源码。

本工作区位于 `C:/Code/NekoTribe/go`，分支为 `codex/go`，与 Nuxt、Rust、Flutter 共用 `../nuxt/.git`。继承的 Nuxt 应用文件已从此分支移除，原历史仍保留在 Git 中。

## 契约来源

`contracts/v2.openapi.json` 是 `../nuxt/doc/v2.openapi.json` 的内容一致的 LF 规范化副本，尚不代表 Go 已实现其中任何接口。

- 来源仓库路径：`doc/v2.openapi.json`
- 来源规范提交：`55e20c27303f14c5695e17d18c8f4b5307b8b754`
- 跨工作区 LF 文件 SHA-256：`a9f5f96b026cfd97a77299b0f69cd1260e4a64daf0f20b7924052370b33ec1f7`
- 本次契约快照 Git blob：`67cf285269fb84de9d0d6c4196b1f8d497dcd4eb`
- OpenAPI：`3.0.1`；API 版本：`2.0.0`

完整来源记录在 `contracts/manifest.json`，包括契约版本、审计修订、两个文件的 LF SHA-256、Git blob 和已提交来源。当前两个快照均与上述规范提交的 Git blob 完全一致，`differsFromCommittedSource=false`；该标记会在未来同步未提交来源时变为 true，不能把工作树修订冒称为旧提交的内容。`contracts/runtime-addresses.md` 同步记录地址、鉴权、实时连接、存储与数据隔离约定。更新时从 Nuxt 审核后的来源同步，不能在各语言工作区独立定义不兼容接口。

在 Nuxt 项目执行 `node scripts/contracts.mjs check` 可离线验证本项目，无需任何兄弟工作区；只有显式执行 `node scripts/contracts.mjs check --workspace-root C:/Code/NekoTribe` 才检查四目录副本。审核来源后用 `node scripts/contracts.mjs sync --workspace-root C:/Code/NekoTribe` 同步；sync 需要本地 Git，check 仅依赖 Node 内置模块，不访问网络或启动服务。

## 后续实现边界

- 后续 Go 实现需遵循统一 v2 API 的路径、认证与权限、请求响应结构、错误行为和数据语义；用同一套契约与集成用例验证兼容性。发现契约缺口先统一修订，不能把预留接口描述当作已实现行为。
- Nuxt、Rust 和未来 Go 可以面向同一业务数据模型，但运行实例、连接配置、凭证与测试环境必须明确隔离。集成测试使用独立数据库、schema 或专用测试数据，不向现有业务库写入测试数据。
- 数据库结构迁移须统一管理并协调执行，禁止多个后端在启动时各自修改共享 schema。上线切换和多实例写入策略需另行设计与验收。
- `../data/oracle-data`、`../storage`、`../SentimentFlow` 与 `../sentimentflow-models` 属于保留的运行/附属目录；本预留工作区不创建、复制、初始化或清理这些数据。将来需要访问时使用显式配置，并保持现有挂载路径。
- 不提交真实 `.env`、密钥、数据库文件或上传内容；不提供假服务、占位健康检查或未经验证的启动说明。
