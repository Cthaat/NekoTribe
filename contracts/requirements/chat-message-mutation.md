# 频道消息编辑、软删除和置顶

三条接口均要求有效会话、正十进制安全整数消息 ID 和当前频道访问权限。消息不存在或已删除返回 40401。无权限返回 40301。响应使用 private, no-store。

- PATCH /api/v2/chat/messages/{message_id} 仅允许活跃的原作者编辑文字消息。正文去除首尾空白后必须非空，最多 4000 个 UTF-8 字节。返回编辑后的消息，保留回复、附件和反应。
- DELETE /api/v2/chat/messages/{message_id} 仅允许作者或群主、管理员、版主软删除。消息与频道计数在同一事务更新。删除当前最后一条时，以仍可见的最大消息 ID 修正预览。没有剩余消息时清空预览。成功返回 200 和 null。
- PUT /api/v2/chat/messages/{message_id}/pin-status 仅允许群主、管理员、版主设置或取消置顶。返回变更后的消息。

先锁定群组和成员，复核权限后锁定目标消息。任一写入或回读失败须回滚。提交后广播 chat_message_updated 或 chat_message_deleted。更新广播不携带操作者的管理权限、作者关系或个人反应状态。真实 Oracle、Redis 和客户端联调待验收。

两端仅对本人文字消息显示编辑入口，仍由服务端判断频道成员状态及最终权限。编辑和置顶回执需匹配消息、群组和频道，并确认修改后的正文或置顶状态。删除确认使用 `{code:200,message:"chat message deleted",data:null,meta:null}`。两端在合并正在加载的历史页时保留已确认的删除，账号、频道或 Flutter 后端切换后丢弃旧回执。
