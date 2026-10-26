# 接口与数据库边界重构：静态验收记录

本记录接续当天的 static-handoff。用户追加授权可以修补需求、增补/拆分/合并接口并重构模块，目标为高内聚、低耦合、容易接手；仍先静态开发，不启动 Docker。

## 实现

1. **补齐 39 项字段审核**：27 个本地接口和 12 个固定 SentimentFlow 上游接口均补充请求、响应、参数、错误及源码依据。代理保留上游格式；本地上游三个 stub 如实标出。当前规范有 162 operations，其中 149 个明确 v2 路由、12 个有限代理及 1 个 WebSocket；4281 个 Schema Object 通过结构检查，待字段审核标记为 0。它不等于所有业务已完成运行验收。
2. **澄清部分更新**：新增 `PATCH /api/v2/posts/{id}`，旧 PUT 保留为 deprecated 兼容入口，两者复用完全相同的 handler。两前端 updatePost 改用 PATCH。省略字段保留、显式数组清空、鉴权和内容校验由原服务继续负责。
3. **明确 JSON 错误传输**：修正文档中把业务错误误写为 HTTP 顶层响应的问题；Nitro JSON 外壳的 data 承载 v2 错误，敏感异常可以省略 data。Nuxt 两个请求入口共用 Accept helper；Flutter 保留原默认协商并修正大小写判断，显式调用方 Accept 仍优先。
4. **单一 schema authority**：五个业务模块中的结构操作与全局种子抽到 `server/database`。默认离线计划；只有显式 check/apply 才连接，dotenv 路径可选，密码不进入 argv/日志。31 个步骤覆盖 5 类功能；基线补齐两步验证对象和媒体 description。请求只做只读 readiness，缺失/不兼容返回通用 503；正常业务 DML 保留。
5. **可恢复迁移**：session 锁跨 DDL 提交、步骤校验和与 ledger、已有序列和设置保留、约束先验证替代再移除旧定义、失败不登记成功并可重试。相同连接同功能只共享进行中的检查，完成立即丢弃，不缓存旧 ready 状态。
6. **部署接线**：源码/外部/镜像/依赖模式可显式运行一次性迁移容器；默认启动不迁移。runtime 包含迁移 CLI 与数据库模块，driver 支持源码和仅 `.output` 布局。文档要求目标 owner 和管理员明确授予 DBMS_LOCK 权限，未声称支持任意跨 owner 低权限登录。

设计入口：[shared-api.md](../architecture/shared-api.md)、[schema-migrations.md](../architecture/schema-migrations.md)、[部署手册](../deployment.md)。本次原始审计补丁保存在 doc/contract-patches，仅是历史来源材料，不可覆盖回权威规范。

## 本轮证据

| 检查 | 当前结果 | 证据 |
| --- | --- | --- |
| Nuxt 完整类型检查 | 退出 0 | `.codex-logs/20261025-refactor-typecheck.log` |
| Node 回归及 nullable 语义审计 | 132 项：130 通过、0 失败、2 项容器相关显式跳过 | `.codex-logs/20261025-refactor-node-tests.log` |
| 其中新静态边界测试 | 65 项通过 | `.codex-logs/20261025-final-static-new-tests.log` |
| 迁移 plan | offline-plan，5 features / 31 steps，无连接 | `.codex-logs/20261025-migration-plan.json` |
| 规范检查 | Nuxt-only / workspace 均通过；提交后重新同步来源 | `node scripts/contracts.mjs check [--workspace-root ..]` |
| 独立审查 | 字段组、代理快照、PATCH、迁移引擎及部署接线均完成；已处理发现的错误分支 | 源码、补丁 evidence 及对应回归 |

迁移测试从实际 SQL 基线解析元数据后执行检查/应用模拟，覆盖不重复 DDL、不覆盖设置、不重置序列、校验和漂移、锁权限、ledger 失败、约束中断恢复、选择测试 dotenv、output-only driver；readiness 另验证并发去重和后续漂移重查。这些是模拟器证据，不代替真实 Oracle。

过程中修复了旧 posts fixture 缺少新元数据导致的三个 503 回归，保留原有可见性、分页、会话断言，并新增真实处理链中的缺失媒体结构 503 负例。没有通过关闭 readiness 或跳过旧测试修复回归。

类型检查最初因缺少本地 vue-tsc 而临时获取不兼容工具；现明确锁定 vue-tsc 3.2.8、TypeScript 5.8.3，语义审计使用的 Ajv 6.12.6 也成为显式开发依赖。通用 fetch 选项改为 ofetch transport 类型，具体 v2 DTO 保留，解决全量 Nitro 类型递归过深；未放宽为 any 或关闭严格检查。工具缓存使用工作区 `.cache`，同时从 Docker 上下文排除。

## 尚未完成

- Docker 引擎/容器未启动。另尝试仅做 Compose 配置解析，但当前环境找不到 Docker CLI，因此该项仍未通过；纯 YAML 解析不替代 Compose 展开。
- 当前 Node 系统内存检查约 1.1 GiB 可用，未启动需要较大堆的新生产构建；类型检查成功不能代替生产构建。
- 本轮 Flutter 新增 9 个离线 adapter 用例尚未通过 SDK 执行；Flutter analyze/test/Web build 需在 SDK 可写环境集中完成，Windows 桌面工具链仍按用户选择暂缓。
- 新 Nuxt/Rust 镜像、真实 Oracle 权限/元数据/锁/隐式提交与中断恢复、旧库数据保留、真实两前端登录刷新/文件/实时、公共网关和另一台 Windows/Linux 部署均待最终测试。
- Rust 仍为依赖 Nuxt 的业务兼容代理，Go 仍预留。字段审核完成与路由存在不能证明原生后端或上游 stub 已实现业务。

项目总目标保持进行中，不能用本轮静态结果标为最终完成。
