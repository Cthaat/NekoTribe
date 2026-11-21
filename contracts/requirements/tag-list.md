# 标签搜索和热门标签共同需求

本需求覆盖 `GET /api/v2/tags` 与 `GET /api/v2/tags/trending`，以 Nuxt `v2SearchTags` 为基准。两个接口都要求有效 access token 及未撤销会话；Cookie 优先，失效凭据不能降级。用户输入不能选择身份。

普通标签列表读取 `q`，按 JavaScript trim、小写后绑定 `%q%`；空值使用 SQL NULL。`n_tags` 过滤 `(:q IS NULL OR name_lower LIKE :q)`，保留 SQL LIKE 的 `%`、`_` 通配符，重复参数遵循 `v2QueryString` 回退为空。热门标签只使用 `is_trending = 1`，忽略 q。分页使用 `page` 和 `page_size`，后端仍忽略旧 `limit` 参数。Flutter 搜索页请求热门标签时将所需数量传为 `page_size`。

Nuxt Web 和 Flutter 在登录用户提交帖子搜索后显示最多六个相关标签。点击标签用精确标签帖子接口打开对应列表。搜索帖子和标签独立加载，标签请求失败不影响帖子结果。搜索条件、登录身份或 Flutter 后端变更后丢弃迟到的标签响应。

两条接口均按 `trending_score DESC, usage_count DESC, updated_at DESC, tag_id DESC` 排序，并按排名返回页内结果。总数和当前页使用同一条 SQL 的同一份筛选数据，越界页返回空列表及实际总数。分页遵循 `post-list.md` 和 `v2Page`，page 默认 1 上限 10000，page_size 默认 20 上限 100，兼容当前小数及重复参数语义。

返回 `{code:200,message:'success',data:[{tag_id,name,usage_count,trending_score,is_trending,updated_at}],meta:{page,page_size,total,has_next}}`，数值按 Nuxt `v2Number`，日期按现有 `v2DateString`；空列表返回 `[]`。查询失败安全收口，不返回或记录底层 SQL、凭据和异常。共享多后端时结果缓存不得返回其他实现写入前的数据；真实失效协议和部署行为仍需验收。

共同样例是隔离输入和预期，不等同真实 Oracle 结果。最终需要真实数据库的大小写、通配符、排序、分页、日期、结构和权限验证，以及跨后端和两个客户端验证。
