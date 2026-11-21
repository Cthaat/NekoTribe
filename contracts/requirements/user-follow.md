# 用户关注

Nuxt、Go、Rust 通过共享 Oracle 原生提供 `POST`、`DELETE /api/v2/users/{id}/followers`，以及分页的 `GET /followers`、`GET /following` 和 `GET /mutual-following`。五个接口都校验当前会话，并使用解码后的无前导零正十进制安全整数作为目标 ID。

1. POST 对本人返回 422，对无有效公开资料的用户返回 404。关注、取关和拉黑采用同样的用户 ID 升序锁定规则。任何一方已拉黑时，新增关注返回 403「无法关注该用户」。若关注先提交，随后提交的拉黑在同一写事务里取消该关注。
2. POST 新建关注或重新激活已取关记录。已有 active 记录的重复请求不更新该记录，也不创建新通知。DELETE 对有效关注标记 cancelled，对已取关或目标不存在保持成功。写入后在同一事务回读目标粉丝数，返回 `target_user_id`、`relationship` 和 `followers_count`。POST 的 relationship 为 following，DELETE 为 none。计数采用现有 Oracle 触发器，缺失统计行按 0。
3. 关注生效并提交后，仅对新激活的关系调用公共通知服务。收件人的 follow 类型偏好决定是否存储，推送偏好控制即时推送。通知采用 actor 的公开昵称，类型为 follow，metadata.event 为 user_follow。通知故障记录安全日志，关注写入结果仍可返回。先前已提交的关注通知可能在后续取关或拉黑期间送达。
4. followers 返回目标的活跃粉丝，following 返回目标的活跃关注。mutual-following 返回当前查看者与目标都关注的账号。若目标无效或查看者与目标之间存在拉黑，返回空列表。过滤非活跃资料和与目标或查看者存在拉黑的候选人。总数和数据使用同一条 SQL，排序为粉丝数降序、创建时间降序、ID 升序。末页之后返回空数组并保留总数。
5. 列表绕过响应和数据库查询缓存，响应使用 `private, no-store`。返回公开资料，包含查看者相对该行用户的关系。列表不公开邮箱、手机号或在线活动时间。

共用的 SQL 位于 `user-visibility-sql.json`。隔离场景位于 `scenarios/user-follow.json`。真实 Oracle 锁、统计触发器、通知偏好、跨实例及两端部署矩阵仍待集中验收。
