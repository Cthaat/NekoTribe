# 通知列表共同需求

`GET /api/v2/notifications` 读取当前认证用户自己的通知；access token 与服务器会话均须有效。客户端提供的用户 ID 不参与授权，失败不得泄露内部数据库错误。响应禁止共享缓存。

`type` 缺失或重复时为 `all`，空字符串和 `all` 不限制类型；其他单一值按原样精确匹配绑定。`unread_only=true` 仅查 `is_read=0`，`show_deleted=true` 仅查已删除通知；其他值或重复参数为 false。分页沿用共同会话分页规则，`page` 默认 1、最大 10000，`page_size` 默认 20、最大 100，重复/非法回退默认，并返回 `page`、`page_size`、`total`、`has_next`。按 `created_at DESC` 排序；计数和行查询应用同样的所有过滤条件。

每条通知包含 `notification_id`、`type`、`title`、`message`、可空 `resource_type` / `resource_id`、`priority`、数字 `is_read`、可空 `read_at` / `deleted_at`、可空 `actor`、`metadata` 和 `created_at`。actor 通过当前用户视角读取公开用户资料并按现有存储地址规则规范化；用户缺失或不可用时为 null。metadata 使用 Oracle `DBMS_LOB.SUBSTR(metadata_json,4000,1)`；空值为 null，合法 JSON 解析为相应值，不合法字符串原样返回。日期映射遵循现有 Nuxt 格式，真实 Oracle 时区和驱动行为须验收。

三端需要共同隔离场景及真实 Oracle、跨用户隔离、客户端和跨后端测试。列表读取不等于通知创建、状态修改或 Redis/WebSocket 推送已完成。
