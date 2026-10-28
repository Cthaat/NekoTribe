# 2026-10-28 当前用户资料部分更新

Nuxt、Rust native 与 Go 实现 `PATCH /api/v2/users/me` 的共同切片：认证会话决定用户，按提供字段部分更新并重新读取当前资料。Rust 和 Go 独立执行自己的 Oracle SQL，不通过 Nuxt。Nuxt 补充 `private, no-store` 和驱动异常安全封装。公共需求和 18 个合成场景分别见 `specifications/requirements/user-self-profile-update.md`、`specifications/scenarios/user-self-profile-update.json`；三端契约副本一致。

隔离测试使用真实 HTTP 路由、JWT、模拟会话与资料存储；Nuxt 另检验实际生成 SQL、绑定和自动提交参数，Rust/Go 以模拟执行器验证字段白名单、绑定、日期表达式及注入隔离。Go 驱动替身还检查独立提交和空更新不提交。Nuxt 全量 501 通过、2 跳过；Go 全套 test/vet 通过。测试没有运行真实 Oracle、Redis、浏览器或跨机。

OpenAPI 修正 Cookie 鉴权、成功响应、可接受字段类型和忽略未知字段；四工作区同步。更新后读取资料失败不证明写入回滚。真实 Oracle 19c/Free 上日期输入、空值/列类型、触发器、并发和驱动关闭仍待验收；原生日志与公共用户资料缓存跨后端失效、客户端全流程、跨机与大于 1 MiB 的请求体差异仍未解决。共同验收仍为 `accepted:0`，不能将合成场景当成完整功能验收。
