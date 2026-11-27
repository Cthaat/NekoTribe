# Go 频道与私信实时接收

> **历史阶段审计记录（2026-11-13）**：本文记录原生 Go 实时通道接入初期的检查点；后续原生聊天/私信 HTTP 与 vNext 能力已陆续合入 `codex/go`。现行入口见 [Go 分支文档说明](../README.md) 与 [全项目文档总索引 (master)](https://github.com/Cthaat/NekoTribe/blob/master/docs/README.md)。

2026-11-13，Go 原生 `/_ws` 支持 `data.channelId` 频道加入及离开。Oracle 频道查询沿用 Nuxt 的群状态、成员状态与私密频道管理角色条件。加入及每次转发前核对权限。权限失效释放对应订阅，鉴权会话撤销关闭连接。私信只接受当前用户 Redis 频道的 `direct_message`，校验会话标识和消息标识，并保留原始 JSON。

Go 每连接最多登记 64 个频道。频道订阅使用独立 Redis Pub/Sub 连接，并计入同一 Redis 适配器的 1024 槽上限。该设计复用现有确认、断线和释放逻辑。高并发集中验收需确认 Redis 连接预算，并核对频道与通知独立断线时的状态反馈。频道队列上限 16，溢出关闭连接。

隔离回环测试覆盖无权加入、获权加入、频道不匹配、私信隔离及权限失效释放。Go 全量 test、vet 及四目录 parity 通过。当前阶段实现跨后端事件接收；Go 原生聊天及私信 HTTP 操作、提交后发布、本地分发、Rust 实现及真实 Oracle/Redis 验收仍待推进。共享契约维持第 4 版，accepted=0、ready=false。
