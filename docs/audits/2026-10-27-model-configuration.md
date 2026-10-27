# 2026-10-27 原生基础与模型配置检查点

用户已选择知识问答/写作、群运营 Agent、审核辅助全部纳入；首期使用公开帖子/评论/规则，模型可切换。权限为登录用户、目标群管理员、平台审核人员分别使用对应功能。本记录仅证明下列源码/组件验证，不证明完整后端或 AI 产品已实现。

## 原生认证基础

- Nuxt 共享向量提交 `26c2176`，Rust 原生 codec `f3c3b56`，Go 模块与 codec `631a9a2`。
- 三端持有相同 revision 2 的 25 个公开合成 token 样例。Node 对 access 使用实际 Nuxt middleware + JWT（Oracle 更新隔离），refresh 验证为 JWT 库；Go/Rust codec 使用对应库。测试没有真实账号/密钥/数据库。
- 已修复 Go NumericDate 小数秒截断与字符串首尾空白的兼容差异，新增三条样例先失败后通过。Node 25 项通过、Go 包测试/vet 通过，Rust WSL 4 项认证测试覆盖全部向量并通过。
- Go 签发的 access/refresh 经 Nuxt JWT 库核对字段、Unicode 名称、jti 和时间；证据 `.codex-logs/20261027-go-to-nuxt-tokens.json`。没有据此验证 Cookie、HTTP 登录、真实会话撤销或完整 JavaScript Number 宽转换。
- Windows 缺 MSVC linker；本轮 Rust 在现有 WSL Ubuntu 中使用工作区独立官方 Rust 1.95.0 编译，未安装 Windows C++、未改 shell PATH。最初 TLS 下载失败后用 rustup curl 后端完成；此项是构建工具，不是应用服务。

## 三端模型配置组件

| 检查 | 实际结果 | 证据 |
| --- | --- | --- |
| Nuxt 配置规则 | 52 个共同 JSON 场景 + 2 项稀疏 JS 数组回归通过 | `.codex-logs/20261027-ai-config-test.log` |
| Go 配置规则 | 同样 52 场景及隔离、并发、边界测试通过，vet/gofmt 通过 | Go `.codex-logs/20261027-model-config-test.log`、后续边界日志 |
| Rust 配置规则 | 同样 52 场景及额外测试通过；全套 31 通过，2 个真实依赖测试忽略 | Rust `.codex-logs/20261027-model-config-52-full.log` |
| TypeScript | 新模块严格单文件类型检查、Nuxt 完整 typecheck 通过 | `.codex-logs/20261027-ai-model-typecheck.log` |
| 公共规范 | workspace check 核对 10 份公开需求/样例在 Rust/Go 的 LF 哈希 | `.codex-logs/20261027-ai-configuration-check.json` |
| 旧入口 | 设置页源码取消旧面板导入/挂载，类型检查通过 | `app/pages/account/settings.vue`；尚未运行页面验收 |

三端各自实现角色选择、任意非空模型名称、提供方标识/地址、凭据引用、能力与 token 声明限制、独立快照及版本比较原子替换。替换失败保留旧配置，旧选择快照不随新配置改变。Go/Rust 同步保护并发，TypeScript 同步发布不可变对象。

规格审查发现 Unicode 空白和 DNS 尾随点长度差异，已统一并加入共享临界样例；质量审查发现 TS 稀疏数组可绕过 map 校验，新增真实红绿回归修复。URL 格式只做配置校验，不是 SSRF/网络权限证明。

本组件没有提供方 HTTP 实现、真实模型调用、实际能力探测、向量索引或 Agent 工具。adapter 仅为配置标识，能力/token 限制仅为声明。52 个样例是组件场景，不能冒充完整 MODEL-S001..008 已执行。

## 持续同步与限制

共同登记现有 162 操作和 4 个新增 AI 功能，166 项目前 `accepted:0`、`ready:false`；13 个旧 SentimentFlow 操作已改为退役任务，不能再依旧计划补写预测/训练服务。新 AI 产品权限及场景已登记，尚未执行业务验收。

公共副本检查既比较源哈希也比较 Rust/Go，要求需求/样例来自物理公开目录，符号链接不能跳转到组件私有文件。两个回归使用匹配哈希的隔离私有路径标记，证明拒绝发生在文件读取前。该工具目前只读检查，审核更新后仍需显式同步副本；没有自动生成三种语言业务代码。

旧面板源码停止挂载不等于整模块退役。旧组件、API 和部署配置仍有待统一处理；历史模型/数据未删除。没有启动 Docker、实际后端、模型或数据库；忽略的真实依赖测试不计为通过。原 Oracle 19c、另一台真实机器、完整三后端业务及新 AI 真实推理验收仍未完成。此前源码恢复 ZIP 是固定历史快照，未冒称包含这些新增提交。
