# 帖子删除共同规则

版本：1。适用 `DELETE /api/v2/posts/{id}`。Nuxt 为已有业务来源，Rust/Go 原生实现同一规则；本次同时修正 Nuxt 的宽松路径 ID 和未约束作者的更新，不能复制这两个缺陷。

- 必须有效 access 会话，认证先于业务校验。路径只接受单次解码后的 canonical 正 JavaScript 安全整数，与创建/转发规则一致。正文、查询参数和客户端传入的作者均不参与授权。
- 按 post_id 查询 author_id、is_deleted。不存在或已删除返回 404/code 40401/`帖子不存在`；存在且作者不是当前用户返回 422/code 42201/`只能删除自己的帖子`。管理员没有额外删除权限；审核处置走单独接口。这里不按可见性函数额外过滤，所有权规则与原 Nuxt 一致。
- 写入必须是绑定参数的 `UPDATE n_posts SET is_deleted=1 WHERE post_id=:post_id AND author_id=:user_id AND is_deleted=0`。读取之后作者/删除状态改变，导致更新零行时返回相同 404。成功仅在一行更新并成功提交后返回 HTTP 200/code 200/message `post deleted`，data/meta 均 null。重复删除返回 404，不重复触发软删除更新。
- 不物理删除帖子、媒体文件、评论、关系或历史通知，不新增通知/实时事件，不增加浏览量。关联计数及原有触发器在真实 Oracle 中另行验收。知识库尚未上线，其未来可见性读取必须排除软删除资料。
- 读取/更新/提交/连接释放错误为安全 500/code 50001/`服务器内部错误`，不暴露驱动详情。提交或关闭失败可能发生在软删除已持久化之后，不推断一定回滚；客户端可重新读取状态。各业务响应设置 `Cache-Control: private, no-store`，共享后端缓存规则继续适用。

`scenarios/post-delete.json` 是三个工程共享的隔离输入与结果，不证明真实 Oracle、会话中间件、触发器或跨端可用。Nuxt 测试预先设置认证上下文；Rust/Go 另经真实 HTTP/JWT 路由测试。语法错误的 URL 可能在进入路由前由 HTTP 服务器拒绝，不能把参数单元测试当作传输响应一致。

帖子 PATCH/PUT 的部分更新、单连接事务和关系清空规则见 `post-update.md`；删除与编辑均约束作者和未删除状态，真实并发效果仍需同一 Oracle 环境验证。
