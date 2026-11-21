# 创建群组

- `POST /api/v2/groups` 要求有效会话，JSON 对象不超过 1 MiB。成功返回 HTTP 200、`group created` 和完整群组详情。响应使用 `Cache-Control: private, no-store`。
- `name` 必填，须是非空白字符串且原值不超过 100 UTF-8 字节，存储时去除首尾空白。`description`、`avatar_url`、`cover_url` 可省略或为 null，字符串最多 500 UTF-8 字节。`category`、`tags` 与群组设置共用验证和规范化。
- `privacy` 默认为 `public`，可取 `public`、`private`、`secret`。`join_approval` 默认 false，须为布尔值。`post_permission` 默认为 `all`，可取 `all`、`admin_only`、`moderator_up`。参数错误返回 400。
- Slug 采用小写群名，保留 ASCII 字母、数字和 U+4E00 至 U+9FA5 的字符，其他字符合并成连字符。空基名使用 `group`，截断时保留完整字符和尾部 `-<group_id>`，总长不超过 100 字节。
- 分配 Oracle 序列 ID，在同一事务写入群组、创建者的活跃 owner 成员记录、标签和 `create_group` 审计，再读出完整群组详情，只在事务提交后返回成功。成员计数由现有触发器更新。写入、回读或提交失败返回 500。
- Nuxt Web 与 Flutter 通过同一端点提交现有表单，成功后使用返回的群组详情更新页面。
- 托管群组图标和横幅在写入前与媒体删除按同一媒体行锁串行化。图片已删除时返回 40001 并回滚。详细 URL 识别和锁顺序见 `media-upload.md`。
