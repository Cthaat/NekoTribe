# 当前登录用户查看公开用户资料

`GET /api/v2/users/{id}` 需要有效 access token 与未撤销、未过期的数据库会话。先完成鉴权和会话 touch，再验证路径 ID；Cookie 优先于 Authorization。ID 采用统一十进制正整数规范：ASCII 数字，无前导零，范围 1..9007199254740991。旧 Nuxt `Number()` 接受小数、科学计数法、十六进制和不安全整数；此切片修正其边界，普通数字 ID 不受影响。失败返回 400 `id 参数错误`。目标身份只由路径决定；查看者只能来自会话，不接受查询参数或请求体冒充。

三后端直接查询共享 Oracle `v_user_profile_public`，要求 `is_active=1`，绑定 viewer_id 和 user_id，并按同一 SQL 计算关系与在线状态：`show_online_status=0` 时状态 hidden 且 last_seen_at 为 null；否则只有未撤销会话在最近 90 秒内活动才 online，其他为 offline；last_seen_at 是未撤销会话最近活动。无资料或停用返回 404 `用户不存在`。关系由 `fn_get_user_relationship` 对当前查看者计算。接口沿用现有 Nuxt 行为：不额外根据屏蔽关系拒绝读取，另需由产品统一审查隐私政策。

只返回 public 字段：user_id、username、display_name、avatar_url、bio、location、website、is_verified、followers_count、following_count、posts_count、likes_count、relationship、online_status、last_seen_at。不得泄露 email、phone、birth_date、认证数据或底层错误。头像遵守共同公共存储地址规则。成功设置 `Cache-Control: private, no-store`；内部异常统一安全 500。代码和合成场景不证明真实 Oracle 时区、隐私策略、跨后端实时数据或双客户端验收。

两客户端的公开资料页按相同的安全整数规则解析链接，验证回执中的数字型用户 ID 与请求相符。确认资料后再加载该用户的帖子。帖子读取失败时资料仍可见，可单独重试帖子；资料请求失败则在资料入口重试。切换目标用户、账号或 Flutter 后端时，清除旧资料和分页状态并忽略过期回执。
