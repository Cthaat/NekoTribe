# 私信附件、引用与表情回应

既有 `POST /api/v2/chat/direct-conversations/{conversation_id}/messages` 接受可选的 `content`、`media_ids` 与 `reply_to_message_id`，正文和附件至少有一项。正文去除首尾空白，最多 4000 UTF-8 字节。仅有附件时以一个 ASCII 空格满足原 Oracle 非空列约束，对外正文返回空字符串。保留原来只发送正文的客户端行为。

附件沿用私密媒体上传 `access_scope=chat`，发送参数最多 32 个不同的正安全整数 ID。附件由发送者所有、处于就绪状态，存储键属于 `private/chat/`，只能关联至一条私信，且与普通帖及频道附件互斥。后端持媒体行锁验证并在消息事务内写入关联。下载仅允许当前具有私信访问权的参与者，原始存储键不会作为下载地址。消息删除或权限收回后，已关联附件不可下载。未关联私密草稿继续由上传者访问。

引用对象必须是同一会话当前未删除的消息。私信历史、发送回执和新增 `GET /api/v2/chat/direct-conversations/{conversation_id}/messages/{message_id}` 可附带 `reply_to`、`media` 和 `reactions`。引用采用频道消息相同的 `{message_id,content,author_name}` 格式。媒体沿用受保护下载的资产数据结构。回应格式为 `{emoji,count,reacted_by_me}`。没有对应资料时可省略字段。

`POST` 或 `DELETE` 同一路径下的 `/reactions`，以 `{emoji}` 添加和移除本人的回应。输入去除首尾空白，最多 16 个 UTF-16 单元及 32 UTF-8 字节。已处理过的相同操作返回当前消息，单账号对同一消息的同一表情最多一条记录。会话行锁与消息删除串行化。某次回应确实变化且成功提交后，通过现有私信用户通道给两名参与者发送 `direct_message_updated`，负载只含 `{conversation_id,message_id}` 和可选 `server_id`。接收及投递时复核当前会话和消息，客户端用精确消息 GET 刷新当前账号的回应状态。该 GET 不改变已读游标。

通过 Nuxt 显式迁移创建 `n_direct_message_media`、`n_direct_message_replies` 和 `n_direct_message_reactions`。三套后端读取同一结构，消息关联及回应的检查全部在原生模块完成。附件访问及关联检查包含私信引用，缺少整个私信附件表的旧数据库可按已有规则读取旧频道和帖子附件。Nuxt Web 与 Flutter 支持附件下载、查看引用和表情回应。
