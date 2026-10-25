# 2026-10-25 静态开发交接与最终测试清单

本轮执行范围：继续已批准的四工程整理，先静态开发，不启动 Docker/应用/浏览器，不安装 Windows C++ 工具链。项目总目标仍在进行，当前不宣称最终部署与业务验收完成。

## 已落地

| 工程/范围 | 本轮结果 | 代码提交 |
| --- | --- | --- |
| Nuxt 权威规范 | 148 个明确 v2 method/path 全覆盖；27 项缺漏补齐，12 个有限代理与 WebSocket 单列；修复 3 个 WS 悬空引用、79 个非法 null 类型 | `311f930` |
| 规范来源/同步 | LF、SHA-256/Git blob、已提交来源清单；本项目离线 check；显式 workspace sync/check | Nuxt `b530d91`，Rust `6954090`，Flutter `b4789ee`，Go `6f90c1c` |
| Nuxt 部署 | 本地 CMD、source/image/dependencies/external 四模式、独立 init-db、stop/status/logs、隔离测试模板、可选公共网关 | `64a3787` |
| Rust | 独立 app-only Compose、端口/上游说明、逐跳头与 Connection 提名头过滤修复、保留 CORS 和多 Cookie | `8a01a92` |
| Flutter | Windows/Linux Web 入口，默认 Nuxt 3000 + Web 30004，设置页覆盖优先级准确，跨机器配置与待验说明 | `641f6ce` |

四份规范的 SHA-256 均为 `78588fabac8e6c0c7077e4f4f838aa984e4ab1c3a0d94aa456de18cd83fd2b5d`，Git blob 为 `4c89ee26638998af98fd0c8bbf4f5caa621382ff`。来源为已提交的 `311f930b42dbbf2cfa64d5d858fab0be4c72739c`；每份清单的两项 source 文件均与该提交一致。39 个 operation 的 payload/upstream schema 仍未逐字段穷举，工具对此明确计数，不将拓扑检查当作完整 OpenAPI/业务验证器。

## 本轮证据

- 36 项纯 Node 检查通过，0 失败、0 跳过：部署参数与无副作用 plan、初始化保护、canonical 环境透传、契约故障回归、可移动运行入口等。日志：Nuxt `.codex-logs/20261025-static-node-tests.log`。
- 其中 79 个 nullable schema 执行 304 个值断言；该可选审计使用已安装的 Ajv 6，其余核心契约检查仅依赖 Node 内置模块。
- Nuxt-only 与四工程 check 均通过；161 operations = 148 明确 v2 + 12 有限代理 + 1 WS，3171 个 Schema Object 结构检查；2 个 catchall 不被虚算为业务覆盖。独立审查再次枚举源码 method/path，集合完全一致。
- 四份 Nuxt Compose 以 YAML 库成功解析，外部模式仅 app、网关模式仅 gateway，无固定全局 container_name；测试样例指向新实例名/命名卷和 `.test-data/storage`。这不代替 Compose 插值及容器验证。证据：`.codex-logs/20261025-static-compose.json`。
- Rust `cargo fmt --check`、离线 metadata 通过；metadata 工作区只包含本工程。新增头过滤测试未执行 Cargo 编译，等待最终 Linux/容器阶段。
- Flutter PS parser、Bash 语法、嵌入 Python 语法及 Windows 缺失依赖/非法地址失败路径检查通过；没有触发 SDK 缓存写入、应用或浏览器启动。
- Git fsck 退出 0，日志 `.codex-logs/20261025-git-fsck.log`。工作区结构仍为 `nuxt/master`、`rust/Rust`、`flutter/Flutter`、`go/codex/go`，旧 baseline 保留 detached。
- 两阶段独立静态审查已处理 external 配置校验与容器透传不一致、单独新库初始化入口，以及 WS 错误日志可能包含查询 token 的问题。

9 月记录的 Oracle、Nuxt 浏览器、Rust Linux、Flutter Web 测试仅是各历史提交证据。本轮新提交不能沿用其结果作为最新运行通过结论。Flutter SDK 需要写入工作区外缓存，当前未触发；Windows 桌面版按用户选择继续等待 C++ 工具链。

## 最终集中测试，尚未执行

1. **清洁克隆**：从最终提交或 bundle 分别建立 Nuxt/Rust/Flutter 克隆；不复用兄弟源码或旧 node_modules/target/.dart_tool/build。Nuxt typecheck/test/build，Rust fmt/check/test/build，Flutter pub get/analyze/test/Web build；分别保存完整命令、退出码和提交。
2. **Compose 与镜像**：用私有测试配置解析 source/image/external/gateway 及 Rust Compose；核对实际端口、服务集合、挂载、实例名和生效环境；新构建 Nuxt/Rust 镜像并运行，不用历史镜像顶替。
3. **数据隔离与保留**：只用独立测试 Oracle/Redis/上传目录；验证未初始化/残留库保护、显式空库初始化、已有库跳过；应用重建后数据保留，开发数据目标从未被测试写入。
4. **客户端与后端**：Nuxt Web、Flutter Web 对 Nuxt 与 Rust 入口分别验证登录/Cookie/Bearer、刷新轮换、旧 token 失效、退出、私有权限、帖子、通知、文件上传读取、聊天/实时和断线重连；核对允许/拒绝 CORS 来源和多 Cookie。
5. **公共网关**：切换 API 上游而保持 UI/WS/文件地址可用；HTTPS 终结、Secure Cookie、代理 Upgrade/Connection、日志不暴露握手 token；Rust 无原生 WS 时确实走 Nuxt。
6. **另一台机器**：记录 Windows 与独立 Linux 的具体系统、架构、依赖、端口、防火墙、首次配置、启动/停止/日志、重启与数据持久化。Linux 容器结果单列，不冒充 Linux 服务器部署结果。
7. **Git 和交付**：四目录分支唯一，来源提交/规范哈希一致，原引用/stash/备份仍可恢复；明确 Rust 代理、Go 预留、Windows 工具链与 39 个 schema 审计缺口。

运行命令及从 bundle 恢复四工程的步骤见 [部署手册](../deployment.md)。当前目标保持进行中，以上未测项不能勾选为完成。
