# 通知实时事件发布基础

通知创建、单条或批量已读状态、删除和恢复均可向指定用户发送实时事件。沿用 Nuxt `WSMessage`：Redis 频道 `ws:user:{user_id}`，JSON 顶层包含 `type`、`data` 和 Unix 毫秒 `timestamp`；`data.server_id` 由发布实例生成，不接受业务数据覆盖。用户 ID 使用 1..9007199254740991 的安全整数。事件类型限 `notification_created`、`notification_read_status_updated`、`notifications_read_status_updated`、`notification_deleted`、`notification_restored`。

已存通知和发送权限由业务层负责；此层不接受客户端决定接收者，不记录事件正文、连接地址或密码。调用需要限制等待时间、响应取消、发送一次，返回可区分的安全失败；Redis Pub/Sub 不保证断线期间送达，发布成功也不能证明 WebSocket 用户收到消息。调用层应按 Nuxt 既有降级行为处理失败，不能用未送达来抹除已存通知，也不能宣称可靠重放。接收端必须验证身份、隔离用户并防止本实例事件的回声重复投递。

支持按实际部署配置 Redis 地址和凭据，禁止硬编码用户配置；配置和日志不得暴露密钥。连接、鉴权、ACL、TLS、Redis 7、跨机器及 WebSocket 接收端需要真实隔离环境验收。

Nuxt Web 的通知页收到上述事件或连接恢复后重新读取通知。Flutter 通知页也重新读取，且首页等其他页面的导航未读角标会通过 HTTP 校准。短时间的多个事件合并为一次角标读取，事件正文不用于推算未读总数。切换账号或后端时清空旧角标并废弃旧请求，待新会话就绪后读取当前未读总数。
