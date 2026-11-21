# 双客户端同步登记

权威入口为 `parity.json`。保留 schemaVersion 1，`clientTrackingVersion:1` 表示本登记包含必需的客户端范围检查。旧清单缺失此字段必须显式迁移，不能默认为不需要客户端。

## 每次新增或修改功能

1. 审查当前需求、共同场景和原实现，更新功能 revision 及三后端 targetRevision。涉及两个客户端时也更新各自 targetRevision/tasks；检查器拒绝旧客户端版本。
2. 每个功能都必须有 `clientScope.state` 和非空 reason。required 必须登记两客户端；not-required 需要实质理由，不能隐藏任何客户端实现；unreviewed 必须有待审查 tasks，阻断最终验收。范围判断由工程审查负责，检查器不能证明某项业务确实没有 UI。
3. required 下 `clients.nuxtWeb`、`clients.flutter` 各有 state、targetRevision、非空 tasks、sourceFiles、testFiles、evidence。not-started/in-progress 是在途状态；implemented/accepted 均要求非空源码和测试。accepted 还需下述真实证据；其余状态禁止携带冒充验收的 evidence。
4. sourceFiles 对 Nuxt Web 使用 app/i18n 路径，Flutter 使用 lib；testFiles 对应 tests/e2e 与 test/integration_test。所有路径相对各工程根，不能指向兄弟工程、server 或私有文件。工作区检查验证文件存在及真实路径；单独克隆 Nuxt 时不会假称检查过 Flutter 源码。

```json
{
  "clientScope": {"state":"required","reason":"Both clients expose this user journey."},
  "clients": {
    "nuxtWeb": {"state":"in-progress","targetRevision":1,"tasks":["Implement and verify the full journey"],"sourceFiles":["app/pages/example.vue"],"testFiles":["tests/example.test.mjs"],"evidence":[]},
    "flutter": {"state":"not-started","targetRevision":1,"tasks":["Implement and verify the same journey"],"sourceFiles":[],"testFiles":[],"evidence":[]}
  }
}
```

示例用于解释登记结构，不是本项目已存在的 example 功能或通过凭据。真实入口参见 AI-KNOWLEDGE-WRITING 的两份客户端记录。

## 客户端验收证据

evidence 引用 Nuxt `specifications/evidence/` 下 JSON 文件，必须绑定：

- schemaVersion 1、featureId、当前 revision、client（nuxtWeb/flutter）、result passed。
- requirementsSha256、全部当前共同 scenarios 的 id/sha256、全部 sharedDependencies 的 path/sha256。
- sources 的 path/sha256 覆盖此客户端全部 sourceFiles 和 testFiles；原始字节绑定实际检出文件，源码或测试变化后凭据失效。
- backends 恰好包含 nuxt/rust/go 三行，每行记录 result passed、实际执行 command、backendReceipt。引用必须出现在同功能对应后端已经 accepted 的 evidence 中，其原生/独立、版本和哈希规则沿用后端检查。一个后端连通不能替代三行矩阵。

只有需求、三后端、适用的两个客户端和旧源码审查均具备匹配证据，整体 ready 才能为 true。unit/widget/API 替身测试只支持局部开发进展，不能填成真实客户端矩阵凭据。检查器不运行 receipt.command，也不认证手填日志；真实 runner、提交 SHA 绑定和 CI 仍需后续开发。

## 当前迁移状态与命令

使用下方检查命令的 clientTracking 和 clientPending 查看当前功能数、客户端登记和待审查范围。各功能的源码、测试与剩余任务见 parity.json，包括两端的通知单条读状态、删除和恢复。只在完成实际后端矩阵后填写 accepted 凭据。

从 Nuxt 根运行：

```powershell
node --test --test-reporter=spec tests/parity.test.mjs
node scripts/parity.mjs check --workspace-root ..
node scripts/contracts.mjs check --workspace-root ..
```

check 输出新增 clientTracking（范围统计/sourceScope）与 clientPending（功能:客户端/范围）。开发检查 exit 0 只表示登记一致；release 会拒绝任何待审查或未验收的功能。当前阶段仍静态开发，不启动 Docker 或真实数据库。
