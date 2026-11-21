# H3：两个客户端的同步登记与验收门槛

用户已确认 Nuxt Web/Flutter 均连接任一后端，需求变更必须同步所有实现。本步是现有 parity 登记器的扩展；只静态开发和临时假项目测试，不启动真实依赖。完整业务与 AI 目标不缩减。

## 范围与约束

现有 schemaVersion 1 保留，新增必须的 `clientTrackingVersion: 1`。每个功能显式登记 `clientScope`：state 为 unreviewed/required/not-required，reason 非空。unreviewed 须有审查 tasks，开发检查允许但阻断最终验收；not-required 必须说明本功能为何无独立客户端行为，且禁止附带被忽略的客户端实现。不能为通过检查而批量标为不需要。

required 功能必须有且仅有 `clients.nuxtWeb` 与 `clients.flutter`，分别记录 state、targetRevision、tasks、sourceFiles、testFiles、evidence。状态只允许 not-started/in-progress/implemented/accepted；每次功能 revision 变更，三后端和两客户端 targetRevision 都必须更新。源码路径分别限定 app/i18n 与 lib，测试路径分别限定 tests/e2e 与 test/integration_test。禁止越界、反斜杠、server 源码冒充客户端、重复路径及实际工作区内符号链接逃逸；有工作区时核对文件存在。

implemented/accepted 均要求非空源码和测试登记。accepted 必须有版本匹配的 receipt：绑定需求、全部共同场景、全部 sharedDependencies、全部登记源码及测试的原始字节 SHA-256，并记录连接 Nuxt/Rust/Go 的三行结果、命令及已经登记通过的原生后端 receipt 引用。要求 --workspace-root 验证 Flutter 实际文件。缺任一组合、过期 receipt/源码/场景/依赖、缺少当前后端验收均拒绝；unit/widget 通过只能记局部进展。

整体 accepted/ready 同时取决于三后端、适用客户端和旧源码审查。检查器验证记录一致性，不执行任意元数据命令，也不能认证手填运行结果真实性；真实跨后端 runner、提交 SHA/CI 仍是后续工作。not-required 的理由须人工/工程审查，检查器不能自动证明业务无 UI。

## 实施顺序与验证

1. 先在 `tests/parity.test.mjs` 增加临时项目反例：范围缺失/未审查、客户端任务遗漏、版本落后、错误状态和路径、缺少测试、虚假 accepted、缺后端组合、哈希漂移；旧后端测试仍通过。
2. 扩展 `scripts/lib/parity.mjs`，复用原有路径/哈希与需求证据检查，保持后端逻辑和原始字节 receipt 语义。
3. 155 个现有功能逐项有客户端审查入口；先将三个已确认 AI 产品标 required 并登记实际入口/未实现任务，其他项明确待审查。H2 只有局部静态证据，AI-KNOWLEDGE-WRITING 保持 in-progress，其余两个 not-started。
4. 更新 specifications README 与交接状态，运行：

```powershell
node --test --test-reporter=spec tests/parity.test.mjs
node scripts/parity.mjs check --workspace-root ..
node scripts/contracts.mjs check --workspace-root ..
```

首次真实客户端完整验收尚未发生，不能产生业务 accepted receipt。本步不自动翻译代码、不把已有客户端实现状态批量改成完成、不自动提交此前在途改动。
