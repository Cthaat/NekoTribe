# AI 权限接线的源码依据

用户确认：登录用户使用问答/写作；目标群管理员使用运营 Agent；平台审核人员使用审核助手。以下是 2026-10-27 的静态源码核对，尚无 AI 业务端点或真实权限验收。

| 入口 | 当前依据 | 接线约束/待验证 |
| --- | --- | --- |
| 登录身份 | `server/middleware/auth.ts` 的 v2 access JWT、sessionId/jti、`n_auth_sessions` 有效会话匹配；`server/utils/v2.ts` 的 `v2Auth` 读取已验证 context | 三后端应查询当前会话，不能仅解析 token 或相信客户端 userId。撤销/过期会话不能继续生成。当前已实现的 Rust/Go token codec 不包含此数据库判断。 |
| 目标群管理员 | `server/services/v2/groups.ts` 的 `v2GroupPermission` 调用 `fn_has_group_permission`；权威初始化 SQL `data/neko_tribe-oracle-v2.sql` 的 `fn_get_member_role`、`fn_has_group_permission` | 角色层级 owner=4/admin=3/moderator=2/member=1；以 admin 为门槛包含群主，不包含版主/普通成员。必须按目标 groupId 查询；其他群管理员、仅平台审核身份或前端字段不能自动获得群 Agent 权限。 |
| 平台审核人员 | `server/services/v2/moderation.ts` 的 `requireModerationAccess` 读取 active 用户的 username/email，并匹配 `MODERATION_ADMIN_ACCOUNTS`；缺省白名单为 `v2_admin` | 现有源码不是通用数据库 RBAC，不能编造已存在的 moderator 全局角色。正式接线须明确三后端相同的有效人员配置/撤权规则，并以实际身份匹配。 |

现有 moderation 还有 `MODERATION_ALLOW_ALL` 历史放行分支，提前返回任何登录用户。它不是“仅审核人员”的证明，不得把现有 helper 名称或页面隐藏当作 AI 审核权限验收。后续 AI 接线必须明确拒绝普通用户，并核对该开关不会扩大用户已确认的 AI 权限；此记录不修改现有审核模块行为。

`fn_get_member_role` 及调用它的 `fn_has_group_permission` 接受 active/muted；`fn_is_group_member` 仅接受 active。退出、待审核、不在群、封禁不应成为管理员来源。生成过程中发生会话撤销、群权限撤回，以及确认发布/处置前的再次授权，仍需在实际业务执行器中验证。首期公开内容范围独立于角色，拥有管理员身份也不自动允许检索私密群内容。

`server/utils/auth.ts` 含 fake-jwt 工具；当前全工程调用搜索只命中自身定义。AI 接线应复用真实 v2 认证链路，不得使用该演示工具。该观察不代表对全工程安全性的完整审计。

本次只读源码，未读取私有环境、查询数据库、登录真实账号或修改身份。权限业务尚未实现；合成 token、模型配置/HTTP 组件测试不能记作本表权限通过。
