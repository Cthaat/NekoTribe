# 当前用户资料更新

`PATCH /api/v2/users/me` 以已验证 access token 和数据库会话确定用户，不能通过请求体或查询指定其他用户。鉴权及会话 touch 先于解析请求体；Cookie 优先规则与 `user-self-profile.md` 一致。成功返回与 GET 相同的完整个人资料，不设置 Cookie，并设置 `Cache-Control: private, no-store`。

只识别 `display_name`、`bio`、`location`、`website`、`phone`、`birth_date`，未知字段忽略。每个字段仅在请求对象自身包含该键时更新；字符串保留原样，不 trim，数字和布尔值按 JavaScript 字符串化，null、数组和对象转为空字符串。Oracle 将空字符串视为 NULL。日期采用 `CASE WHEN :birth_date IS NULL THEN NULL ELSE TO_DATE(:birth_date, 'YYYY-MM-DD') END`，非法日期或字段长度/约束由数据库处理并返回安全 500，不泄露数据库错误。不得因缺失字段覆盖原值。对象无已识别字段时不发 UPDATE，仍读取资料。

更新按用户 ID 绑定参数且独立提交，之后查询当前用户资料；没有匹配用户或资料查询无记录时返回 404。UPDATE 的提交成功后如果读取或关闭连接失败，不能声称更新已回滚。客户端或代理重试可能重复写入；不承诺幂等副作用或跨语句快照。body 支持 JSON 对象及 URL 编码表单；非对象拒绝 400。三套后端按实际读取的字节将请求体限制在 1 MiB，超限返回 400 / 40001 且不更新或读取用户资料。空字符串及 null 的数据库驱动绑定、日期解析、表触发器、连接关闭、跨实例缓存与并发语义必须在真实 Oracle 验证；隔离替身不可代替。

不通过代理 Nuxt；不可写账号、邮箱、头像、权限或其他用户字段。更新和后续读取失败统一安全错误，不能泄露 SQL、地址或资料；不记录私有字段值。共同合成场景 `scenarios/user-self-profile-update.json` 不是最终业务验收。

Nuxt Web 与 Flutter 提供六个已有资料字段的编辑入口。手机号可清空为字符串 `""`，生日发送 `YYYY-MM-DD`，清空时允许 null 或空字符串。客户端从当前用户资料填入表单，通过接口回执的用户 ID 确认成功。请求失败保留表单，账号会话变化后丢弃旧回执，Flutter 切换后端后也需重新打开编辑页。
