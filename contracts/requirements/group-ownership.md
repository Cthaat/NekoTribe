# 群主转让

PUT /api/v2/groups/{id}/ownership 要求有效会话和正十进制安全整数群组 ID。请求体为 JSON 对象，new_owner_id 为正安全整数。响应使用 private, no-store。

操作者必须同时是群组登记的所有者及 active 群主，不得转让给自己。接任者必须是同群组的 active 非群主成员。群组停用、删除、不存在或目标成员不存在时返回 40401。权限或成员状态不满足返回 42201。前群主的重复提交须按当前权限重新检查。

先锁群组，再锁原群主及接任者的成员记录。原群主变为 admin、接任者变为 owner，随后更新群组 owner_id，写入 transfer_ownership 审计记录。每次写入须恰好影响一行，四项写入共同提交，失败回滚。成功返回 group_id、owner_id。

Nuxt Web 和 Flutter 仅向可转让的目标成员显示操作，成功后通过群组详情重新加载当前权限。真实 Oracle 并发与客户端组合待验收。
