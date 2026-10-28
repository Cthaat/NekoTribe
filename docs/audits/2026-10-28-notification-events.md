# 通知事件发布开发检查点

三端读取共同的八条通知事件样例；Nuxt 现有发布代码、Rust 和 Go 的新组件均验证频道、事件类型、数据与实例标识。Rust 基于既有 Redis 客户端增加 `PUBLISH`；Go 引入 Redis 官方客户端 `github.com/redis/go-redis/v9`，新发布器可使用 Redis URL（含可选 TLS），设置超时、不自动重试，并对调用方返回脱敏错误。Go 与 Rust 测试使用本地模拟 Redis 协议服务，确认实际客户端发出的 `PUBLISH`；未访问真实 Redis 或运行 Docker。官方当前客户端文档将 Redis 7 列为非正式支持，实际项目使用的版本仍需实测，不从协议替身推断兼容性。

发布组件目前尚未连接原生通知业务或配置启动入口；Rust、Go 也尚未提供独立 WebSocket 收件端。Redis Pub/Sub 发布成功不证明用户收到事件，断线期间不保证送达。真实 Redis 7、ACL、认证、TLS、超时、跨实例及接收端隔离需最终验收；首次点赞通知仍未实现。Go 客户端及协议资料参考 [Redis 官方 Go 客户端](https://redis.io/docs/latest/integrate/go-redis/) 和 [Redis Pub/Sub 指南](https://redis.io/docs/latest/develop/use-cases/pub-sub/go/)。

验证：Nuxt 共同样例及登记检查 41 项通过；Go 全量 test/vet 通过；Rust 离线全量回归通过、两项真实依赖测试仍忽略。共同登记包含 154 个工作项、65 份共享文件，`accepted:0`、`ready:false`。
