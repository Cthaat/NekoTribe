# 三后端与双客户端共同需求及进度

这里是正在建立的语言无关需求基线。当前目标、已做内容与剩余工作先看 [需求与进度总览](../docs/audits/2026-10-28-project-requirements-status.md)，完整目标见 [开发计划](../docs/plans/2026-10-26-native-backend-parity.md)。Nuxt 是首次提炼业务的源码基准，Rust/Go 最终原生实现同一需求；本目录不把现有代理或占位算作完整后端。

## 当前范围

- `requirements/authentication.md`：16 项兼容需求、35 个待执行完整业务场景、7 项需统一修订的缺口。另有三端相同的25个token样例和29个会话撤销HTTP/JWT隔离场景；后者需求见 `auth-session-revocation.md`，不能代替真实Oracle或完整认证验收。
- `requirements/ai-product-scope.md`：三个已确认 AI 方向与角色权限；`ai-model-switching.md` 是完整切换要求；`ai-model-configuration.md` 和 `ai-inference-transport.md` 是已实现的配置/非流式传输组件。52 个配置样例和 55 个传输样例和 24 个工具历史样例已在三端隔离测试通过，后者使用合成 loopback 提供方；实际模型调用、产品权限接线及完整场景仍未验收。
- `parity.json`：当前 **147** 个登记项覆盖 **225** 个规范操作、**180** 份场景与 **399** 份共享文件（含 AI、WebRTC、投票/草稿/Markdown/链接预览与公共存储等扩展工作）；部分关联操作合为工作项，旧登记 ID 保存在 `supersedes`，不删除 HTTP 接口。`server/` 基线源码固定 LF SHA-256，`sourceAudits` 共 **136** 项（其中 **126** 项待审查 `unreviewed`）。13 个旧情感分析操作标记退役；所有功能均未获得完整业务验收。
- `clientTrackingVersion:1`：每个功能必须登记客户端范围。当前 `clientTracking` 中 **139** 项为 `required`（均已登记 `nuxtWeb` / `flutter` 任务与目标版本，双端验收均仍待完成）、**8** 项为 `notRequired`、**0** 项为 `unreviewed`；缺少适用客户端验收仍阻断最终发布，规则见 [双客户端同步登记](client-tracking.md)。
- `requirements/auth-session-list.md`：三端会话列表行为及 16 条分页样例；隔离测试不代替真实 Oracle、时区与跨实例验收。
- `requirements/auth-otp-verification.md` 与 `auth-otp-creation.md`：验证码校验和邮件创建的共同规则与隔离场景；短信提供方、真实邮件及数据库联测仍需完成。
- `requirements/auth-registration.md`：三端注册、验证码门槛与 29 条隔离场景；真实 Oracle 触发器、并发注册和跨后端登录尚待验收。
- `requirements/ai-agent-runtime.md`：知识库、持久化上下文与 Skills 的三端共同目标，10 条验收场景尚未执行；框架尚未选定。
- `requirements/auth-password-reset.md`：三端密码重置的事务规则及 17 条隔离场景；旧密码并发登录、双因素挑战和已建立的实时连接仍需处理。
- `requirements/post-detail.md`：帖子详情权限、附件及浏览量共同目标；三端均通过 22 条共同隔离样例，真实数据库及客户端联调待验收。
- `requirements/post-list.md`：公共、热门、个人、收藏、点赞及指定用户、标签、回复、转发列表的共同需求；Rust/Go 已接入相应原生路由并完成局部隔离测试，完整共同场景和真实数据库联测仍待完成。
- `requirements/post-create-reference.md`、`post-create-transaction.md` 与 `post-create-request.md`：发帖、回复、引用和转发的请求与事务要求；Rust/Go 均已接入原生请求、事务、提交后通知及完整响应，80 条请求向量在三端隔离测试通过。真实依赖及三端创建流程尚未通过共同验收。
- `requirements/media-upload.md` 与 `storage-local-files.md`：上传补偿、临时文件和本地路径/范围规则；Rust/Go 已接入公开读取、原生删除及开发中的上传路径；两端格式与元数据完整性、私密附件授权及真实依赖验收仍待完成。
- `requirements/post-update.md`：PATCH 与兼容 PUT 的共同部分更新、行锁及原子事务；53 条请求向量与三端隔离事务/HTTP 检查通过，真实 Oracle 及客户端仍待验收。两个操作合为 `POST-UPDATE` 工作项并保留原 ID。
- `requirements/post-delete.md`：三端所有者软删除、canonical 路径、并发条件写入及安全错误；17 条共同隔离场景通过，真实 Oracle、触发器及跨后端缓存仍待验收。
- `requirements/post-comments-list.md`、`post-comment-create.md`、`post-comment-delete.md`、`post-comment-like.md`：Rust/Go 已接入评论列表、创建、删除及点赞/取消点赞的原生路径；真实数据库、通知副作用及跨后端联调仍待验收。
- `requirements/tag-list.md`：标签搜索与热门标签的鉴权、分页及返回结构；三端共同隔离样例和原生仓储测试不代替真实数据库验收。
- `requirements/tag-analytics.md`：标签统计按当前查看者可见的未删除帖子计算；真实数据库的权限函数、聚合和并发仍需验收。
- `requirements/post-interactions.md`：三端共同点赞与收藏要求。Nuxt 已加入写入可见性检查；Rust/Go 已接入原生点赞/取消点赞、收藏/取消收藏，以及首次点赞通知存储和 Redis 发布。隔离验证不代替真实数据库、并发、推送失败和跨端验收。
- `requirements/notification-list.md`：三端通知列表鉴权、过滤、分页、作者和元数据共同规则；真实 Oracle、跨用户和客户端联调尚未验收。
- `requirements/notification-single-read.md`、`notification-batch-read.md`、`notification-delete-restore.md`：Rust/Go 已接入通知单条/批量已读、删除与恢复的原生路径；真实数据库与客户端仍待验收。
- `requirements/notification-events.md`：通知事件频道和消息格式；三端共享编码样例，Rust/Go 发布组件已接入通知读写及帖子/评论互动等路径，真实 Redis 与跨实例投递仍待验证。
- `requirements/notification-websocket.md`：通知连接认证、来源、心跳和用户专属订阅规则；Rust/Go 均已接入开发中实现，目前只覆盖通知与心跳，群聊、私信和在线状态仍属完整 WebSocket 的后续范围。
- `requirements/cache-shared-backends.md`：共享后端默认绕过两层 Nuxt 缓存；跨三后端可靠失效协议及真实环境验收仍待实现。
- `requirements/user-self-profile-update.md`：三端当前用户资料部分更新和 18 条隔离场景；真实 Oracle 日期、约束、事务和跨实例缓存待验收。
- `requirements/user-public-profile.md`：三端公开资料和 21 条隔离场景，真实 Oracle 在线状态、时区及双端联调待验收。
- `requirements/user-self-profile.md`：三端当前用户资料与 10 条隔离鉴权场景；真实共享数据和两客户端联调待验收。
- 2026-10-28 初期审计时登记了 97 份公共文件与 50 份场景文件；目前已扩展至 **399** 份 `sharedFiles` 与 **180** 份登记场景，当前数量以检查器实时输出为准，业务通过数见验收记录。

## 两种检查

在 Nuxt 根执行：

```text
node scripts/parity.mjs check
node scripts/parity.mjs release --workspace-root C:/Code/NekoTribe
```

`check` 验证登记结构。运行后读取 `ready`、`accepted` 和 `pending` 获取签收状态。RC7 曾提交 `revision: 2` 的三端服务就绪回执（保留于 `specifications/evidence/`），后续 vNext 将 `SERVICE-READINESS` 升至 `revision: 3`（当前状态 `implemented`、`evidence: []`），因此实时运行结果为 `ready: false`、`accepted: 0`。`release` 要求验证全部功能及来源审查，因此当前退出 1。两个命令均只读工作区文件。

`--workspace-root` 用于核对 Rust/Go/Flutter 实际文件，且检查器要求当前工作目录与 `resolve(workspaceRoot, 'nuxt')` 严格一致（若在独立分支克隆或派生子 worktree 中运行，请省略 `--workspace-root` 以执行 `Nuxt-only` 离线检查）。未验收状态下独立检出可运行普通 `check`，其 `clientTracking.sourceScope` 为 `Nuxt-only`；有 Rust/Go/Flutter `accepted` 记录时，缺少实际工程目录就拒绝核对，不跳过来源验证。将来发行仍需专用多分支测试检出流程。

该参数还核对 `sharedFiles` 登记的 Rust、Go 和 Flutter 副本，返回 `sharedScope:workspace`。不传参数时只核对 Nuxt 的公开源文件。公共源位于 `specifications/requirements` 或 `specifications/scenarios`，副本位于各独立工作树的 `contracts`。检查命令只读取文件。

## 同步已审核的共享文件

先在 Nuxt 更新需求或场景，在 `parity.json` 的 `sharedFiles` 登记相应副本。新登记可留待同步命令填入 `source.sha256`。在 Nuxt 根目录运行：

```text
node scripts/parity.mjs sync-shared --workspace-root .. --shared specifications/requirements/media-upload.md
node scripts/parity.mjs check --workspace-root ..
```

一次可重复传入多个 `--shared`。同步只发布指定文件的 LF 副本和 SHA-256。若副本与旧哈希和新源均不同，命令会在写入前停止，请先合并该工作树的本地修改。中断后已更新与待更新的副本可继续使用同一命令同步。若留下 `specifications/.parity-sync.lock`，确认持锁进程已结束后再移除锁。各实现、客户端任务、功能修订和验收记录仍按下节维护。

## 变更登记

1. 先还原或修订对应需求正文与场景。`unreviewed` 不能升为已完成；新增独有功能可建立不直接对应 HTTP 操作的功能条目。
2. 更新功能 `revision`，同时明确 Nuxt/Rust/Go 三份 `tasks` 及其 `targetRevision`；适用功能还要同步 clients.nuxtWeb / clients.flutter 的 tasks 和 targetRevision。缺一个实现任务或仍指向旧版本都会拒绝；新功能不能遗漏 clientScope。
3. 每个规范操作必须且只能归属一个功能。`sourceFiles` 记录 Nuxt 的来源，`implementations.<backend>.sourceFiles` 记录各实现应绑定的源码；全部 server 基线文件必须有功能归属或 `sourceAudits` 条目。
4. 修改源码后先审核需求差异，再显式更新 baseline；新增/删去源码、现有内容和规范变化都会被发现。baseline 的 SHA-256 使用 UTF-8 LF 规范化，避免 Git CRLF 转换造成假漂移；只清点 server 中的 JS/TS 变体、JSON 与 SQL，不读取环境/密钥文件。
5. 把语言无关场景写成含唯一 `id` 和非空 `cases` 的 JSON，并由功能的 `scenarios` 引用。JSON 结构登记并不自动执行业务断言；可执行 runner 是后续独立任务。完整请求、权限、数据库、Redis、文件/WS断言需在需求中定义，不能只列名称。
6. `sourceAudits` 的旧接口/任务/工具等入口只能在有理由时分类为 `feature`、`alias` 或 `diagnostic`；前两者必须关联真实功能 ID，并将该来源加入所引用功能的 `sourceFiles`，使对应验收记录必须覆盖它。诊断分类须经审查，不能用来静默删除产品能力。

## 验收记录边界

实现状态为 `not-started` / `in-progress` / `proxy` / `implemented` / `accepted`。最后一项需要已审查需求、实际场景文件，以及 `evidence` 引用的脱敏 JSON 记录。每个记录必须绑定：

- `schemaVersion:1`、`featureId`、需求 `revision`、`backend`、`result:passed`、`mode:native`。
- Nuxt 的 `nuxtDependency:self`；Rust/Go 的 `nuxtDependency:blocked`，由真实测试运行过程验证阻断，而非仅手填一个标志。
- `requirementsSha256`、全部场景的 `{id,sha256}`，以及实际实现源码 `{path,sha256}`。这些证据哈希是文件原始字节，绑定当次实际检出；Git 换行或源码更改后需重新核对/生成证据。
- 功能声明 `sharedDependencies` 时，凭据还必须包含 `dependencies` 数组，逐项记录相同依赖路径和文件原始字节的 `{path,sha256}`；目录更新后旧凭据不能继续通过。所声明依赖必须登记到共享文件清单并与其他后端副本一致。
- 源码证据必须覆盖实现声明的 `sourceFiles`，Nuxt 还必须覆盖功能声明的 `sourceFiles`。共享依赖与测试代码也需纳入实际测试记录，声明遗漏由需求/实现审查发现，不是检查器自动推导完整依赖图。

检查器核对记录与当前文件的对应关系。真实回执来自受审查的 HTTP／SQL／WebSocket 或部署测试，记录源码、命令、结果和必要的隔离环境。RC7 的三后端就绪回执位于 `specifications/evidence`。要求客户端覆盖的功能还需 Nuxt Web 和 Flutter 的匹配证据。

规范副本一致性仍由 `node scripts/contracts.mjs check --workspace-root ..` 验证。它与本检查互补，二者都不替代最终真实业务和跨机器部署验收。
