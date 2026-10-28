# 通知删除与恢复共同需求

`DELETE /api/v2/notifications/{id}` 和 `PUT /api/v2/notifications/{id}/restore-status` 需要有效会话，只能操作当前用户的通知。路径 ID 为不带前导零的安全正整数（1 至 9007199254740991）；此规则收紧了原 Nuxt 的宽松数字解析。接口使用 `private, no-store` 并对数据库错误脱敏。

删除只更新匹配用户且尚未删除的通知，将 `deleted_at` 设为数据库当前时间。零行（不存在、属于其他用户或已删除）返回 404 `通知不存在`；更新后再次按用户和通知 ID 查询删除时间，行已消失时事件时间为 null。成功返回 `{code:200,message:"notification deleted",data:null,meta:null}` 并发布 `notification_deleted`，数据为 `{notification_id,deleted_at}`。

恢复按用户和通知 ID 清空 `deleted_at`，不要求此前必须已删除；零行返回相同 404。成功返回 `{notification_id,deleted_at:null}` 并发布 `notification_restored`，事件数据与返回数据相同。每次成功恢复均发送事件，包括重复恢复。数据库更新、删除后读取与 Redis 事件并非一个原子操作；读取失败可能发生在删除已提交之后，Redis 失败只降级实时推送。

真实 Oracle 日期与时区、自动提交、并发恢复和删除、跨实例 Redis 事件，以及 Nuxt Web 和 Flutter 联调尚待隔离环境验收。
