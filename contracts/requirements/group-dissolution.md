# 群组解散

- `DELETE /api/v2/groups/{id}` 需要有效会话及正安全整数路径 ID，响应带 `Cache-Control: private, no-store`。
- 事务先锁定群组行。不存在或已解散返回 404。同群组记录的所有者且具有活跃 owner 成员记录方可操作，否则返回 422。允许群主解散已停用但未删除的群组。
- 设置 `is_deleted=1` 和 `is_active=0`，并写入 `delete_group` 审计日志。两条 SQL 各影响一行且事务提交后才返回成功。任何失败应回滚，重复请求不追加审计。
- 成员、邀请、帖子、频道和历史消息继续保留在数据库。依赖群状态的群组详情、邀请和群聊入口在解散后拒绝访问。遗留帖子和评论修改端点的群状态校验与原生实现一起验收。
- 成功响应为 HTTP 200，正文为 `{"code":200,"message":"group deleted","data":null,"meta":null}`。Nuxt Web 和 Flutter 在确认后发起操作，并在成功时离开管理界面。
