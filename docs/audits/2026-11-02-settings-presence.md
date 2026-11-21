# 设置在线状态事件检查点

2026-11-02。本轮完成暂停前的最后一处时钟错误降级复核，并补齐三后端设置presence的共同HTTP、查询映射和事件编码规则。仍仅静态开发/隔离验证；未启动Docker、真实Oracle/Redis/模型/SMTP，未操作日常数据、分支切换/提交或旧交接档案。

## 修复与范围

- 设置事务成功后，仅输入含show_online_status才查询当前状态。无字段、非法输入或设置存储失败不发布；查询失败安全500但设置可能已提交，不回滚、不自动重放。Nuxt/Go隔离驱动核对查询发生在commit之后；Rust使用生产OracleSessions/HTTP路由、SessionExecutor原子边界夹具，实际事务编排由settings_read生产Transaction单元测试另行覆盖。
- 三后端查询90秒内未撤销会话，原始可见NUMBER精确1才可见；SQL与mapper都将1.9等旧非1值隐藏。此前Nuxt/Rust可能暴露online状态，Go可能扫描失败；已修复。hidden永远last_seen_at=null，包括不一致行或非法传入对象；未知status拒绝，缺用户兼容offline/null。
- presence_update的ws:presence帧固定字段，Rust不再透传额外数据；Go强类型数据和Nuxt新独立v2PresenceMessage保持同一白名单。合法用户ID/epoch毫秒在JS安全整数范围，server_id由服务端覆盖。非法时钟或编码在发送边界拒绝；设置写入成功后交付故障仍按降级处理。
- Nuxt本地WS和Redis分别尝试，一方失败不阻止另一方；没有publish成功即保证送达的声明。Node Redis发布工具不再记录正文或原始发布者异常，发布者命令超时1500ms、禁用未完成命令自动重发和每命令重试，就绪等待仍有1500ms界限。配置与无网络适配器回归不证明真实网络时延；其他Redis/WS日志未在此声称完成整体审计。
- Go/Rust现有Redis发布器的有界发送和降级语义保留。已明确发现它们依赖Redis才能给本机订阅者送达，尚无Nuxt式独立本地降级；已同步到NOTIFICATION-WEBSOCKET任务，不能把这轮共同HTTP/编码通过误称完整实时能力一致。事件仍非持久、无断线重放/全序/保证送达。

共同规范user-settings-presence.md及user-settings-presence.json包含9个HTTP场景、7个查询场景、10个事件向量，由三后端相关测试消费。Nuxt额外覆盖独立本地发送失败、发布编码时钟错误降级与真实Redis工具的无网络配置/日志边界。原生设置HTTP夹具提取到tests/helpers/settings-http.mjs，实际路由/鉴权/两层缓存和presence代码运行，仅隔离DB/传输边界。

## 最终验证

| 检查 | 结果 |
| --- | --- |
| Nuxt 35个相关测试文件 | 1416通过，失败/取消/跳过0 |
| Nuxt typecheck | exit0 |
| Go离线test ./...和vet ./... | exit0；未变化ai/auth包复用Go缓存 |
| Rust离线lib及7个integration目标 | 141通过：lib99、注销1、通知编码4、WS3、repository24、presence3、设置PATCH3、设置HTTP4 |
| Flutter API及路由契约 | 44通过 |
| contracts workspace check | exit0，171 operations、0 schema gaps、4571 schemas |
| parity workspace check | exit0，155 features、71 scenarios、151 sharedFiles、131 sourceAudits，required17/unreviewed138，accepted0/readyfalse |
| 新Rust presence测试文件rustfmt --check | 本机已存在的Windows formatter通过；未下载或更换工具链 |

初次Nuxt共同/原生74项中15项失败（含独立编码器缺失），Go3个子场景失败，Rust3项中2项失败；Redis日志4项中3项失败，补超时/禁止重发断言时4项失败；最后时钟降级单项先失败后修复，恢复后相关100项通过。最终结果以上表为准。原始日志位于父目录.codex-logs/settings-presence-*.log及settings-presence-contracts.json、settings-presence-parity.json。

本轮Go/Rust设置测试调用各自原生路由，没有代理Nuxt；这不代表所有业务均已摆脱代理或全部完成。Rust相关141项不等于完整Rust集成套件。Flutter本轮运行时代码未改，仅44项契约复核，未重复运行完整1167项或analyze；完整1167项是上一阶段证据。没有真实浏览器、设备或完整WS链路验收。

OpenAPI仍2.0.0，新增AuditedPresenceEvent输出schema及PATCH事件说明；x-contract-revision为2026-11-02-settings-presence，SHA256为b6b92406975d3e97ddfb851aa3189144009a00c976f52bf4fe7c8d6e55c2cc09。设置GET/PATCH revision5且需求均reviewed、注销revision6、NOTIFICATION-WEBSOCKET revision2；各三实现及已有客户端targetRevision同步，实现仍in-progress、未提升accepted。源码依赖显式登记presence/Redis核心文件。原始795份交接快照与旧zip保留。

## 接续工作

优先给Go/Rust补与Nuxt一致的本地presence推送降级，审查两客户端WS状态消费/失效/重连刷新；这仍属于完整实时能力，不能因HTTP发布接口已过就跳过。然后继续AUTH-901/905、资料输入和其余138项客户端范围。真实Oracle并发、Redis/WS跨实例送达、端点认证范围与六种组合、浏览器/设备和多机器部署仍需集中验收。

完整原生业务、群组/实时/管理、可切换模型、公开数据RAG、持久化上下文、版本化Skills、有界Agent、问答写作/群运营/审核、旧情感分析退役及Windows/Linux本地/Docker/混合部署目标全部保留。本轮未退役旧AI字段，也未新增空间清理；容量快照在.codex-logs/settings-presence-disk.json，deletedPaths为空。

后续先读docs/handoff/LATEST.md与START-HERE-PROMPT.md。本轮哈希和验证清单在docs/handoff/2026-11-02-settings-presence-state.json；旧审计是历史时点，不能据旧未完成列表重复已经修复的设置事务和客户端保存流程。
