# NekoTribe 未实现功能盘点

> 更新日期：2026-05-19
> 原始扫描日期：2026-05-09
> 本次核对范围：`app/`、`server/api/v2/`、`server/services/v2/`、`server/routes/`、`doc/neko_tribe-oracle-v2.sql`、`package.json`。
> 判定口径：页面已有入口但只改本地状态、service 空实现、后端 stub、前后端未接线、设置字段没有业务执行链路，均视为未完成或半完成。
> 说明：原文档中“聊天、审核、实时能力完全未实现”的结论已经过期；这些模块当前已有正式实现基础，本文档改为记录当前仍然缺口明确的功能。

## 总体结论

项目当前已经补齐了大量 2026-05-09 扫描时缺失的 v2 能力：

- 聊天/群组频道已经有 `server/api/v2/chat` 路由、`server/services/v2/chat.ts` 服务、`n_chat_*` / `n_direct_*` 数据表，以及 `app/pages/chat.vue` 的真实 API 和 WebSocket 接入。
- 内容审核已经有 `server/api/v2/moderation`、`server/api/v2/reports`、`server/services/v2/moderation.ts`、`n_moderation_*` 数据表，以及审核内容、用户、举报、设置页面的真实接入。
- 实时能力已经有 v2 token/session 鉴权的 `/_ws`，通知邮箱订阅 `useRealtimeSocket`，通知实时事件、在线状态和新设备登录提醒链路也已存在。
- 推文编辑、媒体 alt 文本、群组设置弹窗、群成员管理、群帖子点赞/置顶/删除等能力已有实现基础。

当前最明显的未完成区域已经收敛为：

1. 群组邀请收件箱、群通知开关、群组分类/标签、群帖子评论/举报等群组细节仍有前后端断点。
2. 账户安全里的 2FA 和删除账号仍是字段或路线图级能力，缺少可执行闭环。
3. 内容体验里的“我的点赞”、部分回复入口和媒体 description 仍未补齐。
4. 推荐反馈仍是 accepted stub，没有落库或参与推荐逻辑。
5. 诊断/测试页面仍在正式路由树中，且项目缺少 lint/test 质量闸门。

## 优先级说明

| 优先级 | 含义 |
| --- | --- |
| P0 | 页面已有入口但用户无法真正使用，或已有 API/数据模型但前端关键入口断开。 |
| P1 | 主流程可用，但关键体验、安全约束或数据闭环缺失。 |
| P2 | 不阻塞核心使用，但会影响长期体验、治理质量或可维护性。 |

## 已不再归类为未实现的能力

这些是原文档中列为 P0/P1 的内容，但当前代码已经有正式实现基础；后续应作为验收/边界测试，而不是继续当作“未实现”。

| 模块 | 当前实现基础 | 仍需验收重点 |
| --- | --- | --- |
| 聊天/群组频道 | `server/api/v2/chat`、`server/services/v2/chat.ts`、`app/api/v2/chat.ts`、`app/services/chat.ts`、`app/pages/chat.vue`；SQL 中已有 `n_chat_channels`、`n_chat_messages`、`n_chat_message_media`、`n_chat_message_reactions`、`n_chat_channel_reads`、`n_direct_conversations`、`n_direct_messages` 等表。 | 多账号实时收发、频道权限、断线重连、私信隐私、消息附件、删除/编辑/置顶/反应的跨端同步。 |
| 内容审核中心 | `server/api/v2/moderation`、`server/api/v2/reports`、`server/services/v2/moderation.ts`；前端 `content/users/reports/settings` 页面已调用真实 service；SQL 中已有 `n_moderation_reports`、`n_moderation_cases`、`n_moderation_actions`、`n_moderation_user_restrictions`、`n_moderation_settings`。 | 审核员权限配置、批量动作、领取/释放、封禁/禁言副作用、申诉结果回写、真实统计准确性。 |
| 实时通知与在线状态 | `server/routes/_ws.ts` 已校验 access token、session、`access_jti`；`useNotificationMailbox` 订阅 `useRealtimeSocket`；`server/services/v2/notifications.ts` 发布通知创建/已读/删除/恢复事件；`server/services/v2/presence.ts` 支持在线/离线/隐藏状态。 | 多实例 Redis fanout、页面登录态失效时的断连、隐私开关生效、通知偏好过滤。 |
| 登录提醒 | `server/services/v2/auth.ts` 会识别新设备并调用 `v2CreateNotification()`，尊重 `login_alerts` 和邮件通知设置。 | 邮件配置、设备指纹稳定性、误报/重复提醒、提醒入口跳转。 |
| 推文编辑 | `PUT /api/v2/posts/:id`、`server/services/v2/posts.ts::v2UpdatePost`、`app/services/posts.ts::v2UpdatePost` 和 `app/pages/account/posts.vue` 已接入。 | 时间线/详情页是否需要直接编辑入口、编辑历史、编辑窗口、通知/缓存刷新。 |
| 媒体 alt 文本 | `TweetComposer` 已支持每个媒体草稿填写 `altText` 并随上传提交。 | 展示端可访问性、编辑媒体 alt、description 字段。 |
| 群组管理基础 | `GroupManageModal` 已接入更新群组、删除群组、审批成员、移除成员、角色调整、禁言/解禁、转让所有权、创建/查看/复制群邀请。 | 收件箱、通知偏好、分类标签、群帖子评论/举报、管理动作权限边界。 |
| 通知邮箱核心动作 | `MailDisplay` 当前只保留已接线的已读/未读、删除、恢复等动作，旧版“归档/稍后/转发/标签”等未接线按钮已不再作为主要问题。 | 是否需要扩展成真正邮箱式工作流。 |

## P0 未完成/半闭环功能

### 1. 群组邀请收件箱仍为空实现

**当前状态**

- `app/pages/groups/invites.vue` 已有“我的邀请”页面，会调用 `listMyGroupInvites()`。
- `app/services/groups.ts` 中 `listMyGroupInvites()` 仍直接返回空数组。
- 后端已有“某个群组的邀请列表”接口：`GET /api/v2/groups/:id/invites`，适合群管理员查看自己群内的邀请记录。
- 但没有发现面向当前登录用户的“我收到的待处理邀请”接口，例如 `GET /api/v2/users/me/group-invites` 或 `GET /api/v2/groups/invites?scope=received`。

**证据**

- `app/services/groups.ts:684` 至 `app/services/groups.ts:688`
- `app/pages/groups/invites.vue`
- `app/api/v2/groups.ts:336` 至 `app/api/v2/groups.ts:360`
- `server/api/v2/groups/[id]/invites.get.ts`
- `server/api/v2/groups/invites/[invite_id]/responses.post.ts`

**缺口**

- 新增当前用户收到的邀请列表 API，查询 `n_group_invites.invitee_id = 当前用户` 且 `status = 'pending'`、未过期的记录。
- 前端补齐 `listMyGroupInvites()` 映射到 `GroupInviteView[]`。
- 接受/拒绝后刷新收件箱，并同步群组成员状态。
- 明确公开邀请码和定向邀请的展示规则：公开邀请码不应出现在“我的邀请”收件箱里。

### 2. 群通知开关只改本地状态

**当前状态**

- `GroupDetailModal` 右上角有通知开关。
- 点击后只切换本地 `notificationsEnabled` 并 toast，没有调用 API，也没有写入数据库。
- SQL 中只有全局通知偏好 `n_notification_preferences`，没有用户-群组粒度的通知偏好表。

**证据**

- `app/components/GroupDetailModal.vue:81`
- `app/components/GroupDetailModal.vue:143` 至 `app/components/GroupDetailModal.vue:149`
- `doc/neko_tribe-oracle-v2.sql:739` 至 `doc/neko_tribe-oracle-v2.sql:752`

**缺口**

- 设计用户-群组通知偏好，例如 `n_group_notification_preferences` 或复用现有通知偏好并扩展资源维度。
- 新增查询/更新接口，例如 `GET/PUT /api/v2/groups/:id/notification-preference`。
- 群组帖子、评论、邀请、聊天消息等通知生成时读取该偏好。
- 前端打开群详情时加载真实状态，切换后持久化并处理失败回滚。

### 3. 群组分类/标签 UI 与数据模型不一致

**当前状态**

- 创建群组 UI 强制填写 `category`。
- `createGroup()` 组装 v2 payload 时没有提交 category/tags。
- `mapV2GroupToGroup()` 返回 `tags: []`，没有真实分类/标签数据。
- `n_groups` 表没有 `category` 或 tags 字段，也没有群组-标签关联表。
- `filterGroups()` 只有当返回的 group 带 category 时才按分类过滤，因此当前分类筛选实际基本不会生效。

**证据**

- `app/components/CreateGroupModal.vue:285` 至 `app/components/CreateGroupModal.vue:290`
- `app/services/groups.ts:100` 至 `app/services/groups.ts:122`
- `app/services/groups.ts:229` 至 `app/services/groups.ts:247`
- `app/services/groups.ts:350` 至 `app/services/groups.ts:362`
- `doc/neko_tribe-oracle-v2.sql:1008` 至 `doc/neko_tribe-oracle-v2.sql:1034`

**缺口**

- 若产品保留群组分类/标签：扩展数据库、v2 类型、创建/更新 API、列表筛选、详情展示。
- 若短期不做：移除创建必填 category 和相关筛选，避免用户填写后被静默丢弃。

### 4. 群帖子评论/举报前端闭环不完整

**当前状态**

- 后端已有群帖子评论相关路由：列表、创建、删除、点赞/取消点赞。
- `app/types/v2.ts` 已定义 `V2GroupComment` 和 `V2CreateGroupCommentPayload`。
- 但 `app/api/v2/groups.ts` 没有封装群帖子评论接口，`app/services/groups.ts` 也没有暴露群帖子评论 service。
- `GroupPostCard` 会 emit `comment` 和 `report`，但 `app/pages/groups/posts.vue` 当前只接了 `like/pin/unpin/delete/share`。
- 举报后端已存在 `POST /api/v2/reports`，推文卡片已接入举报，但群帖子卡片的举报事件未接到该接口。

**证据**

- `server/api/v2/groups/[id]/posts/[post_id]/comments/index.get.ts`
- `server/api/v2/groups/[id]/posts/[post_id]/comments/index.post.ts`
- `server/api/v2/groups/[id]/posts/[post_id]/comments/[comment_id].delete.ts`
- `server/api/v2/groups/[id]/posts/[post_id]/comments/[comment_id]/likes.post.ts`
- `server/api/v2/groups/[id]/posts/[post_id]/comments/[comment_id]/likes.delete.ts`
- `server/services/v2/groups.ts:1388` 至 `server/services/v2/groups.ts:1557`
- `app/components/GroupPostCard.vue:51` 至 `app/components/GroupPostCard.vue:59`
- `app/components/GroupPostCard.vue:126` 至 `app/components/GroupPostCard.vue:151`
- `app/pages/groups/posts.vue:390` 至 `app/pages/groups/posts.vue:401`
- `app/api/v2/moderation.ts:213` 至 `app/api/v2/moderation.ts:219`

**缺口**

- 在 `app/api/v2/groups.ts` 和 `app/services/groups.ts` 补齐群帖子评论列表、发送、删除、点赞封装。
- 页面提供评论弹窗或跳转详情页，评论数更新。
- 群帖子举报接入 `v2CreateReport({ target_type: 'post', target_id })` 或定义专门的群帖子目标类型；如果复用 `post`，需确认 `n_group_posts.post_id` 与普通 `n_posts.post_id` 不会混淆。

## P1 未完成/半完成能力

### 5. 2FA 仍只是设置字段

**当前状态**

- `n_user_settings.two_factor_enabled` 已存在。
- 账户设置页可以保存 `two_factor_enabled`。
- `server/services/v2/auth.ts::v2Login()` 登录时只查 `n_users`，校验密码后直接签发 token；没有读取 `two_factor_enabled`，也没有二次验证挑战。
- 没有发现 TOTP 密钥、恢复码、信任设备、挑战 ticket 等数据模型。

**证据**

- `doc/neko_tribe-oracle-v2.sql:758`
- `app/pages/account/settings.vue:243` 至 `app/pages/account/settings.vue:267`
- `server/services/v2/users.ts:563` 至 `server/services/v2/users.ts:582`
- `server/services/v2/auth.ts:615` 至 `server/services/v2/auth.ts:650`

**缺口**

- 启用流程：生成密钥、扫码、验证码确认、恢复码。
- 登录流程：密码通过后若开启 2FA，返回 challenge，而不是直接签发 token。
- 关闭流程：需要密码/验证码确认。
- 设备信任和恢复码需要数据库模型与前端页面。

### 6. 删除账号/注销账号流程缺失

**当前状态**

- 账户页面有资料、设置、安全、会话、处置记录等页面。
- v2 users/me 相关接口包含资料、头像、邮箱、帖子、收藏、屏蔽、静音、设置、处置记录等。
- 没有发现删除账号、停用账号、冷静期、匿名化或软删除的 API/页面流程。

**证据**

- `server/api/v2/users/me/`
- `app/pages/account/`
- `doc/neko_tribe-oracle-v2.sql` 中 `n_users.status` / `is_active` 可支撑禁用，但未形成用户自助账号生命周期流程。

**缺口**

- 新增账号删除/停用 API，要求二次确认和密码校验。
- 明确数据策略：软删除、匿名化、帖子保留/隐藏、会话撤销。
- 前端在账号安全页提供危险操作区。

### 7. “我的点赞”缺少页面和接口

**当前状态**

- 已有普通帖子点赞/取消点赞和单帖点赞用户列表。
- 已有 `/api/v2/users/me/bookmarks` 和账户帖子管理页。
- 没有发现 `/api/v2/users/me/likes`、`v2ListMyLikedPosts()` 或账户“我的点赞”页面。

**证据**

- `server/api/v2/users/me/bookmarks.get.ts`
- `server/api/v2/users/me/posts.get.ts`
- `server/services/v2/posts.ts:1175` 至 `server/services/v2/posts.ts:1224`
- `app/pages/account/posts.vue`

**缺口**

- 新增 `GET /api/v2/users/me/likes`，按 `n_post_likes.created_at DESC` 返回已点赞帖子。
- 前端新增账户页或用户页入口。
- 与普通时间线的点赞/取消点赞状态同步。

### 8. 推文回复入口仍不完整

**当前状态**

- 推文详情页有评论区，也能发送评论。
- 推文级回复列表已经存在。
- 但 `app/pages/tweet/[id].vue` 中 `handleReplyTweet()` 仍为空函数。
- 列表页和搜索页点击回复只是跳转详情页，并不会直接打开回复 composer 或带入回复上下文。

**证据**

- `app/pages/tweet/[id].vue:202` 至 `app/pages/tweet/[id].vue:203`
- `app/pages/tweet/[type]/[user].vue:135` 至 `app/pages/tweet/[type]/[user].vue:138`
- `app/pages/tweet/search/[search].vue:92` 至 `app/pages/tweet/search/[search].vue:95`
- `TweetComposer` 已支持 `replyTo`、`open-reply-dialog`、`replyToPostId`。

**缺口**

- 详情页回复按钮应打开回复 composer 或弹窗，并设置 `replyTo`。
- 列表/搜索页可跳转详情页并带 query/hash，让详情页自动打开回复框。
- 回复成功后刷新回复列表和原帖统计。

### 9. 媒体 description 尚未实现

**当前状态**

- `TweetComposer` 已支持 alt 文本输入和提交。
- 没有看到媒体 description 输入、上传 payload 和展示闭环。

**证据**

- `app/components/TweetComposer.vue:558` 至 `app/components/TweetComposer.vue:567`
- `app/components/TweetComposer.vue:726` 至 `app/components/TweetComposer.vue:731`

**缺口**

- 确认 `n_media_assets` 是否需要新增/已有 description 字段。
- 上传接口、composer 表单和展示组件统一支持 description。

## P2 待补强或应清理项

### 10. 推荐反馈仍是 accepted stub

**当前状态**

- `/api/v2/recommendations/feedback` 会校验 `resource_type`、`resource_id`、`action`。
- 校验后直接返回 `{ accepted: true }`，没有落库。
- 推荐用户接口主要按粉丝数/帖子数等基础信号排序，不消费反馈事件。

**证据**

- `server/services/v2/posts.ts:1697` 至 `server/services/v2/posts.ts:1705`
- `server/api/v2/recommendations/feedback.post.ts`
- `server/services/v2/users.ts` 推荐用户查询逻辑

**缺口**

- 增加推荐反馈事件表，例如 `n_recommendation_feedback`。
- 记录“不感兴趣、隐藏、减少类似内容”等 action。
- 推荐查询消费反馈信号，实现降权、过滤和解释。

### 11. projects 导航仍是占位数据

**当前状态**

- secondary feedback 已经是 GitHub issues，不再是 `#`。
- `projects` 导航仍保留 design/sales/travel 三个占位项，URL 均为 `#`。
- `NavProjects` 组件仍被 TODO 注释掉。

**证据**

- `app/components/AppSidebar.vue:155` 至 `app/components/AppSidebar.vue:167`
- `app/components/AppSidebar.vue:263` 至 `app/components/AppSidebar.vue:265`

**缺口**

- 若不做 projects 功能，应删除占位数据和 TODO。
- 若保留，应实现真实页面/路由。

### 12. 诊断/测试页面仍在正式路由树中

**当前状态**

- `app/pages/test.vue` 是 toast/comment mock 测试页。
- `app/pages/ws/index.vue` 是 WebSocket 诊断页。
- `app/pages/test-token-refresh.vue` 是 token 刷新诊断页。

**证据**

- `app/pages/test.vue`
- `app/pages/ws/index.vue`
- `app/pages/test-token-refresh.vue`

**缺口**

- 生产环境隐藏这些页面，或移入需要管理员权限的 diagnostics 区域。
- 避免被误认为正式产品功能。

### 13. 自动化质量闸门不足

**当前状态**

- `package.json` 只有 `build/dev/generate/preview/start/typecheck/docker` 等脚本，没有标准 `lint`、`test`、`test:e2e` 或 `check` 聚合脚本。
- 本次运行 `yarn typecheck` 失败，错误分布在既有的 shadcn auto-form/Zod 类型、部分前端页面类型、以及大量旧 v1 API 缺失类型上。
- 这些错误说明当前仓库无法通过统一类型闸门，也会影响后续判断新功能是否破坏构建。

**证据**

- `package.json:5` 至 `package.json:18`
- `eslint.config.mjs`
- `yarn typecheck` 当前失败，典型错误包括：
  - `app/components/ui/auto-form/*` 依赖 Zod v3/v4 类型差异。
  - `server/api/v1/*` 大量 `Auth`、`ErrorResponse`、旧响应类型缺失。
  - `app/components/BirthdayCalendar.vue`、`app/components/ProfileForm.vue`、`app/composables/usePostFeed.ts` 等前端类型错误。

**缺口**

- 修复或隔离旧 v1 类型错误。
- 增加 `lint`、`test`、`check` 脚本。
- 为登录、发帖、群组、通知、审核、聊天补 API 冒烟测试。
- 为关键前端路径补 Playwright 或 Nuxt 测试。

## 建议实施顺序

1. 先补群组 P0 闭环：
   - 我的群组邀请收件箱。
   - 群通知偏好持久化。
   - 群组分类/标签取舍。
   - 群帖子评论和举报前端接线。
2. 再补账户与内容体验 P1：
   - 2FA 真正接入登录流程。
   - 删除账号/停用账号流程。
   - 我的点赞页面与接口。
   - 推文回复入口。
   - 媒体 description。
3. 再补 P2 治理与工程质量：
   - 推荐反馈落库并参与推荐。
   - 清理 projects 占位和诊断页面。
   - 修复 typecheck，补 lint/test/check。

每个模块完成时都应保留一条可验证链路：

`前端入口 -> service -> API -> DB/事件 -> UI 刷新/实时同步 -> 失败回滚`

避免再次出现只有 UI、只有后端、或只有字段没有执行链路的半完成状态。

## 当前验证记录

- 已复核当前文件结构和关键调用链。
- 已运行 `yarn typecheck`，当前失败；失败主要来自既有类型问题和旧 v1 API 类型缺失，不是本文档修改导致。
- 本文档为盘点更新，没有修改业务代码。
