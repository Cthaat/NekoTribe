# 帖子编辑共同规则

版本：1。`PATCH /api/v2/posts/{id}` 与 `PUT /api/v2/posts/{id}` 使用相同的部分更新语义，PUT 不是全量替换。本规范保留现有字段转换，修正逐步提交及缺少并发所有权约束的问题。

## 请求

有效 access 会话后检查路径 canonical 正安全整数，再解析对象正文。正文、非法 JSON、数值/标签数组转换沿用 `post-create-request.md` 的规则及已记录框架差异。只允许读取 content、visibility、language、location、media_ids/mediaIds、tag_names/tagNames、mention_user_ids/mentionUserIds；客户端 author_id、post_type、引用字段不能修改身份或类型。

省略字段保留原值；存在的 null、数组、对象在字符串字段转换为空字符串，数字/布尔值转 JavaScript 字符串，字符串保留空白。content/location 空字符串绑定 null，非空空白原样保存。visibility 存在时只接受四个精确枚举，null/空串不是省略而是 400 `visibility 参数错误`。language 先 trim 和转小写，空值归 zh；非空必须匹配 `^[a-z]{2}(-[a-z0-9]{2,7})?$`，否则 400 `language 参数错误`。

关系字段按 snake_case 是否存在优先，null、非数组或空数组明确清空；省略保持原关系。数组先按创建规则转换，再在仓储按媒体 4、标签 20、提及 50 的去重及上限规则处理。无可修改字段的对象是合法空操作，不改变 updated_at。

## 单连接事务

解析完成后，在同一连接和事务中 SELECT 帖子作者、删除状态、类型及内容摘要并 `FOR UPDATE`。不存在/已删除为 404 `帖子不存在`，其他作者为 422 `只能修改自己的帖子`；管理员无额外编辑权限。锁必须覆盖后续有效内容检查、媒体计数、所有字段和关系写入，提交或回滚后释放。非转发帖子更新后的内容 trim 为空且媒体数为零时拒绝 400 `content 不能为空`；省略内容仅用于校验而非用摘要覆盖完整 CLOB。

有可修改字段或关系时，绑定参数更新字段及 updated_at，WHERE 同时约束 post_id、author_id、is_deleted=0；零行更新返回 404。仅删除并重建明确传入的关系。每个媒体必须属于当前用户且状态为 uploaded/processing/ready，条件附加不是一行时为 400 `附件不存在或无权使用`，整笔回滚。标签合并、关系清空、附加失败均回滚之前字段及关系；所有 DML 禁止 autoCommit。

成功只提交一次，包括空操作释放读锁。事务内读取/写入/提交失败尝试回滚；回滚错误返回安全内部错误。提交失败可能已经持久化，禁止声称一定撤回或自动重试。最终完整帖子映射在提交后执行，不递增浏览量，不发送创建/提及通知；映射失败不会回滚成功提交。响应 HTTP 200/code 200/message `post updated`，data 为完整帖子，meta=null；业务错误采用现有 v2 envelope，意外错误为安全 500。所有业务响应 private/no-store，缓存规则沿用共享后端规范。

当前内容摘要仍按既有 Nuxt 的前 4000 字符参与空内容校验。真实 Oracle 的锁、CLOB/浮点数绑定、触发器、跨后端并发、缓存及两客户端仍需集中验收；隔离事务替身不能证明这些能力。POST 创建、DELETE 软删除及 PATCH/PUT 编辑在共同数据上都必须遵守同一作者和删除状态约束。
