# 当前用户资料

`GET /api/v2/users/me` 由 Nuxt、Rust、Go 各自实现，Nuxt Web 与 Flutter 使用同一接口。身份只能从已验证的 access token 及未撤销、未过期的数据库会话取得，不能由 query 或请求体选择用户；access Cookie 有效值优先于 Authorization。缺失令牌或令牌/会话无效返回 401；会话检查失败安全拒绝，不能返回资料。

通过验证后，使用认证用户 ID 同时绑定 `viewer_id` 和 `user_id` 查询 `v_user_profile_self` 及相关会话数据，复用登录/注册的资料字段、默认值和头像公共地址规则。无记录返回 404 `用户不存在`，数据库及地址映射失败返回安全 500；成功响应为 `{code:200,message:"success",data:V2SelfUser,meta:null}`，设置 `Cache-Control: private, no-store`，不创建会话或设置 Cookie。返回的 email、phone、birth_date 等仅属于当前用户，不得泄露其他用户资料或内部错误。

资料包括公开字段、关系、在线状态、最后活动、邮箱、电话、生日、邮箱验证时间、状态和创建/更新时间；日期和空值规则继承现有 self profile 映射。Nuxt 该接口绕过响应缓存，因为其他后端对共享数据的修改不保证触发 Nuxt 缓存失效。SQL 中存在 `n_auth_sessions`，其查询缓存需保持绕过。此规则不声称其他用户列表、帖子或所有缓存均已跨后端同步。

Nuxt Web 和 Flutter 账号页只使用符合上述成功回执、且 `user_id` 为正安全整数的资料。开始切换身份时清空账号页旧资料，切换结束后重新请求，忽略过期的成功或失败响应。Flutter 切换后端时同样执行该规则。当前资料读取失败可重试。Nuxt 账号头部的分析数据单独加载，失败时资料仍可使用，过期分析也不能修改当前账号。

`scenarios/user-self-profile.json` 是合成的 HTTP 场景；实际 Oracle 视图/函数、时区、账号停用策略、跨实例数据变更及 Nuxt Web/Flutter 联测尚需最终环境验收。会话有效性与访问令牌遵循 `authentication.md`，头像转换遵循 `storage-public-urls.md`。
