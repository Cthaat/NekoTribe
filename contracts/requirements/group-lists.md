# 群组发现、热门与我的群组

GET /api/v2/groups、GET /api/v2/groups/popular 和 GET /api/v2/users/me/groups 需要有效会话。均只读取启用且未删除的群组，复用群组详情的公开群主资料、标签和当前用户成员状态。安全策略及权限变化须从当前数据库读取，响应为 private, no-store。

群组发现返回公开群组和当前用户拥有有效 active 成员记录的非公开群组，按成员数、发帖数、创建时间、群组 ID 降序。「我的群组」仅返回当前用户的 active 成员记录，按加入时间和群组 ID 降序。两个接口共用 q、privacy、category 及分页。q 去首尾空白并忽略大小写，按原有 LIKE 匹配群名或描述。privacy 精确匹配。category 去首尾空白，支持 tech、game、music、art、life、study、work、other，无效值返回 40001。分页包含 page、page_size、total、has_next。

热门仅返回公开群组。activity_score 为成员数乘 0.3 与发帖数乘 0.7 的和，保留两位小数。按分数、成员数、群组 ID 降序，limit 默认 10、最大 50；返回 meta.limit。群组详情字段来自同一群组数据，热门视图的排名不得将审批和发帖权限替换为默认值。无结果时 data 为 []。真实 Oracle 和客户端联调待验收。

Nuxt Web 与 Flutter 的「发现群组」和「我的群组」均可将关键词、隐私和分类组合发给服务端。Flutter 两个标签各自保留已应用的筛选；应用或清除后从第一页开始，继续翻页使用相同条件。改变筛选后不接收旧请求的结果。Flutter 切换会话或后端时清空旧列表。

Nuxt Web 与 Flutter 均提供「热门群组」入口，调用 `/api/v2/groups/popular` 读取前 10 项，按服务端排序展示并允许进入群组详情。热门列表不继承发现列表的筛选或分页，返回发现时保留原筛选。刷新及切换会话或后端时沿用各客户端的请求失效规则。
