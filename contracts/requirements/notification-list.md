# 通知列表共同需求

`GET /api/v2/notifications` 读取当前认证用户自己的通知；access token 与服务器会话均须有效。客户端提供的用户 ID 不参与授权，失败不得泄露内部数据库错误。响应禁止共享缓存。

`type` 缺失或重复时为 `all`，空字符串和 `all` 不限制类型；其他单一值按原样精确匹配绑定。`unread_only=true` 仅查 `is_read=0`，`show_deleted=true` 仅查已删除通知；其他值或重复参数为 false。分页沿用共同会话分页规则，`page` 默认 1、最大 10000，`page_size` 默认 20、最大 100，重复/非法回退默认，并返回 `page`、`page_size`、`total`、`has_next`。按 `created_at DESC, notification_id DESC` 排序，并按该顺序返回页内结果。总数和当前页使用同一条 SQL 的同一份筛选数据，越界页返回空列表和实际总数。

每条通知包含 `notification_id`、`type`、`title`、`message`、可空 `resource_type` / `resource_id`、`priority`、数字 `is_read`、可空 `read_at` / `deleted_at`、可空 `actor`、`metadata` 和 `created_at`。actor 通过当前用户视角读取公开用户资料并按现有存储地址规则规范化；用户缺失或不可用时为 null。metadata 使用 Oracle `DBMS_LOB.SUBSTR(metadata_json,4000,1)`；空值为 null，合法 JSON 解析为相应值，不合法字符串原样返回。日期映射遵循现有 Nuxt 格式，真实 Oracle 时区和驱动行为须验收。

Nuxt Web 与 Flutter 均提供通知收件箱及已删除视图。已删除视图发送 `show_deleted=true`，并使用已有恢复接口。删除和恢复后重新读取当前视图。实时变化及重连时，从当前筛选的第一页重新读取，旧页不能合并回新结果。未读徽标使用收件箱里未读通知的总数。切换会话身份或后端地址后丢弃旧请求结果。

群动态与群评论通知通过 `group_id` 和 `post_id` 打开站内群动态详情，不依赖已加载的群组列表。群动态通知可用对应资源 ID 作为帖子 ID；群评论通知定位新评论，优先使用 `comment_id`，旧通知可用群评论资源 ID。两者冲突时不生成链接，不用父评论 ID 或普通动态页作为替代。目标仍由后端校验群组可见性与资源归属。

普通评论通知使用双方的帖子详情 `comment` 查询参数直接加载单条评论，无需评论已出现在首页。帖子 ID 依次取合法的 `target_post_id`、`post_id`、`source_post_id` 或帖子资源 ID。评论取合法的 `comment_id`，旧通知可用评论资源 ID；两者冲突或均无有效值时只打开帖子。不能将 `parent_comment_id` 当作新评论。目标 ID 必须为正安全整数或其规范十进制字符串，资源归属和可见性继续由后端校验。

私信通知使用 `metadata.conversation_id` 打开已有会话。这个 ID 必须为正安全整数或其规范十进制字符串，消息资源 ID 不作为会话 ID。Nuxt Web 和 Flutter 均按 ID 读取当前参与者可见的会话摘要，再进入该会话。Flutter 用回执中的参与者资料显示聊天标题，查不到会话或读取失败时留在收件箱，保留未读状态供重试。切换账号、后端或选择另一条通知后，旧回执不能发起跳转。点击通知不会创建私信会话。

Nuxt Web 的聊天页若查不到指定会话或查询失败，保留有效会话链接并显示重试和取消。查询成功、用户取消或手动选中其他会话后消耗该链接，弃用旧请求。

群邀请通知按 [定向邀请收件箱和响应](group-invite-response.md) 的规则定位邀请，并提供返回完整收件箱的入口。

三端需要共同隔离场景及真实 Oracle、跨用户隔离、客户端和跨后端测试。列表读取不等于通知创建、状态修改或 Redis/WebSocket 推送已完成。
