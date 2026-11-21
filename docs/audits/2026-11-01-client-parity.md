# H3：客户端同步登记检查点

2026-11-01。按已确认的双客户端/三后端同步要求，扩展现有 parity 检查器；不改变任何业务路由，不启动 Docker、数据库或模型，不生成真实验收凭据。

## 已实现

- 每个功能必须显式 clientScope，旧清单通过 clientTrackingVersion 1 迁移；新功能遗漏范围直接拒绝。未审查范围有 review tasks，并阻断整体 accepted/release。
- 需要 UI 的功能必须有 Nuxt Web、Flutter 两份任务；功能 revision 改变但只更新三后端时，旧客户端 targetRevision 也会报错。
- 验证客户端源码/测试路径和工作区文件，拒绝 server 冒充客户端、越界、重复、丢失文件或符号链接重定向；单独 Nuxt 检查明确标记 Nuxt-only。
- 客户端 accepted 绑定需求、所有共同场景、依赖、源码和测试的原始字节哈希，以及连接 nuxt/rust/go 的三行结果/命令和当前已通过原生后端 receipt 引用。源码/测试变化、漏组合、旧版本、旧场景/依赖、无后端验收或只手填 accepted 均拒绝。
- 复用相同的需求/场景/依赖证据检查，保留已有后端 native、Nuxt 阻断和源码覆盖规则。总体完成同时取决于两端与三后端，不能只凭三后端状态发布。

真实登记：155 个功能都有客户端范围。三个已确认 AI 产品 required，152 个旧功能 unreviewed，未把任何旧功能批量标为不需要客户端。知识/写作两客户端 in-progress，完整群运营和审核两客户端 not-started；所有实现 evidence 仍为空。局部 H2 通过记录不能转为整个 AI 产品 accepted。

## 验证

新增反例在旧检查器上先复现“缺少预期拒绝”和后端已通过却忽略客户端的错误；实现后发现一个临时项目用例遗漏 workspaceRoot 参数，修正测试调用。最终 **70 项检查器测试通过，0 失败，0 skipped**，包含既有40项后端检查回归和新增客户端反例/合成正例。

实际运行：

```powershell
node --test --test-reporter=spec tests/parity.test.mjs
node scripts/parity.mjs check --workspace-root ..
node scripts/parity.mjs check
node scripts/contracts.mjs check --workspace-root ..
```

开发检查通过：155 features、171 operations、58 scenarios、124 sharedFiles、131 sourceAudits；clientTracking 为 required=3 / notRequired=0 / unreviewed=152，clientPending=158（152范围审查+6客户端任务）。accepted=0、ready=false。单目录检查报告 Nuxt-only；工作区检查核对实际 Flutter 源码。contracts 保持158明确路由、12代理操作、schemaGaps=0。

检查器测试中的临时项目和 receipt 只验证门槛，不是业务验收。检查器不执行记录里的 command，不认证手填日志；真实多后端 runner、提交 SHA/CI 尚未实现。本轮仅修改 Node 检查器、测试、登记与说明；不需要重复编译 Rust/Go 或重跑未变化的 Flutter/Nuxt UI 套件。

## 接续任务

先从 AUTH-LOGIN 等基础业务逐项审查152个客户端范围，关联当前 Nuxt/Flutter 实际页面/API/测试，并明确缺口；不能凭目录存在就标 implemented。继续审查/拆分此前在途变更和跨分支提交同步，后续实现真实场景 runner/提交绑定。然后依完整主文档补齐原生业务与完整 AI 产品，不只围绕登记器增加规则。

规范入口：[双客户端同步登记](../../specifications/client-tracking.md)，设计与任务：[H3计划](../plans/2026-11-01-client-parity.md)。当前仍不启动真实依赖或做日常库迁移。
