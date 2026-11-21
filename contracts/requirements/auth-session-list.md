# 认证会话列表

`GET /api/v2/auth/sessions` 列出当前用户尚未撤销的会话，不代理到其他后端。复用认证与会话触碰规则：Cookie 优先、验证 access token 并且只在数据库 touch 恰好一行后读取；失败返回既有安全 401，查询失败返回安全 500。每次请求直接读取共享数据库，不复用 API 响应缓存。

总数与分页行在同一条 Oracle 查询中读取，候选来自该用户 `revoked_at IS NULL` 的全部会话。按 `last_accessed_at DESC, session_id ASC` 分配行号，并按行号返回。已过期但未撤销的会话仍包含在内。请求超出末页时返回空数组，仍提供该次读取的总数。每项仅返回 `session_id`、`device_info`、`ip_address`、`last_accessed_at`、`created_at`、`is_current`，不返回 token、哈希或其他用户会话。空字符字段转空字符串，日期按现有 Nuxt 映射输出，当前会话标记比较认证 session ID。

分页沿用 Nuxt `v2Page`：`page` 默认 1，上限 10000；`page_size` 默认 20，上限 100。参数按 JavaScript Number 转换，非有限、非正数和重复参数使用默认值；正小数保留，低于 1 的正数截断到 1。`start=(page-1)*page_size+1`、`end=page*page_size`，不对正小数取整；meta 返回 `page`、`page_size`、`total`、`has_next`。这记录既有行为，不为本接口单独引入向下取整等不兼容规则。共享输入样例位于 `scenarios/auth-session-pagination.json`。

Nuxt Web 与 Flutter 读取 V2 信封中的 `data` 数组和顶层 `meta`，每页请求 20 条，保留服务端的本设备标记。列表刷新使用当前页，末页变空时可回到第一页。登录会话改变或 Flutter 切换后端时，清空当前列表和分页，忽略原请求的回执。

不同语言 Oracle 驱动和服务器时区的 DATE/TIMESTAMP 处理、同一数据库跨实例访问、分页并发与数据库排序仍需隔离真实 Oracle 验证；单元测试和编译不等于生产或三后端业务验收。认证成功的 touch 先于查询，后续查询失败不撤销该 touch。
