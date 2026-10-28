# Rust 和 Go 原生评论创建检查点

Rust native 和 Go 实现 `POST /api/v2/posts/{id}/comments`：鉴权、正文与父评论校验、帖子可见性和父评论约束、评论插入和回复根 ID，以及对帖子作者和不同父评论作者的通知。通知沿用接收者偏好；推送失败不撤销评论。共同需求和待执行验收场景见 `specifications/requirements/post-comment-create.md` 与 `specifications/scenarios/post-comment-create.json`。

隔离路由和数据库替身测试覆盖不可见帖子、跨帖或失效父评论、写入前权限变化、本人和重复接收者、通知偏好、部分通知失败、Redis 推送失败以及 UTF-16 摘录边界。评论写入、读取和通知分别执行；写入后失败可能已经提交评论或部分通知，不承诺回滚。Go 全量测试与 vet 通过；Rust 离线全量测试通过，两个真实 Oracle/Redis 连接测试忽略。

这些结果不证明真实 Oracle 空绑定、自引用外键、触发器、CLOB、语句快照或并发行为，也不证明真实 Redis、两客户端和跨后端互通。共同登记保持 `in-progress`，整体 `accepted: 0`；真实依赖和部署仍需在最终隔离环境验收。本轮未启动 Docker 或使用日常数据库。
