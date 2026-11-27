# NekoTribe (nuxt) 文档总索引与职责边界

本仓库（`master` 分支）是 **NekoTribe** 的 Nuxt 4 全栈主项目，同时承载跨四端（Nuxt / Go / Rust / Flutter）共享的 OpenAPI 契约源文件、语言无关需求与场景基线。本索引旨在明确各文档目录及多工作区间的职责边界，区分现行有效规范、受代码强引用的保护资产与历史归档资料。

---

## 一、多目录与多工作区职责边界

| 位置 | 定位与职责 | 现状说明 |
| --- | --- | --- |
| [`../README.md`](../README.md) | **Nuxt 主仓库总入口** | 面向新用户/开发者的快速开始（Docker Compose、Release 预编译包、本地源码运行）、核心功能、常用环境变量、目录概览与开发检查命令。 |
| `docs/`（本目录） | **现行运维、架构与工程手册中心** | 存放现行有效的部署手册、启动安全基线、架构边界、数据库显式迁移规范、工作区恢复套件、AI 功能开发与维护指南；同时包含历史 `docs/plans/`（31 份）与 `docs/audits/`（112 份）。 |
| `../doc/` | **双轨目录：活跃 v2 契约源 + 历史早期文档归档** | **活跃核心**：`doc/v2.openapi.json`、`doc/runtime-addresses.md`、`doc/contracts.manifest.json` 为四栈唯一权威契约源；`doc/contract-patches/` 为 39 项字段审核与 PATCH 改造的审计留档。<br>**历史归档**：其余 35 个文件（含已标示归档横幅的 `doc/README.md` 及 20 份旧 `.md`、旧 SQL/JSON/图表/Word 文档）均为重组前遗留资料，不再作为现行开发或部署依据。 |
| `../specifications/` | **语言无关共同需求与一致性台账** | 跨三后端（Nuxt / Go / Rust）与双客户端（Nuxt Web / Flutter）的共同规范基线：含总览 3 份、`requirements/` 206 份（142 `.md` + 64 `.json`）、`scenarios/` 193 份、`evidence/` 3 份，总台账为 `parity.json`。 |
| 子目录 `README.md` | **特定工具或遗留自动化目录说明** | `scripts/benchmark/README.md` 为现行三后端对拍/压测指南；`config/versions/README.md` 与 `script/github/README.md` 为旧版微服务标签自动化遗留说明（已由 `.github/workflows/` 现行流程替代）。 |
| 父工作区 `../../README.md` 与 `../../docs/` | **四工作树并排父管理目录（仓库外部）** | 仅存在于四栈同父目录布局（如 `C:\Code\NekoTribe\`），独立克隆本仓库时不存在。存放跨四栈总交付清单（`docs/deployment/`）、AI 交接包（`docs/handoff/`）、Prometheus/Grafana 观测配置（`docs/observability/`）与早期总路线图。注意：父目录的 `docs/startup-safety.md` 与 `docs/contracts/runtime-addresses.md` 为早期快照，已落后于本仓库现行版本。 |
| 同级工作区 `../../{go,rust,flutter}/contracts/` | **跨端共享契约与规范的只读分发副本** | 由本仓库通过 `node scripts/contracts.mjs sync --workspace-root ..` 与 `node scripts/parity.mjs sync-shared --workspace-root ..` 显式同步；不在各自子分支另立标准。 |

---

## 二、现行有效文档导航

### 1. 入门与交接
- [项目主 README](../README.md) — Nuxt 4 全栈总览、Docker / Release / 本地源码快速开始、默认端口与核心配置。
- [多框架 AI 交接入口](handoff.md) — 说明父工作区 `../../docs/handoff/` 下的完整交接文档与最新增量状态入口（仅四工作树父布局可达）。

### 2. 部署、运行与启动安全
- [Windows / Linux 启动与部署手册](deployment.md) — 涵盖本地、混合、源码容器栈、外部依赖、独立 Go/Rust 容器、Flutter Web 静态部署、独立知识索引与更新器、公共网关切换、WebRTC 通话、Passkey/GitHub OAuth、观测入口日志与隔离测试资源。
- [Nuxt 启动与初始化安全基线](startup-safety.md) — `.env.example` 权威配置映射、`scripts/dev.*` / `scripts/start.*`、`scripts/init-db.mjs`（开发基线与 `--schema-only`）保护逻辑及可重复验证命令。

### 3. 架构与数据库治理
- [多框架接口边界与兼容规则](architecture/shared-api.md) — v2 单一规范入口、成功与错误响应封套、`PATCH /api/v2/posts/{id}` 兼容策略、服务/数据层边界及 SentimentFlow 退役说明。
- [Oracle 显式结构迁移规范](architecture/schema-migrations.md) — `server/database/schema-definition.mjs` 权威定义与 `scripts/migrate-db.mjs`（`--plan` / `--check` / `--apply`）不变量、权限及恢复边界。
- [四目录源码恢复设计](architecture/workspace-restore.md) — Git bundle 跨机器恢复机制与安全约束。

### 4. 工作区恢复套件（`docs/workspace-kit/`）
- [恢复套件入口说明](workspace-kit/kit-README.md) — Windows / Linux 源码恢复套件操作说明（配合 `restore-workspace.mjs`、`restore.cmd`、`restore.sh`）。
- [恢复套件生成的工作区 README 模板](workspace-kit/workspace-README.md) — 2026-10-26 快照模板，仅随历史恢复包分发；最新四端状态以父目录 `../../README.md` 与 [部署手册](deployment.md) 为准。

### 5. AI 功能配置与维护
- [AI 写作接口开发配置](ai-writing-development.md) — `AI_MODEL_CONFIG_FILE` / `AI_MODEL_CONFIG_JSON`、适配器声明与写作对话/个人提供方接口说明。
- [AI Skill 启用配置维护](ai-skill-maintenance.md) — `scripts/ai-skill-config-maintenance.mjs` 及 Go/Rust 原生 `skills` 子命令维护四项受控技能（`knowledge-answer`、`writing-draft`、`group-brief`、`moderation-advice`）。
- [平台规则版本维护](ai-terms-maintenance.md) — `scripts/ai-public-terms-maintenance.mjs` 对共享 Oracle 规则目录版本的发布与停用流程。

### 6. 跨栈契约、地址规范与一致性台账
- [地址、实时连接与文件约定](../doc/runtime-addresses.md) — 三后端与两客户端的 API/WS/媒体基址、JWT 有效期与 Redis URL 校验、CORS 白名单及本地/S3 存储规范。
- [OpenAPI v2 权威规范](../doc/v2.openapi.json) & [契约来源清单](../doc/contracts.manifest.json) — OpenAPI 3.0.1 定义及 SHA-256 / Git blob 校验清单。
- [三后端与双客户端共同需求及进度](../specifications/README.md) — `parity.json` 检查机制、变更登记、共享文件同步与验收证据边界。
- [双客户端同步登记规则](../specifications/client-tracking.md) — `clientScope` 与 `nuxtWeb` / `flutter` 客户端证据绑定规则。

### 7. 子目录说明
- [三后端对照评测与压测指南](../scripts/benchmark/README.md) — `scripts/benchmark/run.mjs` 的 `parity` 与 `benchmark` 模式用法。
- [服务版本配置说明（历史遗留）](../config/versions/README.md) — 旧微服务版本 JSON 说明（`app/pages/about.vue` 仍静态读取其中 3 个 JSON）。
- [标签自动化脚本说明（历史遗留）](../script/github/README.md) — 旧 `service-name/v1.0.0` 标签交互脚本说明（已被现行 `.github/workflows/` 替代）。

---

## 三、受代码 / 测试 / Docker / CI 强引用的受保护资产

以下路径被构建、运行时、测试套件、容器构建或 CI 工作流直接读取或校对哈希，**严禁擅自移动、重命名、删除或破坏其格式/行尾**：

| 保护路径 | 强引用来源 | 约束要求 |
| --- | --- | --- |
| `doc/v2.openapi.json`<br>`doc/runtime-addresses.md`<br>`doc/contracts.manifest.json` | `scripts/contracts.mjs`、`scripts/package-nuxt.mjs`、`scripts/package-native.mjs`、`tests/contracts.test.mjs`、`tests/contract-payloads.test.mjs`、`tests/contracts/null-schemas.test.mjs`、`tests/auth-session-revocation.test.mjs`、`tests/package-nuxt.test.mjs`、`tests/package-native.test.mjs`、`.github/workflows/ci-nuxt.yml` & `release.yml` | 必须保持 UTF-8 无 BOM 与 LF 行尾；SHA-256 与 Git blob 哈希锁定于 `doc/contracts.manifest.json`，改动须经 `contracts.mjs sync` 显式同步。 |
| `doc/contract-patches/*` | `doc/contract-patches/README.md`、`docs/audits/2026-10-25-contract-payloads/evidence.json` | 字段审核输入留档，非权威契约。 |
| `specifications/parity.json` | `scripts/parity.mjs`、`scripts/lib/parity.mjs`、`tests/parity.test.mjs` | 一致性台账，`sharedFiles` 与基线源码哈希受检。 |
| `specifications/requirements/**` | `nuxt.config.ts`、`Dockerfile`、`Dockerfile.knowledge-index`、`app/` 组件与工具、`server/services/` 与 `server/utils/`、`scripts/`（生成/校验/打包脚本）、`tests/` | 运行时与测试直接 `import` 或读取；`ai-public-terms-catalog.json` 与 `two-factor-schema-catalog.json` 等还受源哈希/跨端一致校验。 |
| `specifications/scenarios/**`<br>`specifications/evidence/**` | `scripts/benchmark/replay.mjs`、`scripts/lib/parity.mjs`、`scripts/` 向量生成脚本、大量 `tests/*.test.mjs` | 行为向量与验收证据；`evidence/` 下 JSON 按原始字节校验。 |
| `docs/audits/2026-10-25-contract-payloads/evidence.json` | `tests/contract-payloads.test.mjs:9` | 契约负载审核测试直接读取。 |
| `docs/audits/2026-09-10-t11-null-schema-repair.json` | `tests/contracts/null-schemas.test.mjs:11` | OpenAPI 空 schema 修复测试直接读取。 |
| `docs/ai-writing-development.md`<br>`docs/deployment.md`<br>`docs/startup-safety.md`<br>`docs/architecture/shared-api.md`<br>`docs/architecture/schema-migrations.md` | `.env.example:56`、`../README.md` 及跨工作区文档链接 | 公开引用路径，保持路径稳定。 |
| `data/neko_tribe-oracle-v2.sql`<br>`data/nekotribe-schema-only.sql` | `docker-compose.yml`、`docker-compose.local.yml`、`scripts/docker-init-db.sh`、`scripts/init-db.mjs`、`scripts/package-nuxt.mjs`、`tests/helpers/schema-fixture.mjs`、`tests/schema-migrations.test.mjs`、`tests/startup-safety.test.mjs` | **实际 Oracle 数据库基线位于 `data/`**（而非 `doc/neko_tribe-oracle-v2.sql`）。 |
| `config/versions/{Neko,oracle-server,shadcn-web}.json` | `app/pages/about.vue:15-17` | 前端「关于」页面静态导入。 |

---

## 四、历史规划、审计与归档文档

- **`docs/plans/`（31 份，2026-10-26 至 2026-11-03）**：包含 [三后端一致性总计划](plans/2026-10-26-native-backend-parity.md)、能力清单 `2026-10-26-backend-capability-inventory.json` 及各阶段功能设计计划，保留作为设计追溯依据。
- **`docs/audits/`（112 份，2026-09-08 至 2026-11-13）**：包含工作区重组/契约/运行时审计（如 [2026-10-26 运行记录](audits/2026-10-26-runtime-verification.md)、[2026-10-28 需求与进度总览](audits/2026-10-28-project-requirements-status.md)）及分切片实现检查点，以及受测试引用的两份 JSON 证据。
- **`../doc/` 历史归档文件（35 份）**：含已添加顶部归档横幅的 [doc/README.md](../doc/README.md) 与 20 份早期文档（v1 API / 迁移指南 / Apifox 文档 / 群聊与无感刷新实现报告 / 早期路线图 / BRD / PRD / 课程研究说明 / SentimentFlow v1 API 等），以及旧 SQL（含未跟随 `data/neko_tribe-oracle-v2.sql` 更新的 `doc/neko_tribe-oracle-v2.sql`）、旧 JSON 与静态图表资源。阅读时请以本索引第二部分所列现行文档为准。

---

## 五、常用校验命令

在 Nuxt 仓库根目录执行（与四栈同父目录并排布局时，可对支持 `--workspace-root` 的检查追加 `--workspace-root ..`）：

```sh
node scripts/contracts.mjs check
node scripts/parity.mjs check
yarn schema-catalog:check
yarn ai-terms:check
yarn test
```

> 说明：在独立子 worktree（路径非 `<workspaceRoot>/nuxt`）或单分支克隆环境下，`scripts/contracts.mjs`（第 195 行）与 `scripts/lib/parity.mjs`（第 396 行）会拒绝指向父目录的 `--workspace-root`，请省略该参数执行离线检查；`yarn ai-terms:check` 及部分跨工作树测试会读取同级目录 `../rust`、`../go`，无同级工作树时会报 `ENOENT`。
