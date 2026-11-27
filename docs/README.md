# NekoTribe · Flutter 分支文档说明

本分支（`Flutter`）聚焦 **NekoTribe Flutter 跨端客户端**（Windows / Android / Web）。为保持全项目文档单一事实源（SSOT），跨端共享的部署、架构、后端规范与一致性台账统一维护在 `master` 分支，本分支仅保留独立构建/运行入口、自动同步的客户端契约副本与专属历史阶段记录。

## 本分支文档构成

| 路径 | 定位与维护方式 |
| --- | --- |
| [`README.md`](../README.md) | **Flutter 客户端入口指南**：Release 下载、Passkey 域名/指纹配置、Docker Web 预览、本地源码运行、Web 静态部署及各平台打包验收说明。 |
| [`contracts/`](../contracts/v2.openapi.json) | **只读共享契约副本（285 份）**：含 `v2.openapi.json`、`runtime-addresses.md`、`source.json` 与客户端相关共享需求/场景。**严禁手工修改**，须在 `master`（`nuxt`）通过 `node scripts/contracts.mjs sync --workspace-root ..` 与 `node scripts/parity.mjs sync-shared --workspace-root ..` 显式同步。 |

### 历史阶段记录与审计留档（`docs/`）

以下文件记录了早期迁移、单个切片实现或静态回归检查点，仅保留作历史追溯，不代表当前 `v2.0.0` / `vNext` 全貌：

- [2026-09-10 / 2026-10-25 T09 独立化迁移与启动器验证](t09-validation.md)
- [2026-11-02 会话清理完成凭据计划与检查点](2026-11-02-session-clear-plan.md)
- [2026-11-13 Flutter 活动聊天连接审计](audits/2026-11-13-flutter-chat-ownership.md)
- [2026-11-13 Flutter 实时通知与握手审计](audits/2026-11-13-flutter-realtime.md)

## 全项目共享文档中心（位于 `master` 分支）

- [全项目文档总索引](https://github.com/Cthaat/NekoTribe/blob/master/docs/README.md)
- [Windows / Linux 统一部署手册](https://github.com/Cthaat/NekoTribe/blob/master/docs/deployment.md)
- [双客户端同步登记规则](https://github.com/Cthaat/NekoTribe/blob/master/specifications/client-tracking.md)
- [三后端与双客户端共同需求及进度台账](https://github.com/Cthaat/NekoTribe/blob/master/specifications/README.md)

## 其他活跃分支文档入口

- `master`（Nuxt 4 全栈 & 文档契约中心）：[README](https://github.com/Cthaat/NekoTribe/blob/master/README.md) · [文档总索引](https://github.com/Cthaat/NekoTribe/blob/master/docs/README.md)
- `codex/go`（Go 原生后端）：[README](https://github.com/Cthaat/NekoTribe/blob/codex/go/README.md) · [分支文档说明](https://github.com/Cthaat/NekoTribe/blob/codex/go/docs/README.md)
- `Rust`（Rust 原生后端）：[README](https://github.com/Cthaat/NekoTribe/blob/Rust/README.md) · [分支文档说明](https://github.com/Cthaat/NekoTribe/blob/Rust/docs/README.md)
