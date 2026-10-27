# 2026-10-27 三端推理传输组件检查点

已实现同一需求的 Nuxt、Rust、Go 原生非流式 HTTP 库，分别调用选定的 Ollama 或 OpenAI 兼容提供方；Rust/Go 此组件不经过 Nuxt。模型名、服务地址、凭据引用来自内部配置快照，不绑定 Qwen 或某台机器。用途与权限要求沿用已确认的共同产品范围；本次没有新增公开业务端点。

## 代码与共同数据

- Nuxt：`server/services/ai/inference-transport.ts`，`AiInferenceTransport.infer(selection, input, signal?)`。
- Rust：`Rust` 分支提交 `a9bf548`，`src/ai/transport.rs`，`Transport::infer(snapshot, input, watchReceiver?)`；watch true 或丢弃 future 取消当前 I/O。
- Go：`codex/go` 分支提交 `7dbb8ad`，`internal/ai/transport.go`，`Transport.Infer(ctx, selection, requestJSON)`。
- 共同规范：`specifications/requirements/ai-inference-transport.md`；55 个合成样例 `scenarios/ai-inference-transport.json`，两端副本一致。生成器仅使用公开常量，不读取环境/运行数据；重生成字节完全一致，SHA-256 `901660788c884b230bfe39aae83fd6768910347ecc0a834bb91224757d8b66e1`。

支持文本历史、工具提议与结构化 JSON 请求；结果只返回统一文本/提议/结束原因/usage。限制能力、超时、取消、JSON 深度、Unicode、请求/响应大小；凭据只由服务端 resolver 按引用读取，错误使用固定安全 code。拒绝重定向、自动回退与请求重试，未声明工具不会成为执行权限。v1 共同提供方入口须支持 HTTP/1.1；不承诺仅 HTTP/2 或任意私有协议直接兼容。

## 验证

| 检查 | 本轮实际结果 | 证据 |
| --- | --- | --- |
| 三端共同样例 | 每端执行同样 55 项；实际 loopback HTTP 核对路径/头/body、归一化与拒绝行为 | 各端 `.codex-logs/ai-inference-transport-green.log`，Rust 同名全套日志 |
| Nuxt 传输回归 | 62 项通过（55 共同 + 7 组额外边界） | Nuxt `.codex-logs/ai-inference-transport-green.log` |
| Node 全套 | 306 通过、2 跳过、0 失败；另一个聚焦回归集合 184 通过 | `ai-inference-transport-full-tests.log`、`20261027-ai-transport-node-tests.log` |
| Nuxt 完整类型检查 | `yarn typecheck --dotenv .env.example` 通过，54.17s | `.codex-logs/20261027-ai-transport-typecheck.log` |
| Go | 完整 test/vet 通过；Linux amd64 无 CGO 交叉构建通过 | Go `.codex-logs/ai-inference-transport-retry-green.log`、`ai-inference-transport-vet.log`、`20261027-ai-transport-linux-build.log` |
| Rust | WSL 官方工具链全套 36 通过，2 个 Oracle/Redis 真实连接测试忽略；Windows 格式检查通过 | Rust `.codex-logs/ai-inference-transport-green.log` |
| 共同登记 | 166 features、162 operations、6 场景文件、12 公共文件，accepted:0、ready:false | Nuxt `.codex-logs/20261027-ai-transport-parity.json` |
| API 契约 | 四工程原 162 operations / 4281 schema 核对通过，无新增公开端点；release 门仍按预期拒绝未完成业务 | `.codex-logs/20261027-ai-transport-contracts.json`、`20261027-ai-transport-release.log` |

测试中临时监听 loopback、完成后关闭，没有启动 Docker、应用服务、数据库或真实模型。Linux Go 是交叉构建，不是另一台 Linux 机器的部署证明；Rust 在 WSL 编译运行，不是 Windows 原生链接/运行证明。

## 审查修复

独立规范与质量审查发现并以红绿回归修复：TS 结束原因数组被字符串强制转换、普通 JSON 的 toJSON 键误拒绝、BOM 被移除；TS Proxy 反射异常泄漏和稀疏数组异常键绕过；三端未配对 Unicode 代理项差异、Go 默认 HTML 转义带来的额外体积。

单次调用的协议重试也实核库行为：Rust 显式 `reqwest::retry::never()`；Go 自建 HTTP/1 transport、清除 GetBody。Go 真实连接回归证明旧实现会在复用连接零字节写入失败时重放 POST，修复后返回安全失败；另测 TLS 协商和全局 DefaultTransport 被替换。日志保留在各端 `.codex-logs`，未提交测试日志/私有配置。

## 尚未完成

这是传输库组件检查点，不是完整模型切换或 AI 产品验收。流式输出、工具结果回合、真实能力/模型/GPU 性能、管理配置入口、embedding/索引重建、检索与引用失效、三组产品和实际权限接线仍需继续。工具 arguments 和结构化 JSON 这里只验证对象形态，不完整验证任意 JSON Schema；业务层必须做类型/权限校验，不能直接执行模型提议或审核处置。

权限源码依据见 [AI 权限接线核对](2026-10-27-ai-authorization-sources.md)。Rust/Go 完整会话/业务接口仍未补齐；本组件不改变已有代理范围。旧 SentimentFlow API 退役、Oracle 19c、Windows 原生 Rust、真实跨机器与最终部署均未据此验收；旧源码恢复 ZIP 仍为历史快照。
