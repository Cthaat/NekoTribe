# 原生本地presence与跨实例订阅拆分计划

遵循现有接口设计、TDD和分步实现流程。保持完整业务/AI/部署目标；不启动Docker或真实Oracle/Redis/模型，不改分支/提交或已有数据。

1. [x] 新增Go/Rust实例级本地presence分发器，使用现有发布者server_id；每个已鉴权订阅有界队列与释放回调。发布先本地再独立调用现有Redis发布器，过滤本实例Redis回声，不过滤其他实例的合法事件。通知仍只走经鉴权用户的远程频道。
2. [x] 两原生后端订阅在本地能力可用时可降级建立，异步连接/重连远程订阅，不阻塞本地流。使用既有system_notification携带严格realtime_status控制状态（connecting/connected/unavailable），明确local_presence能力与remote_events状态；普通远程Redis输入不得伪造该控制帧。没有本地包装器的旧纯远程source仍fail-closed。
3. [x] 两原生后端WS升级/心跳/撤销检查保持原样；发送事件前仍核验当前会话。测试Redis初次失败、阻塞、订阅断开与恢复，本地送达、回声去重、其他实例/用户隔离、满队列和关闭清理；仅使用隔离适配器/本地测试服务器，不代表真实Redis验收。
4. [x] 生产Go入口及Rust native_router只创建一个本地分发器，订阅source和presence publisher共用它。保留通知发布者既有持久化/发布语义，不通过presence队列广播私密通知。
5. [ ] Nuxt/Flutter严格解码新增订阅状态并对断连/身份变更清除旧状态，给用户明确降级反馈；未提供状态的旧服务保留unknown，不将WS连接等同于远程事件可用。审查Nuxt原socket身份守卫，防旧连接跨账号派发。
6. [ ] 共同需求/场景、WS功能客户端范围及三后端/两客户端targetRevision同步；运行Go test/vet、Rust相关回归、Nuxt/Flutter针对性验证、contracts/parity，更新审计、机器状态和接手入口。保持accepted0/readyfalse；完整WS、真实跨实例/设备/六组合/部署仍待集中验收。

2026-11-03原生增量：1至4仅表示静态实现及隔离验证，非产品验收。共同LOCAL-PRESENCE场景、local-presence.md和OpenAPI控制帧已登记并同步；WS revision3，设置GET/PATCH revision6、注销revision7，客户端范围required18/unreviewed137。第6项仅完成规范登记和当前局部检查，尚需随新运行时代码补齐双客户端与Nuxt服务端验证。

接续先审Nuxt服务端如何发出可信订阅状态、检测断线并有界释放；当前仅Go/Rust发送新控制帧，Nuxt仍须实现。再处理两个客户端的严格解析、unknown/降级反馈、身份切换和恢复读取，尤其Nuxt旧socket回调不能跨身份派发。远程presence消费者已补共同7向量拒绝额外私密字段、hidden时间泄露和非法毫秒时钟；通知仍保留原始JSON字节。
