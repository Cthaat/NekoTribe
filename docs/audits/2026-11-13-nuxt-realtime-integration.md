# Nuxt 实时路由接线与握手契约

2026-11-13，隔离验证。Nuxt 的 `server/routes/_ws.ts` 和 `server/utils/wsSession.ts` 已接入按连接管理的实时订阅和 Redis 适配器。已鉴权的连接先登记本地在线状态能力，异步建立远程订阅。欢迎帧后由本实例报告 `connecting`、`connected` 或 `unavailable`。远程连接失败与重连期间仍能接收合法本地在线状态。

- 握手前校验 Origin 和会话。无法确认会话时返回 401，拒绝来源时返回 403，实例满载时返回 503。握手错误使用 HTTP JSON 包装。升级后再次校验会话，登记时再次检查容量，发送前校验当前会话。
- 每实例最多登记 1024 个连接，每连接发送队列最多 16 帧。Nuxt 入站帧上限 64 KiB，出站帧上限 256 KiB，套接字缓冲上限 4 MiB。积压溢出关闭连接并释放订阅。Nuxt 保留已有聊天权限检查，每连接最多加入 64 个聊天频道。聊天及私信功能对齐另行跟踪。
- 私密通知按用户定向发送。仅当同实例远程通知或聊天帧与该连接已入队的本地帧指纹匹配时去重。匹配记录每连接最多 128 条，保留 60 秒。远程私密通知保留原始帧，在线状态只过滤本实例回声。
- 共享通知 WebSocket 需求修订为 4，四目录已同步 OpenAPI 及两份共享需求。三后端与两客户端仍登记为进行中。

79 项实时回归通过，包括使用真实 Node WebSocket 适配器、模拟 Oracle 和 Redis 的回环测试。94 项契约载荷及对齐登记测试通过。Nuxt typecheck、四目录 contracts check 和 parity check 通过。验证命令和日志见 [机器状态](../../../docs/handoff/2026-11-13-nuxt-realtime-integration-state.json)。

继续处理 Nuxt Web 与 Flutter 的状态解码、会话和端点切换隔离、恢复后的权威读取。Nuxt 聊天页有独立 WebSocket，需一并核对会话归属。真实 Oracle、Redis ACL/TLS、反向代理、跨实例和六种组合待集中验收。Docker 未启动，验收登记为 accepted=0、ready=false。
