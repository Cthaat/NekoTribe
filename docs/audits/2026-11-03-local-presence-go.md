# Go 本地在线状态增量与空间清理后续

2026-11-03 用户要求先清理再继续。仅清理已确认的 Go 编译缓存，清理瞬间净增 6.44 GiB；恢复测试后 2026-11-03T10:45:23.1222996+08:00 实测可用 104.27 GiB。不同时间后台占用有变化，不能把全部差额都归因于测试。详见 [空间清理记录](../../../docs/audits/2026-11-03-storage-cleanup.md)。

## 已完成的 Go 局部增量

- 一个实例级 LocalPresenceEvents 同时接 HTTP presence 发布与本机已鉴权 WebSocket。先本地投递，再独立尝试原有远程发布；失败不重放业务请求。固定编码继续隐藏 last_seen_at，使用同一个 server_id，过滤本实例 presence 回声；不误丢本实例通知。
- 本地订阅立即建立，远程订阅异步尝试；报告 system_notification / realtime_status，local_presence 固定 true，remote_events 为 connecting/connected/unavailable。WS 严格验证控制帧类型、字段、用户、时钟和状态；经 Redis 输入的同类控制帧始终拒绝。私密通知继续仅来自当前用户远程源，绝不通过本地 presence 广播。
- 远程关闭/错误后报告 unavailable 并延迟 1 秒重试，期间本地流仍可用；每级队列 16、最多 1024 订阅，慢消费者关闭；停止、上下文取消和 hub 关闭释放资源。
- Go 生产入口共享同一个 hub，不改通知持久化/发布器。原纯远程 source 的鉴权/503 行为保留；新混合 source 才允许降级升级。握手、Origin、发送前与心跳会话核验继续保留，已撤销会话收不到本地事件。
- 实际 Redis 库的 Channel 会内部重连而掩盖断线；已改用 ReceiveTimeout 暴露第一次读失败，30 秒 ping 与 65 秒读期限负责失联检测，上下文取消主动关闭连接。这里只是代码与本地 RESP 测试服务器验证，不代表真实 Redis 网络/跨实例验收。

## 验证

- WebSocket 两个降级模式先因等不到状态帧失败，再通过；远程断线先复现“source did not close”，改后通过。红/绿日志在机器状态列明。
- Go test ./... 退出 0：2042 个通过事件（含子测试），其中顶级通过 381；失败 0。跳过 TestMediaUploadRealWAV，需要显式 NEKO_TEST_FFPROBE；另两个包没有测试文件。未变化的 auth/ai 可以使用 Go 测试缓存。
- go vet ./... 与定向 diff --check 退出 0。
- 四工作树 contracts/parity 检查通过，仍为 171 operations、0 schema gaps、4571 schemas；155 features、71 scenarios、151 sharedFiles、131 source audits、required17/unreviewed138，accepted0/readyfalse。

## 未完成与准确断点

这是 Go 局部开发检查点，不是跨框架功能完成。Rust 未实现本地包装器；两客户端未消费严格健康状态，Nuxt 旧 socket 身份守卫也待处理。local-presence.json 已在四树放置相同草案，Go 验证其中 statusCases；尚未登记场景/共享清单，当前 71/151 的通过不覆盖该草案。仍需共同规范、OpenAPI 控制帧、WS 功能修订/客户端范围与目标版本同步，然后执行相关 Rust/客户端回归。

继续Rust本地presence包装器、两客户端严格状态消费/身份失效与Nuxt旧socket守卫；登记共同需求/LOCAL-PRESENCE场景、WS客户端范围与OpenAPI控制帧。然后继续AUTH-901/905、资料输入、完整原生业务/AI及Windows/Linux多方式多机部署。

旧设置功能与全部长期目标保留。只进行静态开发和隔离测试，未启动真实依赖；未改分支、提交、数据或初始交接档案。机器状态为 [2026-11-03-local-presence-go-state.json](../../../docs/handoff/2026-11-03-local-presence-go-state.json)。
