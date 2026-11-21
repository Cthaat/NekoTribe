# 内容发布限制

Nuxt、Go 和 Rust 的普通发帖、引用、转发、回复帖、普通帖子编辑及评论使用同一规则。对应入口为 `POST /api/v2/posts`、`POST /api/v2/posts/{id}/retweets`、`PATCH/PUT /api/v2/posts/{id}` 和 `POST /api/v2/posts/{id}/comments`。

同一规则覆盖群帖和公告、群评论、私信、频道消息及频道消息编辑。

| 操作 | 接口 |
| --- | --- |
| 发布群帖或公告 | `POST /api/v2/groups/{id}/posts` |
| 发布群评论 | `POST /api/v2/groups/{id}/posts/{post_id}/comments` |
| 发送私信 | `POST /api/v2/chat/direct-conversations/{conversation_id}/messages` |
| 发送频道消息或附件 | `POST /api/v2/chat/channels/{channel_id}/messages` |
| 编辑频道消息 | `PATCH /api/v2/chat/messages/{message_id}` |

- 已认证账号必须仍处于启用状态。其 `mute` 限制状态为 `active`，且开始时间已到、结束时间未到或为空时，拒绝发布。时间由 Oracle 计算，开始时刻包含在禁言区间内，结束时刻即恢复发布权限。
- 审核处置和发布写入共同锁定目标账号行。发布入口取得行锁后查询限制，再在同一连接和事务写入。拒绝返回 HTTP 403，消息为「当前账号不能发布内容」，并释放行锁。拒绝时没有内容、附件关系、会话摘要、读游标或通知写入，也没有实时发布事件。
- 请求校验、资源可见性、群组权限、私信收件规则和作者权限沿用各接口自身的规则。群内禁言仍可单独限制频道操作。删除、置顶、点赞、表情回应、收藏和读取继续使用各自的权限规则。WebSocket 负责已提交内容的订阅和投递，发布经由以上 HTTP 接口。
- 定时封禁到期恢复和举报自动阈值由审核处置的后续任务跟踪。

隔离测试覆盖发布写入拦截及其时间边界。真实 Oracle 需要两连接交错验证审核生效、撤销禁言、发布时间边界及群组和聊天事务的锁顺序。
