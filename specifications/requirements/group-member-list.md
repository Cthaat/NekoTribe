# 群组成员列表

GET /api/v2/groups/{id}/members 要求有效会话、正十进制安全整数 ID，响应使用 private, no-store。停用、软删除或不存在的群组返回 40401。

已登录且未被封禁的用户可查看公开群组的正常成员。私密和秘密群组要求查看者为 active 或 muted 成员。只有状态为 active 的群主、管理员和版主可查看 pending 和 banned 成员，其他允许访问的查看者仅可查看 active 和 muted 成员。封禁或缺少私密群组成员资格返回 40301。筛选条件不会扩大可见范围。

支持 role 和 status 单值精确筛选，空值表示不筛选，非法或重复值返回 40001。沿用 v2 的 page 和 page_size 默认值及上限。只纳入有有效公开账号资料的成员。排序依次为角色级别、加入时间升序、member_id 升序。total 和 has_next 基于权限与筛选后的数据，超出末页返回空数组和完整分页元数据。

成员数据包括 member_id、user、role、role_desc、status、nickname、mute_until 和 joined_at。user 复用公开资料及查看者关系映射。mute_until 只对本成员和具有管理权限的查看者返回，其余为 null。

Nuxt Web 群组详情和管理页、Flutter 群组管理页沿用现有端点。真实 Oracle 和客户端组合待验收。

两个客户端的管理页可按 `has_next` 继续加载成员。翻页按成员记录 ID 去重，保留已加载记录的次序。成员搜索只筛选已加载的记录。刷新期间作废先前的翻页结果，Nuxt Web 在关闭管理面板或认证身份变化时清除成员列表。
