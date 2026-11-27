# Nuxt、Go 和 Rust 后端对照评测

从 Nuxt 工作树根目录运行，使用 Node.js 22 和项目锁定的依赖。评测场景与数据归一化规则见 [行为契约](../../specifications/requirements/backend-comparison.md)。

## 准备隔离数据

- 从同一份测试快照克隆三套独立 Oracle 应用 schema。使用一致的结构版本、初始行、应用配置和 AI 上游桩。每次正式比较都从这份快照恢复。评测会创建帖子、修改点赞和会话、发送聊天消息以及运行 AI 写作，在专用测试环境中运行。
- 每套快照配备能密码登录的测试账号、可读取的公开个人资料和账号已加入的聊天频道。将测试账号和密码通过 `accountEnv` 与 `passwordEnv` 引用的环境变量传入，将实际频道 ID 填入 `chatChannelId`。
- 为每套目标准备独立的 Redis 状态。使用同一台机器、相同资源限制和同等启动条件。AI 角色使用同一个兼容上游桩及相同模型配置，配置文件路径可通过 `AI_MODEL_CONFIG_FILE` 注入。
- 行为对照直接通过 Oracle 驱动执行只读 `SELECT` 核验。给每个 `oracle` 配置独立读取账号的环境变量，只授予对应克隆 schema 中 `n_auth_sessions`、`n_posts` 和 `n_post_likes` 的查询权限。读取账号须能解析这些表名，可由管理员在读取 schema 内预置私有同义词。应用写入账号用于后端进程。

## 运行

复制 [配置样例](config.example.json)，按测试环境设置 `targets.nuxt`、`targets.go` 和 `targets.rust`。配置文件只放端点、进程设置和环境变量名称。测试凭据通过环境变量注入，绝对路径可以用于配置和启动命令。按需选择一个模式。从行为对照转到基准时，先停止已有后端并恢复三套快照。

```sh
node scripts/benchmark/run.mjs parity --config path/to/backend-comparison.json --out .bench/parity
node scripts/benchmark/run.mjs benchmark --config path/to/backend-comparison.json --out .bench/benchmark
```

- `parity` 连接已启动的三套后端和对应的 Oracle 读取账号。它按共享用例顺序比较 HTTP 状态、归一化 JSON 和 Oracle 断言，也逐一比较三套后端的实际回执。`parity.json` 和 `parity.md` 记录差异位置、步骤状态、断言与清理结果。
- `benchmark` 从 `launch` 逐个启动并停止后端，Oracle 连接由后端进程负责。为每个目标配置空闲监听端点，使地址与启动环境的端口一致。使用构建好的 Nuxt `.output/server/index.mjs` 和 Go / Rust 可执行文件，`launch.cwd` 相对于命令执行目录。Windows 样例使用 Go / Rust 发布包的 `.exe`，Linux 使用相应的无扩展名可执行文件。在其他位置部署时调整 `command` 和 `cwd`。Rust 保持原生运行所需的 Oracle Instant Client 配置。`launch.env` 定义普通进程设置，`launch.envFrom` 将当前进程中的环境变量映射到后端。Nuxt 直启时保留样例的 `NUXT_` 配置名称。直接运行应用进程可采集其驻留内存。[Nuxt 部署](../../README.md) · [Go 部署](../../../go/README.md) · [Rust 部署](../../../rust/README.md)（后两项相对链接仅在四工作树并排父目录下有效）

## 读取结果

基准报告 `benchmark.json` 和 `benchmark.md` 包含动态、公开资料读取、发帖、点赞、会话刷新、聊天 WebSocket 广播和 AI 写作的样本数、成功数、错误数、清理错误数、成功吞吐及 P50/P95/P99。吞吐使用成功数除以测量阶段的墙钟时间，延迟分位数使用成功样本。HTTP 测到完整响应读取，聊天测到与 HTTP 发送匹配的 WebSocket 消息。准备和清理在测量阶段之外。准备失败的样本计入错误，清理错误单独计数。

启动时间从创建进程测到 `/api/ready` 成功。RSS 是进程驻留内存的采样最大值，单位为 MiB。缺少采样或后端未就绪时，Markdown 显示 `Unavailable` 并在有错误信息时标出原因。成功响应的完整归一化数据与基准原始精度见 JSON。报告只反映本次运行覆盖的测试夹具和场景。
