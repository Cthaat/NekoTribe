# 群组成员角色与禁言

PATCH /api/v2/groups/{id}/members/{user_id}/role 修改角色，复数 /roles 为兼容路径。PUT 和 DELETE /api/v2/groups/{id}/members/{user_id}/mute-status 分别设置和解除禁言。要求有效会话、正十进制安全整数 ID，响应使用 private, no-store。

操作者须为 active 成员。修改角色要求管理员或群主，且原角色与新角色均严格低于操作者。role 接受 admin、moderator 或 member。禁言与解除禁言要求版主或更高角色，目标角色严格低于操作者。三项操作均保护操作者自己、群主、待审批和封禁成员。目标必须为 active 或 muted。

禁言时 duration_hours 省略时默认为 24，提供时必须是 1 至 8760 的整数。reason 可省略或为 null，字符串最多 200 个 UTF-8 字节。重设禁言从数据库当前时间重新计算到期时间。解除禁言清除到期时间和原因。重复设置同一角色或解除已正常成员的禁言为成功的空操作。

角色修改返回 user_id、role。禁言返回 user_id、status=muted 和 UTC 格式的 mute_until。解除禁言返回 user_id、status=active。参数错误为 40001，停用、删除或不存在的群组及找不到目标成员为 40401，权限或状态不满足为 42201。

先锁群组，再在同一 Oracle 事务内锁定并读取成员。实际变更须恰好影响一行，并与 change_role、mute_member 或 unmute_member 审计记录共同提交。失败时回滚。真实 Oracle 并发和客户端组合待验收。
