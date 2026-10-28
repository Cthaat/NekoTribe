# 通知列表开发检查点

Rust native 和 Go 新增 `GET /api/v2/notifications`：服务端认证会话决定用户，支持类型、未读、删除状态和分页过滤，返回通知及接收者视角的公开作者资料；数量和列表都使用相同过滤条件。合法 metadata JSON 解析，空值为 null，无法解析的值保留为字符串。Nuxt 入口补充 `private, no-store` 和异常脱敏。共同需求及八条待执行完整场景分别见 `specifications/requirements/notification-list.md` 和 `specifications/scenarios/notification-list.json`。

OpenAPI 修正通知作者及资源类型可空、cookie 认证和分页类型，并按实际行为不限制通知类型枚举。Nuxt、Rust、Go 的隔离 HTTP/数据库替身测试覆盖用户范围、过滤条件及绑定、metadata、作者映射和错误。此检查点不覆盖通知创建、状态更新或实时推送，也不证明真实 Oracle 时区、长 CLOB、事务快照、跨用户隔离或双客户端联调；这些仍待隔离真实环境验收。未启动 Docker 或改动日常数据。

验证：Nuxt 根目录 Node 测试 534 项通过、2 项跳过，类型检查通过；Go 全量 test/vet 和通知专项通过，Rust 离线全量回归通过、2 项真实依赖测试忽略。共同需求检查覆盖 63 份共享文件，完整业务验收仍为 `accepted:0`、`ready:false`。
