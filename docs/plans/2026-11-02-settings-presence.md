# 设置变更在线状态事件计划

沿用现有设置事务与私密HTTP响应，按TDD/API接口设计和安全检查流程顺序执行。保持完整业务/AI/部署目标，不启动真实依赖，不切分支或提交现有WIP。

1. [x] 登记user-settings-presence.json共同HTTP、查询映射和事件向量，先在Nuxt/Rust/Go复现旧小数标志、字段泄露和发布失败差异。输入是否包含show_online_status决定触发，而非其转换后的布尔值。
2. [x] 三后端均在设置提交后查询最新服务端presence；查询失败返回安全500、不发布、不声称写入撤销。无字段、鉴权/输入/事务失败不查presence或发布。将未显式可见的旧NUMBER值映射为hidden，hidden永远last_seen_at=null。
3. [x] 统一presence_update/ws:presence数据白名单user_id/online_status/last_seen_at/server_id和epoch毫秒timestamp，拒绝非法ID/status/可见last_seen类型/发送者/时钟。Nuxt本地WS与Redis分别尽力发送；Go/Rust现有Redis发布器分别维持有界发布。验证字段不从PATCH输入推导。
4. [x] 隔离实际HTTP路由、生产presence查询/mapper和生产encoder，不以伪repository代替事务或Redis送达证明。补发布失败/缺publisher、隐藏状态和固定错误头，保留best-effort非持久事件语义。
5. [x] 更新共同需求、OpenAPI说明和PATCH需求审查/revision/三后端及两客户端任务，同步共享文件。运行Nuxt相关回归/typecheck、Go离线test/vet、Rust相关lib/integration、contracts/parity与差异检查。
6. [x] 写审计和状态，更新最新接续点及可粘贴提示词，capture后verify --check-only；保留795份初始快照和旧zip。真实Redis/WS分机送达、事件时序/丢失恢复、Oracle并发和客户端组合仍须集中验收，不标accepted。
