# 账号处置记录与申诉

三条接口要求有效会话，并从会话取得记录所有者。请求中的用户 ID 不参与查询。响应使用 private, no-store。

- `GET /api/v2/users/me/account-statements` 支持 status、type 精确筛选，缺失、空值和 all 表示不限。同一查询计算列表和总数，按创建时间、记录 ID 降序。空页仍返回总数，日期以 UTC 毫秒格式返回。
- `PATCH /api/v2/users/me/account-statements/{id}` 接受 mark_read、mark_unread、dismiss、resolve。只更新本人的记录，在提交前按同一所有者和记录 ID 回读状态。记录状态与申诉审核状态分别持久化。
- `POST /api/v2/users/me/account-statements/{id}/appeals` 接受去除首尾空白的申诉文本，长度为 1 至 2000 UTF-8 字节，拒绝 NUL。锁定本人的记录后读取待处理申诉。同一文本重试返回已有申诉 ID 和当前记录状态。不同文本在已有待处理申诉时返回 409。审核结束后可再次提交。新增申诉和更新记录状态为 appealed 在同一事务完成。

写入路径 ID 解码后须为无前导零的正十进制安全整数。验证失败返回 400，找不到本人记录返回 404，数据库错误返回安全 500。真实 Oracle 的行锁、时间格式和跨部署读写待验收。

Nuxt Web 与 Flutter 支持筛选、分页、标记已读或未读、忽略、解决及提交申诉。账号切换后清除旧列表，旧会话的申诉操作不得发出。待处理冲突显示已有申诉提示。
