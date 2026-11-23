# 聊天输入状态与私信已读

已认证的 `/_ws` 客户端可发送 `typing_start`、`typing_stop`，`data` 只包含一个正安全整数 ID，即 `conversation_id` 或 `channel_id`。服务端从会话取得 `user_id`，验证实时访问权。私信只发给另一位现有参与者，双方启用且互未拉黑。频道只发给已订阅且当前有权读取该频道的成员，不显示本人。服务端向接收方发送相同事件名，`data` 包含原范围 ID、`user_id` 及可选 `server_id`。类型各自按连接限频，同类型最短间隔 1200 ms。输入状态只通过现有本地会话和实时广播传输，不保存至 Oracle。客户端忽略其他会话与较旧事件，5 秒后自然消失，也可被同一用户的 `typing_stop` 提前清除。离开当前视图或账号时清空显示。

`GET /api/v2/chat/direct-conversations/{conversation_id}/read-status` 返回 `{conversation_id,last_read_message_id,participant_last_read_message_id,unread_count}`。两个游标尚未建立时为 `null`。未读数只统计当前查看者收到且未删除的消息。`PUT` 同一路径以 `{last_read_message_id}` 提交当前已看到的同会话未删除消息 ID。游标只能前进，重复提交获取当前状态。非参与者返回 403，游标无效或属于另一会话返回 400。两个入口均要求身份鉴权，返回 `Cache-Control: private, no-store`。复用 `n_direct_conversation_reads`，不新增表或 DDL。

私信历史接受可选 `mark_read`，默认保持既有第一页已读行为。`mark_read=false` 时禁止更新游标，两客户端用此选项取历史，在会话可见后再明确提交已经显示的游标。精确消息读取和搜索不更新游标。任一行为使游标实际前进并提交成功后，向两位参与者发布 `direct_read_updated`，负载为 `{conversation_id,reader_id,last_read_message_id}` 和可选 `server_id`。事件无消息正文和用户的未读数。发送和投递均按私信范围校验。客户端在当前会话用对方的游标显示最后一条已读的自己所发消息，其他客户端刷新本人的未读角标。连接恢复时以 HTTP 状态为准。
