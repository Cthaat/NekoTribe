# 三后端共同需求与进度

这里是正在建立的语言无关需求基线。完整目标见 [开发计划](../docs/plans/2026-10-26-native-backend-parity.md)。Nuxt 是首次提炼业务的源码基准，Rust/Go 最终原生实现同一需求；本目录不把现有代理或占位算作完整后端。

## 当前范围

- `requirements/authentication.md`：16 项兼容需求、35 个待执行完整业务场景、7 项需统一修订的缺口。另有三端相同的25个token样例和29个会话撤销HTTP/JWT隔离场景；后者需求见 `auth-session-revocation.md`，不能代替真实Oracle或完整认证验收。
- `requirements/ai-product-scope.md`：三个已确认 AI 方向与角色权限；`ai-model-switching.md` 是完整切换要求；`ai-model-configuration.md` 和 `ai-inference-transport.md` 是已实现的配置/非流式传输组件。52 个配置样例和 55 个传输样例和 24 个工具历史样例已在三端隔离测试通过，后者使用合成 loopback 提供方；实际模型调用、产品权限接线及完整场景仍未验收。
- `parity.json`：165个登记项覆盖原162个规范操作及新增AI和公共存储地址工作；会话撤销与登录/双因素相关操作分别合为工作项，旧登记ID保存在 `supersedes`，不删除HTTP接口。282个server源码文件固定LF SHA-256，其他130个入口待分类/关联。13个旧情感分析操作标记退役；所有功能均未获得完整三后端业务验收。
- `requirements/auth-session-list.md`：三端会话列表行为及 16 条分页样例；隔离测试不代替真实 Oracle、时区与跨实例验收。
- `requirements/auth-otp-verification.md` 与 `auth-otp-creation.md`：验证码校验和邮件创建的共同规则与隔离场景；短信提供方、真实邮件及数据库联测仍需完成。
- `requirements/auth-registration.md`：三端注册、验证码门槛与 29 条隔离场景；真实 Oracle 触发器、并发注册和跨后端登录尚待验收。
- `requirements/ai-agent-runtime.md`：知识库、持久化上下文与 Skills 的三端共同目标，10 条验收场景尚未执行；框架尚未选定。
- `requirements/auth-password-reset.md`：三端密码重置的事务规则及 17 条隔离场景；旧密码并发登录、双因素挑战和已建立的实时连接仍需处理。
- `requirements/cache-shared-backends.md`：共享后端默认绕过两层 Nuxt 缓存；跨三后端可靠失效协议及真实环境验收仍待实现。
- `requirements/user-self-profile-update.md`：三端当前用户资料部分更新和 18 条隔离场景；真实 Oracle 日期、约束、事务和跨实例缓存待验收。
- `requirements/user-self-profile.md`：三端当前用户资料与 10 条隔离鉴权场景；真实共享数据和两客户端联调待验收。
- 检查器校验任务、版本、源码覆盖和证据链接，以及46份公共需求/样例在Rust/Go的固定副本。自动复制工具、真实业务场景runner、流水线及全量需求还原仍需继续实现，不宣称检查通过就会自动更新三种语言代码。

## 两种检查

在 Nuxt 根执行：

```text
node scripts/parity.mjs check
node scripts/parity.mjs release --workspace-root C:/Code/NekoTribe
```

`check` 是开发期完整性检查：检查命令退出 0 只表示登记结构有效；必须读取 `ready`、`accepted` 和 `pending`，不代表三套后端已完成。当前应返回 `ready:false`、`accepted:0`。`release` 额外拒绝所有未验收功能、未审查来源，因此当前应退出 1。命令只读文件，不联网、不启动服务、不读取 `.env`，也不会替你修改或重新固定源码哈希。

`--workspace-root` 用于核对验收记录所绑定的 Rust/Go 源码，必须是包含此 Nuxt 项目的管理目录。未验收状态下独立 Nuxt 克隆可以运行普通 `check`；有 Rust/Go `accepted` 记录时，缺少实际工程目录就拒绝核对，不跳过来源验证。将来发行仍需专用三分支测试检出流程。

该参数还核对 `sharedFiles` 的 Rust/Go 公共副本，返回 `sharedScope:workspace`；不传参数只核对 Nuxt 的公开源文件并返回 `Nuxt-only`。公共源只从物理 `specifications/requirements` / `scenarios` 读取，副本只从各组件物理 `contracts` 读取，符号链接不能绕到私有目录。变更共同文档/样例后，审核并显式更新 LF 哈希和两端副本；漏掉一个实现就会因旧副本失败。现阶段命令只读，不自动覆盖文件。

## 变更登记

1. 先还原或修订对应需求正文与场景。`unreviewed` 不能升为已完成；新增独有功能可建立不直接对应 HTTP 操作的功能条目。
2. 更新功能 `revision`，同时明确 Nuxt/Rust/Go 三份 `tasks` 及其 `targetRevision`；缺一个实现任务或仍指向旧版本都会拒绝。
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

检查器校验这些记录与当前文件的对应关系，**不认证手填记录的真实性，也不执行 HTTP/SQL/WS 场景**。真实记录必须来自受审查的测试执行流程，保存源码提交、命令/结果和必要的隔离环境证据；当前没有任何实际验收记录。单元测试中的临时假项目/记录仅测试检查器拒绝逻辑，不是 Nuxt/Rust/Go 业务通过证据。

规范副本一致性仍由 `node scripts/contracts.mjs check --workspace-root ..` 验证。它与本检查互补，二者都不替代最终真实业务和跨机器部署验收。
