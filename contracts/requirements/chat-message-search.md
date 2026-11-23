# 私信与频道消息搜索

在现有 `GET /api/v2/chat/channels/{channel_id}/messages` 和 `GET /api/v2/chat/direct-conversations/{conversation_id}/messages` 中使用同一组可选过滤器。`q` 按不区分大小写的普通文本子串匹配消息正文，首尾空白忽略，最多 400 UTF-8 字节。`sender_id` 为正安全整数，对发送者账号精确筛选。`start_at` 和 `end_at` 为 RFC 3339 时间，精确到毫秒，起点包含、终点排除，可独立指定。同时指定时起点须早于终点，非法参数返回 400。过滤器之间使用 AND。

搜索仍校验当前私信参与者资格或频道读取权，检索范围限于该会话或频道的未删除消息。计数和分页使用相同过滤条件。分页窗口按创建时间和消息 ID 倒序选取，窗口内按创建时间和消息 ID 正序显示，与普通历史一致。任何实际过滤器存在时均只读，省略私信 `mark_read` 也不改变已读游标。所有过滤值以 Oracle 绑定变量传入。

Nuxt Web 与 Flutter 从当前聊天中的搜索动作打开过滤器，并提供恢复完整历史的清除操作。日期选择采用用户本地日历，结束日期包含整天，转换为次日零点作为接口独占终点。搜索时保留现行权限与分页，两端不对检索结果提交已读。时间谓词使用 Oracle 的会话时区与现有 `CURRENT_TIMESTAMP` 列默认值一致。[Oracle 日期时间表达式](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/Datetime-Expressions.html)
