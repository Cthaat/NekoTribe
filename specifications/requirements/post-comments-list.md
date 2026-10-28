# 帖子评论列表共同需求

`GET /api/v2/posts/{id}/comments` 需要有效 access token 与数据库会话，按会话用户判断帖子可见性。帖子不存在、已删除、被屏蔽或无权查看时统一返回 404 `帖子不存在`。路径 ID 是不带前导零的安全正整数（1 至 9007199254740991）；Nuxt 原宽松 ID 解析及未校验可见性行为已收紧。

计数和列表必须各自在自己的 SQL 中调用 `fn_can_view_post(:viewer_id, c.post_id)=1`，不能只在前置检查中验证权限。数据来自 `v_post_comment_list_item`，该视图过滤已删除评论。分页使用既有 `v2Page` 规则；`sort=oldest` 按创建时间升序，`popular` 按点赞数降序、创建时间降序，其余值按创建时间降序。每条包含 comment_id、post_id、当前查看者视角的公开作者、parent_comment_id、root_comment_id、content、stats（likes_count、replies_count）、viewer_state（is_liked、can_delete）和时间。父/根 ID 可为空，缺失时间输出空字符串。点赞状态按当前用户查询，can_delete 仅在当前用户是评论作者时为 true；作者不可用返回 404 `用户不存在`。响应包含标准分页 meta，设置 `private, no-store`，内部错误脱敏。

前置权限检查、计数、列表和作者映射是独立查询，可能在并发权限变化时观察到不同快照；后续查询均有各自可见性条件，不声称跨查询原子性。真实 Oracle 权限函数、分页和排序并列、CLOB/时间转换、并发以及两个客户端需要隔离环境验收。
