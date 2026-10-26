# 集中运行验收（进行中）

用户在 2026-10-26 明确授权自行下载 Docker 并继续测试，不再等待确认。本记录接续 2026-10-25 的静态交接；后者所列环境阻碍属于当时快照。

| 项目 | 本轮结果 | 证据 |
| --- | --- | --- |
| Docker Desktop | 官方安装包，Docker Inc Authenticode Valid；静默安装成功，引擎 29.9.2 | 父目录 `.codex-logs/docker-setup`，官方安装日志 |
| Compose | v5.6.1；两种主栈 HOST/PORT 展开验证通过 | `.codex-logs/20261026-compose-config.log` |
| Nuxt 类型检查 | 最后修复后退出 0 | `.codex-logs/20261026-final-typecheck.log` |
| Node 全量回归 | 139 项全部通过、0 失败、0 跳过，含真实 Compose、Linux 脚本容器和 5 项真实 Git 恢复保护检查 | `.codex-logs/20261026-final-with-restore.log` |
| Flutter | 134 项测试通过，analyze 无问题，Web 构建成功 | Flutter `.codex-logs/20261026-flutter-{test,analyze,web-build}.log` |
| 规范 | 162 operations / 149 明确 v2 路由 / 12 有限代理；原 39 项字段审核缺口为 0 | `node scripts/contracts.mjs check --workspace-root ..` |
| Nuxt Linux 镜像 | 干净依赖安装及生产构建通过；两次运行问题修复后均重新构建 | `.codex-logs/20261026-nuxt-{docker-build,docker-rebuild,cors-build}.log` |
| Rust Linux 镜像 | 独立源码和锁文件构建通过，含 Oracle Instant Client 19.31 | Rust `.codex-logs/20261026-rust-docker-build.log` |
| Rust 测试 | 22 项常规测试通过；原先 ignored 的 2 项 Oracle/Redis 测试另行真实执行通过 | Rust `.codex-logs/20261026-rust-{tests,connectivity}.log` |
| Oracle Free | 实际引擎 23.26.3.0.0；31 步迁移及 8 组真实状态/恢复检查通过 | `.codex-logs/20261026-schema-oracle-retry.log` |
| 完整开发基线 | 在独立 Free PDB 执行，仅测试副本调整 PDB 名；52 表、0 无效对象，31 项结构均 ready | `.codex-logs/20261026-free-baseline.log`、`20261026-baseline-schema-{check,apply}.log` |
| HTTP / WS | Nuxt 31001、Rust 31003 均通过登录、权限、帖子部分更新、文件、刷新退出、CORS、认证 WS ping/pong | `.codex-logs/20261026-runtime-final-{31001,31003}.log` |
| 单一网关 | 31005：Nuxt 页面 + Rust API/文件 + Nuxt WS，同源登录、媒体附加和认证实时连接通过 | `.codex-logs/20261026-gateway-rust-http.log` |
| 私信与通知 | 两个虚构账号经网关：HTTP 落库、WS 私信、WS 通知与收件箱一致；默认陌生人拒绝仍有效 | `.codex-logs/20261026-realtime-gateway.log` |
| 浏览器 | Nuxt 页面经 Rust 网关显示时间线；Flutter 真实登录并切换 Rust API、Nuxt WS 后读取同一批帖子 | `.codex-logs/20261026-nuxt-rust-gateway.png`、Flutter `.codex-logs/20261026-flutter-rust-feed.png` |
| Windows 生产构建 | `yarn build --dotenv .env.example` 退出 0，更新本机产物；没有将日常私有配置作为构建输入 | `.codex-logs/20261026-windows-production-build.log` |
| 干净源码构建 | 从 bundle 新恢复、Git 状态为空的 Nuxt 目录构建 Linux 镜像通过 | `.codex-logs/20261026-clean-bundle-build.log` |
| Windows 混合运行 | 本机生产 Node 31000 + Docker Oracle/Redis，认证、文件、刷新退出、WS 全流程通过 | `.codex-logs/20261026-hybrid-runtime-31000.log` |
| 干净源码运行 | bundle 镜像 31001 运行同样的完整流程通过 | `.codex-logs/20261026-hybrid-runtime-31001.log` |
| 多实例一致性 | Windows 发 HTTP 私信，Linux 实例经 Redis/WS 推送私信和通知；四入口读取相同文件 SHA-256 | `.codex-logs/20261026-realtime-cross-instance.log`、`20261026-shared-files.json` |
| 干净恢复 | Windows 四 worktree 与契约检查通过；Alpine Linux 新恢复后 36 项部署/启动检查通过 | `.workspace-exports/verification-20261026`、`.codex-logs/20261026-linux-clean-bundle.log` |

Flutter Web 构建报告 secure_storage_web 等依赖的 Wasm dry-run 警告；本次通过的是默认 JavaScript Web 构建，不声称 Wasm 通过。Windows 桌面版继续按用户选择暂缓 C++ 工具链。

安装后引擎中没有已有容器、镜像或卷；没有清理旧磁盘、导入旧开发库或修改保留数据。测试容器、网络和卷统一使用 `nekotribe-t16` 前缀；HTTP 仅发布 loopback。Oracle/Redis/上传分别使用新测试卷，没有挂载 `../data/oracle-data` 或 `../storage`。Redis 哨兵在重启后保留，Oracle 在停止/重新打开以及引擎恢复后仍保留基线与帖子，Nuxt 重建保留上传卷。测试账号只用于新库，不接触用户的实际账号。

Oracle 19c 官方镜像 `container-registry.oracle.com/database/enterprise:19.3.0.0` 匿名拉取返回 401；官方 Free lite 的 blob 存储重定向亦不可达。实际测试使用公开维护的 `gvenzl/oracle-free:23-slim`，平台 manifest SHA-256 为 `366fe85702d764d81a0272b72e94e629290c27aa72a47825fcc45701a0633dac`。通过宿主机直连下载并校验各层 digest 后导入引擎；不是伪造 Oracle 官方镜像来源。Linux 脚本用 Docker Hub 官方 `oraclelinux:9-slim` 并在本地增加测试预期标签，Rust 最终镜像仍实际使用其 Dockerfile 指定的 Oracle Registry 基础镜像。Free 的结果不替代 19c 兼容性，默认开发配置和仓库基线的 ORCLPDB1 没有因此替换。

真实迁移验证入口为 `scripts/verify-schema-oracle.mjs`。仅接受显式 `NEKO_ORACLE_TEST_DISPOSABLE=true`、`NEKO_ORACLE_TEST_USER=NEKO_T13_*`、`NEKO_ORACLE_TEST_PASSWORD` 与 `NEKO_ORACLE_TEST_CONNECT`，不读取应用 dotenv；连接后核对 schema 身份和零对象，再创建最小前置业务表及哨兵数据。脚本在该新测试 schema 内执行故障注入和结构修改，绝不能用于日常数据库。用户/schema provisioning 由测试容器管理员完成，脚本不自动提权或删除用户。

## 真实运行发现并修复

- Oracle 将 `TARGET_TYPE IS NOT NULL` 单独暴露为检查约束，原迁移器将它误判为额外限制。保留列 nullability 检查，仅接受该精确的冗余谓词；其他自定义限制仍拒绝。新增回归先失败再通过，在全新 schema 重跑真实 31 步通过。首次失败现场保留，没有通过重置数据库掩盖错误。
- Flutter 默认携带 `x-request-id`，原 CORS 白名单遗漏导致浏览器 OPTIONS 403。补上这一明确头名，保留精确来源/方法/头白名单；实际浏览器切换后 API 200、WS 连接和时间线恢复。Node HTTP 验证也改为使用真实 Flutter 请求头，不再用较窄的预检掩盖问题。

真实迁移检查包括：请求 readiness 只读拒绝、DDL 隐式提交后 session 锁仍互斥、故障步骤无成功记录且另一连接可恢复、重复运行不产生 DDL/DML、序列从保留 ID 续接、不覆盖管理员设置、旧审核谓词升级、后续结构/ledger 漂移拒绝。额外新建权限不足账号被自动审批拒绝后，改用本基线已有的 `NEKO_READONLY`，验证权限不足时拒绝且前后零对象，没有新增账号或授权来绕过拒绝；证据为 `20261026-oracle-lock-denied.log`。

Rust 保持已约定的业务兼容代理，不声称原生业务已补齐。它没有 `/_ws` 路由：直连 API 时 WS 单独指向 Nuxt；希望所有配置只填一个根地址时使用本次已实测的网关。Go 仍仅预留。

浏览器真实观察到 Flutter 经 Rust 入口 `GET notifications 401 → PATCH tokens/current 200 → GET notifications 200`，页面保持登录并展示通知。脱敏网络证据保存在 [flutter-refresh.json](2026-10-26-runtime/flutter-refresh.json)，不包含请求头、正文或 URL 查询参数。Nuxt 网关页面重新加载后也维持登录并显示已上传媒体。

干净源码构建的源 HEAD 单独核对为 `7d8ca0ab185893e1df23f4d29cb18f28c8d6d135`，源码 bundle SHA-256 为 `0cc8598ea3bd777babc5db60992589cf8fecddbe731a651f3bdc6d8eb29c2026`。BuildKit 因 Windows 副本的 owner 边界未自动捕获 Git 来源字段并发出警告，构建本身成功；不将该警告隐藏或表述成完整供应链证明。镜像标识另存 `20261026-image-ids.json`。

Windows 与容器共用的上传路径仅为新建 `.test-data/20261026-shared-storage`，内容由本轮测试卷复制而来；原测试卷仍保留，日常存储目录没有搬移。本机测试通过独立 dotenv 与明确的子进程环境覆盖连接地址，包含空 Redis URL/密码，不依赖调用者的全局数据库环境。

为其他机器提供校验哈希、核对四分支并恢复 worktree 的独立入口，见 [workspace-restore.md](../architecture/workspace-restore.md)。已有目标、损坏 bundle、路径越界、缺少分支和提交不符均在创建目标前拒绝；私有管理文件不复制。源码恢复套件的实际跨平台执行与完整系统部署验收分别记录，不能互相替代。

## 尚未验收

- Oracle 19c 版本与原开发数据升级/恢复：官方拉取需要账户授权，Free 不能替代。
- 另一台实际 Windows/Linux 机器及其网络、TLS、持久化与操作权限；本机 Linux 容器不能冒称跨机器完整验收。
- Flutter Windows 桌面工具链、移动设备、Wasm，以及未纳入本次核心流程的深层业务和 SentimentFlow 训练/模型流程。
- 恢复套件已打包并验证双平台入口，结果见 [交付记录](2026-10-26-workspace-delivery.md) 和套件 `verification.json`；这不替代另一台真实服务器。

本轮收尾已停止五个 `nekotribe-t16` 测试容器和本轮 Windows Node/Flutter 静态服务；容器最终状态保存在 `.codex-logs/20261026-test-final-states.log`，挂载清单保存在 `20261026-test-mounts.json`。未删除容器、镜像、卷或测试上传文件。Docker Desktop 已执行停止，后续状态查询无法连接；没有为核对而重新启动引擎。

日志和测试私有环境位于各工作区忽略的 `.codex-logs`；本文件只记录可核对结果，不提交密码、令牌或运行数据库。总目标保持进行中。
