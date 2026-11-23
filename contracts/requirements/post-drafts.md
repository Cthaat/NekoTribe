# 云端发帖草稿与定时发布

Nuxt Web 和 Flutter 可在普通帖及群帖编辑器手动保存草稿，并在连接同一套账号数据的设备中继续编辑、删除、立即发布或指定发布时间。AI 写作及群运营生成的内容可由用户带入编辑器和保存。生成、查看或重新打开 AI 回复不会产生草稿或排期。

`GET /api/v2/users/me/drafts` 按草稿 ID 倒序分页。`before_id` 为上一页返回的 `next_before_id`，`limit` 默认为 20、最大 50。传 `group_id=0` 仅列出普通帖草稿，传正整数仅列出指定群的草稿，省略时列出本人的全部草稿。`POST /api/v2/users/me/drafts` 保存新草稿，`PUT /api/v2/users/me/drafts/{id}` 保存完整草稿并清除原定时。`DELETE /api/v2/users/me/drafts/{id}` 删除草稿及其排期。所有接口要求登录，按当前用户限定 Oracle 记录，禁用响应缓存。其他账号的草稿返回 404。

草稿正文使用普通帖子或群帖字段。`group_id` 为 `null` 时支持 `visibility`、`media_ids`、`tag_names`、`mention_user_ids`、`location`，为正安全整数时支持 `media_urls` 与 `is_announcement`。两类均支持 `content` 和可选 `poll`。正文可为空，最多 4000 UTF-8 字节。地点和每个话题名称最多 100 字节。附件只保留既有上传引用。排期与发布须满足普通帖和群帖的正式创作条件。发布时复核账号、群写入、公告和附件权限。编辑器按现有媒体流程保留附件设置。

`PUT /api/v2/users/me/drafts/{id}/schedule` 在用户确认后以 `{scheduled_at}` 排期或重新排期，时间以 RFC 3339 表达，必须晚于数据库当前时间。附带的投票须在排期之后截止。`DELETE /api/v2/users/me/drafts/{id}/schedule` 取消定时并保留草稿。`POST /api/v2/users/me/drafts/{id}/publish` 立即发布，同一 ID 已发布时返回原发布回执。草稿状态为 `draft`、`scheduled`、`failed` 或 `published`，已发布的草稿不可编辑和排期。移除已发布的草稿只清理草稿记录。

三后端每 15 秒扫描一批到期草稿。先读取最多 20 个候选 ID，再按 ID、到期时间和状态尝试行锁 `FOR UPDATE SKIP LOCKED`。复用正常发帖写入，在同一 Oracle 事务内插入新帖并把草稿标成 `published`，事务提交后走既有通知。多后端和多实例共用同一约束。取消、编辑或另一实例发布后无法再次领取。Oracle 的行锁语义见 [19c SELECT 文档](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/SELECT.html)。

如果到期时权限已失效或内容不可发布，回滚任何已执行的发帖写入，保留草稿并记录 `permission_denied` 或 `content_unavailable`。用户重新编辑后可再次排期。临时数据库故障使事务回滚，保留排队状态供之后重试。三套后端按 Nuxt 迁移生成的目录执行只读就绪检查。结构未就绪时，草稿接口返回 503，后台扫描暂不执行。
