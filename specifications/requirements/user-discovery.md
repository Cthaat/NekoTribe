# 用户搜索与推荐

搜索和推荐都要求有效且未撤销的登录会话，返回公开资料、经部署配置规范化的头像及查看者关系。默认在线状态为 offline，最后活动时间为空。响应使用 private, no-store，实时读取 Oracle。数据库或头像处理失败返回安全的 500。

- 搜索 `GET /api/v2/users` 只返回活跃账号。去除 q 首尾空白后按小写匹配用户名、显示名称或简介，保留 Oracle LIKE 的百分号和下划线语义。空 q 浏览所有活跃账号，搜索仍返回公开资料及拉黑关系标识。只有 verified=true 限制为认证账号。newest、oldest 按创建时间，followers、popular 和其他 sort 按粉丝数及创建时间降序。均以用户 ID 升序打破并列。分页沿用公共 page、page_size 规则，结果和总数取自同一条查询，空页仍返回总数。
- 推荐 `GET /api/v2/users/recommendations` 排除自己、已关注账号和任一方向已拉黑的账号。按粉丝数、帖子数和创建时间降序，用户 ID 升序。limit 默认 10，上限 50，沿用正有限数字解析规则，Oracle 取行数时舍去小数部分。响应 meta 仅包含 limit。[Oracle SQL 行数限制](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/SELECT.html)
- 重复或无效查询参数使用对应的默认值。接口接受现有 Nuxt Web 与 Flutter 客户端的查询形状。

Nuxt Web 在全局搜索中显示匹配账号，输入为空时可打开推荐列表。Flutter 搜索页可在帖子和用户之间切换，提交关键词后可继续分页，清空关键词后恢复推荐。结果行打开对应的公开资料。两个客户端在会话切换时清除已显示的用户结果，并丢弃之前会话的响应。

三套后端共用 `user-discovery-sql.json`。真实 Oracle、部署代理和客户端跨后端交互需在部署矩阵中验收。
