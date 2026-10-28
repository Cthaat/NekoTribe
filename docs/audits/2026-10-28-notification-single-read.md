# 单条通知已读状态开发检查点

Nuxt、Rust native 与 Go 对齐 `PUT /api/v2/notifications/{id}/read-status`：当前认证用户只能更新自己的通知；支持设置已读或未读，返回数据库读取到的状态和时间，并向当前用户发布 `notification_read_status_updated`。重复请求也执行更新和事件发布。Nuxt 更新后的读取同样增加用户条件，异常返回经过脱敏。通知 ID 统一收紧为不带前导零的安全正整数，属于既有宽松解析行为的兼容性变更。

共同需求和布尔转换样例分别位于 `specifications/requirements/notification-single-read.md` 与 `specifications/scenarios/notification-single-read.json`。Rust/Go 的公共副本及四工程 OpenAPI 已同步。Rust/Go 请求体限制 1 MiB，而 Nuxt 当前没有统一上限；具体行为差异记录在共同需求中。

Nuxt 全量隔离测试 562 通过、2 跳过，类型检查通过；Go 全量 test/vet 通过；Rust 离线全量测试通过，真实依赖测试仍忽略，路由与仓储专项 2 项通过。三端共享布尔样例及用户范围、错误脱敏、通知发送失败和更新后读取失败等行为由隔离测试覆盖。共同规范检查覆盖 69 份共享文件，`accepted:0`、`ready:false`，不能把样例通过当成最终业务验收。

Rust 共享布尔样例另行通过。尝试执行 `cargo fmt --all -- --check` 时，当前 WSL 离线工具链未安装 rustfmt 组件，故本次格式检查未通过执行，待补充工具后重试；代码差异空白检查已通过。

写入与后续读取、Redis 投递不是同一个原子操作：读取失败时写入可能已经提交，Redis 不可用时实时消息可能未送达。真实 Oracle 日期和时区、并发、Redis/TLS、跨实例及两个客户端仍待隔离环境验证。本轮没有启动 Docker 或访问日常数据库。
