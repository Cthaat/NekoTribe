# NekoTribe Go 预留工作区

状态：**尚未开始实现**。此目录仅保留未来 Go 后端的 API 契约与边界说明，没有可运行服务、Go 模块或启动命令；当前不需要安装 Go SDK。

本工作区位于 `C:/Code/NekoTribe/go`，分支为 `codex/go`，与 Nuxt、Rust、Flutter 共用 `../nuxt/.git`。继承的 Nuxt 应用文件已从此分支移除，原历史仍保留在 Git 中。

## 契约来源

`contracts/v2.openapi.json` 是 `../nuxt/doc/v2.openapi.json` 的内容一致的 LF 规范化副本，尚不代表 Go 已实现其中任何接口。

- 来源仓库路径：`doc/v2.openapi.json`
- 来源规范提交：`4d9167e6ac3052b81a09353055eda38abe2773a7`
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
