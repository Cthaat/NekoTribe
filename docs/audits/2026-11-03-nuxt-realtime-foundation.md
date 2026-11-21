# Nuxt实时订阅基础组件检查点

2026-11-03 接续[原生presence检查点](2026-11-03-local-presence-native.md)。已实现连接级远程订阅控制器及独立ioredis适配器；**生产_ws.ts、wsSession和两个客户端均尚未接线**。这次不能声称Nuxt已完成新的降级握手或健康状态发送。

## 组件与边界

realtime-subscription.ts同步创建控制对象，异步连接和确认频道后才报告connected。错误/关闭/1.5秒超时报unavailable，至少1秒后建立新attempt；旧attempt及迟到promise不能恢复状态或派发消息。AbortController同时取消等待，close清定时器/连接。可控transport不依赖共享缓存的redisAvailable标志，避免缓存故障阻止订阅重试。

每连接目标为当前用户/presence/broadcast/system，以及有界聊天频道集合。早到消息最多16条，确认前不派发；溢出丢弃失败attempt并降级。聊天增删串行确认，离开后立即过滤旧频道；当前组件上限64频道尚未影响产品，接线前须评审统一约束。状态回调中修改频道会在本轮结束后继续协调；关闭后排队的connect不会再执行。

代理输入只能来自当前目标频道，不能生成realtime_status控制帧；presence按共同向量校验白名单、hidden/null、实例和安全时钟，只去除本实例presence回声。其他实例presence及同server_id但尚未本地发送的通知保留；合法私密通知按原始字符串派发，包括未配对UTF-16。组件不向其他用户广播通知。

realtime-redis.ts使用现有配置解析，关闭离线队列、重试、自动重订阅和未完成命令重发，使用lazyConnect与1.5秒连接/命令界限；30秒ping报告链路失败，close移除消息/关闭回调并停心跳，迟到error保持安全no-op。没有打印原始异常、凭据或消息。这里只验证了假客户端下的配置透传和生命周期；实际rediss/TLS解析、网络检测和ACL并未证明。

## 验证

基础组件17项，包括先失败的状态/重试、两个异步竞态和适配器行为。连同现有通知、presence、旧路由、会话及契约/登记10文件共160项通过，0失败/取消/跳过；Nuxt类型检查退出0。旧路由仍按旧语义测试，只能证明本次未接线组件没有改旧行为，不构成新能力路由验收。

四树contracts/parity通过，OpenAPI未改：171 operations、0 gaps、4582 schemas，SHA256 e1c30f5422c584de5c21f427f5ee02e1fd13f5277702fab3ad521b8fa73f80dd。155 features、72 scenarios、153 sharedFiles、133 sourceAudits，required18/unreviewed137，accepted0/readyfalse。新增两个服务端source已登记为WS in-progress，WS revision3、设置GET/PATCH revision6、注销revision7保持不变；仅新增未接线实现，没有改变线上的接口语义。

## 接续工作

把Nuxt已测试的realtime-subscription/realtime-redis接入_ws.ts和wsSession：替换泄漏的全局订阅集合，即时本地登记/可信状态、逐连接有界鉴权发送、取消/撤销/关闭释放；保留聊天、上线/离线和Origin流程。先核对Nuxt已有本地通知/聊天publisher，设计有界回声指纹，不能直接丢弃全部同server_id通知。随后实现两个客户端的严格状态/身份/端点失效与降级/恢复反馈，再推进完整原生业务、AI和Windows/Linux多方式部署。

完整接线步骤、既有publisher差异、聊天约束与测试设计见[Nuxt生命周期计划](../plans/2026-11-03-nuxt-realtime-lifecycle.md)。当前Nuxt有本地通知/聊天再Redis双路径，Go/Rust通知仍依赖用户远程频道，不能用统一server_id过滤掩盖差异或造成丢失。

Rust相关152/Go全量test-vet/Flutter契约44属于上个原生检查点，本阶段未重跑；ffprobe依赖媒体测试仍未执行。没有启动真实服务或Docker，也没有操作真实账号、日常迁移、分支提交或清理数据。2026-11-03T11:26:39.6426845+08:00 C盘实测可用144.75 GiB，本阶段没有新增清理。

机器状态：[2026-11-03-nuxt-realtime-foundation-state.json](../../../docs/handoff/2026-11-03-nuxt-realtime-foundation-state.json)。
