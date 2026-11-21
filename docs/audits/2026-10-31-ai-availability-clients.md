# AI 功能状态：Nuxt 与 Flutter 静态接入检查点

日期：2026-10-31。H2 的代码、隔离验证与共享登记已完成；不是三后端真实运行或模型验收。未启动 Docker/Oracle/Redis/模型，未执行迁移。

## 行为与范围

两个客户端使用现有已登录 GET `/api/v2/ai/availability`，严格解码 `knowledge` 和 `writing` 两个布尔值。分别显示读取中、已启用、未启用、读取失败；读取期间清除旧 enabled，未知/停用禁止发送和重新生成，页面与 controller/callback 都守卫。旧异步结果不能覆盖新状态，Flutter API provider 切换会重新读取。

状态只是技能配置快照，不表示模型健康或长期授权。服务端仍独立鉴权与复核。允许保留/编辑草稿、浏览恢复删除历史和刷新消息，不因状态刷新清输入、重复追加或自动生成。

Nuxt 的共享 controller/API/组件和 zh/cn/en 文案在前一工作段落盘，本轮完成 Flutter 及同步。Flutter 窄屏回归实际发现原 Row 状态栏在 320px 下水平和垂直溢出，改为 Wrap 后，中英文两用途都通过；没有通过隐藏文本或忽略异常绕过测试。

## 实现入口

| 工程 | 入口（相对工程根） |
| --- | --- |
| Nuxt | `app/api/v2/ai-availability.ts`、`app/api/v2/ai-{writing,knowledge}.ts`、`app/services/ai-writing-controller.ts`、`app/components/AiConversation.vue`、`i18n/locales/{zh,cn,en}.json` |
| Nuxt 测试 | `tests/ai-availability-client.test.mjs`、`ai-writing-client.test.mjs`、`ai-knowledge-client.test.mjs`、`ai-writing-api.test.mjs` |
| Flutter | `lib/core/constants/api_paths.dart`、`lib/features/ai/data/ai_writing_api.dart`、`lib/features/ai/presentation/ai_writing_screen.dart`、`lib/shared/providers/providers.dart`、`lib/shared/i18n/app_localizations.dart` |
| Flutter 测试 | `test/features/api_contract_test.dart`、`test/features/ai_writing_screen_test.dart` |

共同需求 `specifications/requirements/ai-skill-selection.md` 同步至 Rust/Go/Flutter 的 `contracts/requirements`。新增 `AI-AVAILABILITY-CLIENTS` / `ai-availability-client-vectors.json` 的 14 条解码向量，同步三份独立工程副本；Nuxt 和 Flutter 实际 API 测试读取该向量，Flutter 不依赖兄弟 Nuxt 目录。

受影响功能版本：AI-KNOWLEDGE-WRITING 40→41，AI-GROUP-AGENT 与 AI-MODERATION-AID 13→14，三后端 targetRevision 同步。后两项依赖共同技能需求，版本更新不代表这两个产品已经实现。保持 accepted=0。

## 实际验证

1. Flutter 最初缺少类型/API/provider，编译失败；补 API/provider 后为 51 通过、4 个预期页面行为失败；接 UI 后 55 通过。
2. 新增初始 loading、窄屏、过期 retry 回调后，先复现窄屏 overflow；修复后两个文件 **58 通过、0 失败**。
3. `flutter analyze --no-pub`：初次提示两个新增多行 if 缺大括号，修复后 **No issues found / exit 0**。
4. Nuxt 四个相关测试文件：**16 通过、0 失败、0 skipped**；共享 14 向量在该测试套件内部循环，不能另算 14 个测试文件或验收场景运行成功。
5. `node node_modules/nuxt/bin/nuxt.mjs typecheck`：exit 0。
6. contracts check：exit 0，171 operations，158 explicit routes，12 proxy operations，schemaGaps=0。
7. parity check：exit 0，155 features，58 scenarios，124 sharedFiles，131 sourceAudits，accepted=0，ready=false。此前的 ai-skill-selection 哈希失败已通过需求审查、显式副本与版本同步解决，没有全量重钉 baseline。

命令均在对应工程根执行：

```powershell
node --test --test-reporter=spec tests/ai-availability-client.test.mjs tests/ai-writing-client.test.mjs tests/ai-knowledge-client.test.mjs tests/ai-writing-api.test.mjs
node node_modules/nuxt/bin/nuxt.mjs typecheck
node scripts/contracts.mjs check --workspace-root ..
node scripts/parity.mjs check --workspace-root ..
```

```powershell
& 'C:\flutter\bin\flutter.bat' test --no-pub test/features/ai_writing_screen_test.dart test/features/api_contract_test.dart --reporter expanded
& 'C:\flutter\bin\flutter.bat' analyze --no-pub
```

Flutter 启动器之前在受限沙箱下无输出；使用工具允许的 SDK cache 写权限后正常运行，无须删除锁、升级 Flutter 或安装依赖。此前会话 94430 的取消不能当作测试结果，本页通过结果来自后续独立执行。

## 仍未验证与下一步

没有运行真实浏览器、真实三后端/六客户端组合、Oracle 配置发布、模型推理、Windows 桌面构建、跨机部署。本轮没有修改 Rust/Go 运行源码，因此没有重跑或重新编译其测试。静态场景通过不证明整体业务完整。

H1/H2 的局部工作已收好，继续 H3 中尚未完成的跨分支提交审查、客户端任务/证据治理，再按完整主文档的业务、群组/实时、知识与上下文、完整 Skills/Agent、群运营/审核、旧功能退役和最终部署路线推进。不要只围绕 availability 继续加无关测试来替代推进完整目标。
