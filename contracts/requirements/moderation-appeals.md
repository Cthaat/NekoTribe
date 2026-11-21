# 审核员申诉列表与处理

`GET /api/v2/moderation/appeals` 和 `PATCH /api/v2/moderation/appeals/{appeal_id}` 需要有效会话。三后端的审核和 AI 审核助手共用平台审核员账号配置，当前启用账号的用户名或邮箱须匹配 `MODERATION_ADMIN_ACCOUNTS` 中显式配置的值。名单缺失、为空或只有空白时拒绝审核访问。显式开启 `MODERATION_ALLOW_ALL` 时沿用现有测试行为。审核权限先于业务查询和写入。两条接口均返回 private, no-store。

- 列表支持 all、pending、approved 和 rejected 筛选。缺失或重复的筛选值使用 all，未知值沿用 pending。按创建时间、申诉 ID 降序，用同一个查询读取过滤后的总数和分页。空页保留总数。申诉人只返回公开资料，日期为 UTC 毫秒格式。
- 写入以正十进制安全整数定位申诉。请求使用 `appeal_status` 指定 approved 或 rejected。可选的 `admin_response` 去除首尾空白，最多 2000 UTF-8 字节，拒绝 NUL，空回复返回空字符串。
- 审核时锁定当前申诉。待处理申诉的决定和审核操作日志在同一 Oracle 事务中提交。日志使用 `appeal_approved` 或 `appeal_rejected`，保留审核员与目标账号，并在 reason 记录 `appeal:<id>`。提交前回读本次结果。已处理申诉收到相同决定及回复时复用已有结果，不新增日志。收到不同决定或回复时返回 409。审核状态和账号处置记录状态单独保存，沿用原有审核语义。

无权限返回 403，格式错误返回 400，找不到申诉返回 404，存储故障返回安全 500。真实 Oracle 并发、部署权限配置和两客户端对三后端的组合仍待联调。

Nuxt Web 和 Flutter 均支持按审核状态筛选和分页、查看已提交的回复、对待处理申诉作出决定。发生冲突时提示并重新加载列表。切换账号时清除列表并阻止旧会话中的决定提交。
