# 群组成员审批与移除

审批使用 PUT /api/v2/groups/{id}/members/{member_id}/approval-status，按成员记录 ID 定位。请求体为 JSON 对象，approved 必须是布尔值。同意将 pending 普通成员改为 active，拒绝删除该申请。成功分别返回 member_id 和 active 或 rejected。处理过的申请不能再次修改，已删除的申请返回 40401。

移除使用 DELETE /api/v2/groups/{id}/members/{user_id}，按用户 ID 定位。可以移除角色低于操作者的 active、muted 或 pending 成员。群主及封禁记录受保护。成功返回 data 为 null。

两项操作均要求有效会话和正十进制安全整数 ID。仅 active 状态的群主、管理员和版主可操作。无管理权限、目标角色受保护或状态不允许时返回 42201。群组未启用、已删除或找不到指定成员时返回 40401。响应为 private, no-store。

先锁群组，再在同一 Oracle 事务内读取操作者和锁定目标。更新或删除必须恰好影响一行，且与对应的 approve_member、reject_member 或 remove_member 审计记录共同提交。失败回滚。真实 Oracle 并发和客户端组合待验收。
