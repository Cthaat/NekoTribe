# 帖子列表与搜索共同要求

本切片目标是 `GET /api/v2/posts`；Nuxt `server/services/v2/posts.ts` 的 `v2ListPosts` 为现有业务来源，Rust/Go 已接入原生列表并通过局部隔离测试，尚未完成全部共同场景和真实环境验收。热门、个人、用户、标签、回复和转发列表复用部分同一服务，但各自路由和授权尚需独立审查，不能因本切片而宣布其完成。

## 身份和过滤

- GET 列表可以匿名，若带 Cookie 或 Bearer 则必须正常验证 access token 和会话；失效凭据不能降级为匿名，Cookie 优先。viewer 使用认证会话 ID，不能采用查询参数。`timeline=following` 与 `timeline=mentions` 仅登录后可用，其他 timeline 值按普通列表处理，区分大小写。
- 所有列表和总数都绑定同一 viewer，应用 `fn_can_view_post(:viewer_id,v.post_id)=1`；匿名 viewer 为数据库 NULL。`following` 额外限定 `n_user_follows` 中 viewer 关注作者且状态为 `active`，`mentions` 额外限定 viewer 被当前帖子提及。不可用客户端输入拼接 SQL。
- `q` 经 trim 和小写后，按 `%q%` 查询内容前 4000 字符、位置或标签；标签查询另外去除开头的所有 `#` 后 trim，为空则回用原 q。保持现有 Oracle LIKE 语义：`%` 和 `_` 是通配符，不做隐式转义。空 q 不加搜索过滤。搜索由参数绑定，不能把文本拼接进 SQL。
- `sort=oldest` 按创建时间升序，`popular` 按互动分降序、创建时间降序，其他值按创建时间降序；现有规则不保证相同排序键的稳定次序。不要虚构 tie-breaker 改变兼容行为。

## 分页和输出

- Nuxt 使用 `v2Page`：`page` 默认 1、上限 10000，`page_size` 默认 20、上限 100；非正数或不可转为有限数采用默认。其当前 Number 解析还接受小数、科学计数法和部分数字格式，重复查询参数被当成非字符串回退。是否收紧这些边界应作为明确的三端兼容变更处理，不能偷偷只在 Rust/Go 收紧。
- 分别执行使用相同 WHERE 和参数的 COUNT 和带 `ROW_NUMBER` 的分页查询；区间是 `(page-1)*page_size+1` 到 `page*page_size`，返回 `meta={page,page_size,total,has_next}`，其中 `has_next=page*page_size<total`。两个查询并发写入时不保证一致性快照，真实 Oracle 对小数分页的行为仍需测试。
- 每个结果采用 `post-detail.md` 所定义的作者、媒体、标签、提及和 viewer_state 映射，列表读取不增加浏览量。现有 Nuxt 是对查询结果并行展开关联数据，可能多次执行媒体结构只读检查；空列表无需媒体结构检查。结构不兼容返回安全 503，其余内部异常不得泄漏数据库细节。
- 共享后端部署不得让结果缓存返回其他后端写入前的数据；目前 Nuxt 默认共享安全模式禁用结果缓存，单后端模式的 TTL 行为不作为跨后端同步方案。

## 验收边界

`scenarios/post-list.json` 是待三端执行的共同验收清单；三端已有各自的局部隔离测试，涵盖匿名/认证过滤、分页、错误及搜索 SQL 绑定，但不是完整共同 runner，也不证明真实 Oracle LIKE、函数、排序、并发或数据库结构。URL 畸形编码和 Unicode 小写在不同运行时的边界仍需跨语言专项对照。最终须阻断 Nuxt 上游分别验证 Rust/Go，使用隔离 Oracle/Redis 和两种前端验证数据读写、搜索、权限、分页和失败响应。
