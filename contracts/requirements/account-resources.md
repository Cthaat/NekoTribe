# 个人资源与数据导出

三后端通过已登录会话识别当前账号。接口只读，所有成功响应使用 `Cache-Control: private, no-store`。服务端从会话取用户 ID，查询参数不能指定其他用户。

## GET /api/v2/users/me/usage

返回 V2 成功信封。数据包含 `ai_quota`（`used_units`、`limit_units`、`window_seconds`）、`media`（`bytes`、`files`）及 `ai_history`（`conversations`）。配额按现有 Redis 账号键和配置读取，请求不消费额度或刷新窗口。有效 Redis 中不存在账号键时用量为 0。Redis 失败时用量为 null，配置无效时上限为 null。账号历史统计仅计其持有的会话。媒体统计计入账号已上传且处于 ready 状态的媒体记录，以原文件字节为准。

## GET /api/v2/users/me/export

`format` 默认 `json`，也可选 `markdown`，其它值返回 400。返回 UTF-8 下载文件 `nekotribe-account.json` 或 `nekotribe-account.md`。

导出包含两份列表，均按 ID 升序。本人未删除且当前可见的帖子包括 `post_id`、`content`（允许 null）、`created_at`。本人收藏只导出仍可见帖子的 `post_id` 与收藏 `created_at`，不复制他人正文。帖子可见性沿用现有 Oracle 规则。导出不访问账户凭据、AI 正文或媒体存储。Markdown 将帖子正文作为缩进代码块显示原文。
