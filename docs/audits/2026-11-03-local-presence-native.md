# 原生本地presence与订阅状态检查点

2026-11-03 接续Go局部增量，Rust现已使用一个实例级LocalPresenceEvents连接HTTP发布者与已鉴权WebSocket。构造时继承真实远程发布者的server_id，无远程发布者才生成本地ID。原有NotificationPublisher实现可继续用于旧路由；需要包装的发布者必须显式提供presence_server_id，避免回声标识不一致。

## 已实现与隔离验证

本地订阅立即建立，异步远程连接/重试不会阻塞本地流。Rust使用单个任务同时轮询本地流和可取消远程future，最多1024订阅、每级队列16；慢消费者关闭，取消/丢弃接收端/实例关闭释放登记。注册守卫在spawn之前创建，使尚未首次poll的任务被丢弃时也能释放登记。close后拒绝新订阅和本地发布，不关闭调用方另行持有的适配器。

有效presence先本地，再独立限时尝试远程发布。过滤本实例presence回声，保留其他实例presence与本实例通知；私密通知仅走当前用户源。通知含未配对UTF-16的原始JSON继续按字节转发。Rust生产native_router与Go入口均把同一hub作为source和presence publisher；Rust通知publish只委托原发布者，不向本地presence广播。

两个原生后端都发送受当前会话保护的realtime_status，状态connecting/connected/unavailable，不把降级握手冒充远程通知健康。Redis输入不能伪造控制帧，普通远程源仍503。WS的Origin/令牌、心跳与发事件前会话撤销核验保留。远程错误/关闭后报告降级并间隔1秒重试；Go低层Redis读已在此前增量修正为暴露读失败，而非隐藏的Channel自动重连。Rust的真实Redis网络检测/恢复仍需独立实测。

本轮还以共同remoteCases复现并修正Go/Rust远程presence消费者：只接受四个白名单数据字段、hidden/null及安全整数毫秒时钟，拒绝额外私密字段、负数/小数/越界时钟。编码端原有白名单继续保留；未改变私密通知原始字节语义。

## 统一需求与双客户端登记

规范local-presence.md、LOCAL-PRESENCE场景及OpenAPI AuditedRealtimeStatusEvent已登记并同步四树。共同向量为8个交付场景、5个控制状态样例、7个远程presence帧样例。WS revision3、设置GET/PATCH revision6、注销revision7，所有三后端及已登记客户端targetRevision同步。WS客户端范围改为required，Nuxt Web与Flutter都有具体任务和现有相关文件映射；这不是新客户端能力已实现的声明。

当前171 operations、0 gaps、4582 schemas，OpenAPI SHA256 e1c30f5422c584de5c21f427f5ee02e1fd13f5277702fab3ad521b8fa73f80dd；155 features、72 scenarios、153 sharedFiles、131 sourceAudits，required18/unreviewed137，accepted0/readyfalse。

## 验证与限制

- Rust lib+8个integration目标共152项通过，分目标101/1/8/4/4/24/3/3/4；0失败，1项真实WAV探测测试因需本地ffprobe而忽略，不是完整Rust集成套件。
- Go全量test与vet通过，2050个通过事件（含子测试）、顶级382；跳过TestMediaUploadRealWAV，需NEKO_TEST_FFPROBE。两个包没有测试文件。
- Nuxt契约/登记94项、Flutter契约/路由44项通过，四树contracts/parity通过；源代码格式/定向diff检查通过。
- 先确认本地订阅失败、pending阻塞、WS控制帧丢失、缺少schema，以及不严格的远程presence接收失败，再通过回归。日志与命令见机器状态。

**Nuxt服务端尚不发送新健康控制帧，两客户端也尚未消费新状态或展示降级/恢复反馈；Nuxt旧socket身份守卫待修正。** 当前规范覆盖范围大于实现进度，不能称三后端/双客户端完整对齐。Nuxt运行时未变，本轮未跑Nuxt类型检查或Flutter完整套件/analyze。真实Oracle/Redis/模型/SMTP、账号、浏览器/设备、跨实例、六组合及部署未验收；没有Docker、迁移、分支提交或原始交接包变更。

先实现Nuxt服务端可信realtime_status、远程订阅断线/恢复与有界资源释放；再实现Nuxt Web/Flutter严格解码、unknown/降级反馈和恢复读取，修正Nuxt旧socket跨身份回调。接续AUTH-901/905、资料输入、137项客户端范围审查，完整原生业务、可切换LLM/RAG/上下文/Skills/Agent及Windows/Linux多方式多机部署；真实依赖和六组合留待集中验收。

机器状态：[2026-11-03-local-presence-native-state.json](../../../docs/handoff/2026-11-03-local-presence-native-state.json)。上轮[空间清理](../../../docs/audits/2026-11-03-storage-cleanup.md)已完成；本阶段不重复清理，2026-11-03T11:08:10.8967277+08:00 C盘实测可用115.58 GiB，不把历史92.60或6.44 GiB重新计入。
