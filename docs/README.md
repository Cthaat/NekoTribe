# NekoTribe · Rust 分支文档说明

本分支（`Rust`）聚焦 **NekoTribe Rust 原生后端**（Tokio + Axum）。为保持全项目文档单一事实源（SSOT），跨端共享的部署、架构、迁移规范与需求基线统一维护在 `master` 分支，本分支仅保留独立运行入口、自动同步的契约副本与专属阶段记录。

## 本分支文档构成

| 路径 | 定位与维护方式 |
| --- | --- |
| [`README.md`](../README.md) | **Rust 后端入口指南**：Docker Compose、Release 预编译包、本地源码运行（含 Oracle Instant Client 说明）、环境变量、目录结构与测试命令。 |
| [`contracts/`](../contracts/v2.openapi.json) | **只读共享契约副本（403 份）**：含 `v2.openapi.json`、`runtime-addresses.md`、`manifest.json` 与共享需求/场景。**严禁手工修改**，须在 `master`（`nuxt`）通过 `node scripts/contracts.mjs sync --workspace-root ..` 与 `node scripts/parity.mjs sync-shared --workspace-root ..` 显式同步。 |
| [`tests/fixtures/smtp/README.md`](../tests/fixtures/smtp/README.md) | **SMTP 测试夹具说明**：Rust 集成测试使用的本地/虚拟 SMTP 夹具说明。 |
| [`docs/audits/2026-11-13-rust-chat-socket.md`](audits/2026-11-13-rust-chat-socket.md) | **历史阶段审计记录**：记录 2026-11-13 原生 `/_ws` 频道与私信接收检查点，保留作历史追溯。 |

## 全项目共享文档中心（位于 `master` 分支）

- [全项目文档总索引](https://github.com/Cthaat/NekoTribe/blob/master/docs/README.md)
- [Windows / Linux 统一部署手册](https://github.com/Cthaat/NekoTribe/blob/master/docs/deployment.md)
- [多框架接口边界与兼容规则](https://github.com/Cthaat/NekoTribe/blob/master/docs/architecture/shared-api.md)
- [Oracle 显式结构迁移规范](https://github.com/Cthaat/NekoTribe/blob/master/docs/architecture/schema-migrations.md)
- [三后端与双客户端共同需求及进度台账](https://github.com/Cthaat/NekoTribe/blob/master/specifications/README.md)

## B0.1 实现状态

Rust 已接入共享 Redis 分级限流和会话提交后的登录提醒。离线验收使用 [共享向量](../contracts/scenarios/b0-1-rate-limit.json)、独立 Redis 和邮件 stub。真实三后端对拍待验收。

## 其他活跃分支文档入口

- `master`（Nuxt 4 全栈 & 文档契约中心）：[README](https://github.com/Cthaat/NekoTribe/blob/master/README.md) · [文档总索引](https://github.com/Cthaat/NekoTribe/blob/master/docs/README.md)
- `codex/go`（Go 原生后端）：[README](https://github.com/Cthaat/NekoTribe/blob/codex/go/README.md) · [分支文档说明](https://github.com/Cthaat/NekoTribe/blob/codex/go/docs/README.md)
- `Flutter`（跨端客户端）：[README](https://github.com/Cthaat/NekoTribe/blob/Flutter/README.md) · [分支文档说明](https://github.com/Cthaat/NekoTribe/blob/Flutter/docs/README.md)
