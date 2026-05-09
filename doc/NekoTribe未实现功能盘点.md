# NekoTribe 未实现功能盘点

> 扫描日期：2026-05-09  
> 扫描范围：`app/`、`server/api/v2/`、`server/services/v2/`、`server/routes/`、`doc/neko_tribe-oracle-v2.sql`、`data/oracle-init/`、现有路线图与 `package.json`。  
> 判定口径：本盘点把“只有静态 UI/模拟数据/本地状态”“有按钮但只弹 WIP 提示”“函数空实现或返回空数组”“后端接口只是 accepted stub”“有后端但前端未接入关键动作”均视为未完成或半完成。

## 总体结论

项目已经有一套 v2 社交主线能力：登录注册、发帖、删帖、点赞、收藏、评论、转发、通知列表、账户设置、会话管理、群组核心 CRUD 与加入/退出等都已有实现基础。

当前最明显的未完成区域集中在：

1. 聊天/群组频道：仍是演示页，没有正式数据模型、业务 API、持久化和鉴权后的实时收发。
2. 内容审核：页面大多使用 mock 或施工占位，没有 v2 审核后端闭环。
3. 实时能力：WebSocket 是通用诊断/房间广播能力，未接入通知、在线状态、聊天业务。
4. 群组管理细节：核心列表/加入/发帖后端存在，但成员管理、帖子管理、邀请收件箱、设置页、群通知等前端闭环缺失。
5. 内容体验细节：推文编辑、我的点赞、回复入口、媒体 alt/description 等未补齐。
6. 安全与治理：2FA、登录提醒、在线状态、私信开关、删除账号等多为设置字段或路线图项，缺少真正执行链路。

## 优先级说明

| 优先级 | 含义 |
| --- | --- |
| P0 | 页面已有入口但无法作为真实功能使用，或缺少核心数据/API/持久化。 |
| P1 | 主流程基本有基础，但关键动作、前后端闭环或安全约束缺失。 |
| P2 | 体验增强、内部工具清理、推荐/质量体系等不阻塞最小可用版本但会影响长期可维护性。 |

## P0 未实现/原型态功能

### 1. 聊天与群组频道

**当前状态**

- `app/pages/chat.vue` 直接声明“模拟群组数据”“模拟频道分类和频道数据”，消息、频道、成员都来自页面内本地数组。
- 发送消息只是在前端 `messages.value.push(newMessage)`，删除、置顶、表情、静音等也只改本地状态。
- 创建频道按钮只提示 `chat.feedback.createChannelWip`。
- `server/routes/_ws.ts` 提供通用 `join_room`、`leave_room`、`room_message`、`broadcast`，但不是聊天业务 API。
- `server/utils/wsSession.ts` 明确说明“已移除用户认证功能”，会话只跟踪匿名连接和房间。
- v2 Oracle SQL 里只出现 `allow_dm_from_strangers` 设置字段，没有聊天/私信/频道/消息相关表；`server/api/v2` 下也没有 chat/message/channel/conversation 目录。

**证据**

- `app/pages/chat.vue:18`、`app/pages/chat.vue:26`
- `app/pages/chat.vue:461` 至 `app/pages/chat.vue:490`
- `app/pages/chat.vue:528` 至 `app/pages/chat.vue:556`
- `server/routes/_ws.ts:188` 至 `server/routes/_ws.ts:207`
- `server/routes/_ws.ts:394` 至 `server/routes/_ws.ts:439`
- `server/utils/wsSession.ts:11`
- `doc/neko_tribe-oracle-v2.sql:749`、`doc/neko_tribe-oracle-v2.sql:762`

**缺口**

- 缺少聊天数据表：会话/群组频道/频道成员/消息/附件/已读回执/反应/置顶/撤回/编辑。
- 缺少 v2 REST API：频道列表、频道创建/编辑、消息分页、发送消息、删除/撤回、反应、置顶、附件上传关联。
- 缺少业务 WebSocket 协议：用户鉴权、房间权限校验、频道订阅、消息投递、断线重连、幂等消息 ID。
- 缺少前端真实接入：`chat.vue` 应改为加载群组/频道/消息，并把 `ChatRoom`、`ChatInput`、`ChatChannelList` 接到 API 和 WebSocket。

### 2. 内容审核中心

**当前状态**

- `app/pages/moderation/content.vue` 使用 mock 统计和 mock 推文列表。
- 审核通过/拒绝/标记只修改本地数组和本地统计，不写入后端。
- 刷新列表通过 `setTimeout` 重置回 mock 数据。
- `app/pages/moderation/users.vue`、`reports.vue`、`settings.vue` 都是 `Construction` 占位卡片。
- `server/api/v2` 顶层目录只有 `auth/comments/groups/media/notifications/posts/recommendations/tags/users`，没有 moderation/report/admin 后端模块。

**证据**

- `app/pages/moderation/content.vue:19` 至 `app/pages/moderation/content.vue:37`
- `app/pages/moderation/content.vue:227`
- `app/pages/moderation/content.vue:324` 至 `app/pages/moderation/content.vue:356`
- `app/pages/moderation/content.vue:384` 至 `app/pages/moderation/content.vue:392`
- `app/pages/moderation/users.vue:1` 至 `app/pages/moderation/users.vue:42`
- `app/pages/moderation/reports.vue:1` 至 `app/pages/moderation/reports.vue:42`
- `app/pages/moderation/settings.vue:1` 至 `app/pages/moderation/settings.vue:42`

**缺口**

- 缺少举报模型：举报记录、举报原因、举报目标、举报人、状态、优先级、证据。
- 缺少审核队列 API：待审列表、筛选、排序、领取/释放、批量处理。
- 缺少审核动作 API：通过、拒绝、下架、恢复、封禁、禁言、备注、处罚时长。
- 缺少治理闭环：申诉审核、操作留痕、管理员权限、规则配置、自动化风控信号。
- 缺少真实统计：待处理数、今日处理量、平均处理时间、误判/申诉成功率。

### 3. 实时通知、在线状态与业务 WebSocket

**当前状态**

- WebSocket 页面 `app/pages/ws/index.vue` 是诊断工具，直接连接 `/_ws`，不接通知或聊天业务。
- 通知前端通过 `v2ListNotifications` 拉列表，`useNotificationMailbox` 是分页刷新模型，没有 WebSocket/SSE 订阅。
- `server/routes/_ws.ts` 是通用广播和房间消息，不绑定登录用户、通知资源或聊天权限。
- 账户设置里有 `show_online_status`、`push_notification_enabled`、`login_alerts` 等字段，但没有看到业务执行链路。

**证据**

- `app/pages/ws/index.vue:45` 至 `app/pages/ws/index.vue:54`
- `app/services/notifications.ts:131` 至 `app/services/notifications.ts:168`
- `app/composables/useNotificationMailbox.ts:27` 至 `app/composables/useNotificationMailbox.ts:57`
- `server/routes/_ws.ts:119` 至 `server/routes/_ws.ts:155`
- `server/utils/wsSession.ts:26` 至 `server/utils/wsSession.ts:30`
- `server/services/v2/users.ts:365` 至 `server/services/v2/users.ts:383`

**缺口**

- 缺少用户级 WebSocket 鉴权和会话绑定。
- 缺少通知实时投递：新通知、已读同步、删除/恢复同步。
- 缺少在线状态：心跳、最后在线时间、隐私设置生效、用户资料/聊天成员在线状态展示。
- 缺少登录提醒的触发链路：新设备登录后写通知或发邮件。

## P1 未实现/半完成能力

### 4. 群组模块的管理闭环

**当前状态**

- 群组发现、我的群组、创建、加入/退出、详情成员/帖子加载已接入 v2 基础 API。
- 但邀请收件箱 `listMyGroupInvites()` 直接返回空数组。
- 群组设置入口只弹 `settingsWip` 提示。
- 详情弹窗里的通知开关只改本地 `notificationsEnabled`，没有 API 持久化。
- `GroupMemberCard` 提供移除、提升、降级、禁言、取消禁言事件并直接 toast 成功，但 `GroupDetailModal` 没有把这些事件向页面/API 继续接线。
- `GroupPostCard` 提供点赞、评论、置顶、删除、举报、分享事件并 toast，但详情页没有对应 API 处理函数。
- 前端 `app/api/v2/groups.ts` 只封装到列表、创建、详情、加入/退出、成员列表、帖子列表、邀请创建/响应；没有封装群组帖子点赞/评论/置顶/删除、成员角色/禁言/审批等已有后端路由。
- 创建群组 UI 要求 category，但 `createGroup()` 组装 v2 payload 时没有提交 category/tags；映射结果 `tags: []`。
- 头像上传按钮只是一个按钮，没有文件选择/上传处理。

**证据**

- `app/services/groups.ts:344` 至 `app/services/groups.ts:357`
- `app/pages/groups/my.vue:68` 至 `app/pages/groups/my.vue:70`
- `app/pages/groups/discover.vue:96` 至 `app/pages/groups/discover.vue:98`
- `app/components/GroupDetailModal.vue:122` 至 `app/components/GroupDetailModal.vue:151`
- `app/components/GroupDetailModal.vue:411` 至 `app/components/GroupDetailModal.vue:428`
- `app/components/GroupMemberCard.vue:40` 至 `app/components/GroupMemberCard.vue:45`
- `app/components/GroupMemberCard.vue:99` 至 `app/components/GroupMemberCard.vue:121`
- `app/components/GroupPostCard.vue:44` 至 `app/components/GroupPostCard.vue:51`
- `app/components/GroupPostCard.vue:98` 至 `app/components/GroupPostCard.vue:134`
- `app/components/CreateGroupModal.vue:119` 至 `app/components/CreateGroupModal.vue:135`
- `app/components/CreateGroupModal.vue:154` 至 `app/components/CreateGroupModal.vue:172`
- `app/services/groups.ts:76` 至 `app/services/groups.ts:95`
- `app/services/groups.ts:288` 至 `app/services/groups.ts:300`
- `app/api/v2/groups.ts:28` 至 `app/api/v2/groups.ts:200`

**缺口**

- 补齐“我的邀请”查询 API 与前端映射。
- 补齐群组设置页/弹窗：名称、描述、封面、头像、隐私、入群审批、发帖权限。
- 补齐群成员管理：审批、移除、角色调整、禁言/解禁、审计日志刷新。
- 补齐群帖子管理：点赞、评论、置顶、删除、举报、分享 URL。
- 明确 category/tags 是否进入数据库模型；若保留 UI，应扩展表和 API；若不做，应移除 UI 筛选和必填项。
- 群通知开关需要持久化到用户-群组偏好表或通知偏好表。

### 5. 推文/内容体验细节

**当前状态**

- 推文创建、删除、点赞、收藏、评论、转发已有基础 v2 流程。
- 推文编辑未实现：`server/api/v2/posts` 下没有 PATCH 路由，前端 API/service 也没有 update/edit post 方法；路线图仍把“推文编辑”列为待补齐能力。
- 推文详情页 `handleReplyTweet()` 是空函数；其他时间线页面点击回复只是跳转详情页，不直接打开回复 composer。
- `TweetComposer` 对媒体上传固定追加 `altText = '111'` 和 `description = '111123'`，TODO 标注“添加描述字段”。
- `TweetComposer` 内部回复/引用按钮区域仍注释为 TODO。
- “我的点赞”没有导航入口，也没有 `/api/v2/users/me/likes` 类型的 v2 接口；路线图仍列为 P1。

**证据**

- `app/components/TweetComposer.vue:145` 至 `app/components/TweetComposer.vue:169`
- `app/components/TweetComposer.vue:387`
- `app/pages/tweet/[id].vue:100` 至 `app/pages/tweet/[id].vue:101`
- `app/pages/tweet/[type]/[user].vue:89` 至 `app/pages/tweet/[type]/[user].vue:92`
- `app/pages/tweet/search/[search].vue:76` 至 `app/pages/tweet/search/[search].vue:79`
- `app/api/v2/posts.ts:137` 至 `app/api/v2/posts.ts:163`
- `server/api/v2/posts/` 只有 get/post/delete/likes/bookmarks/comments/replies/retweets/analytics/trending 路由，没有 patch 路由。
- `doc/NekoTribe长期最终可执行路线图.md:298`
- `doc/NekoTribe长期最终可执行路线图.md:578`

**缺口**

- 补齐 `PATCH /api/v2/posts/:id`，包含编辑窗口、作者校验、编辑历史或 `edited_at`。
- 补齐回复交互：详情页回复按钮打开回复框并带上下文；时间线可直接弹回复 composer。
- 补齐媒体 alt/description 表单、上传 payload 与展示。
- 补齐“我的点赞”接口、service、路由页面和导航入口。

### 6. 通知邮箱 UI 的非通知动作

**当前状态**

- v2 通知列表、标记已读/未读、批量已读、删除、恢复已有服务层。
- `MailDisplay` 中归档、移入垃圾、稍后提醒、回复、全部回复、转发、收藏线程、加标签、静音线程等按钮没有 emit，也没有 API。
- 只有删除和恢复按钮向外发事件。

**证据**

- `app/components/MailDisplay.vue:54`
- `app/components/MailDisplay.vue:63` 至 `app/components/MailDisplay.vue:90`
- `app/components/MailDisplay.vue:135` 至 `app/components/MailDisplay.vue:229`
- `app/components/MailDisplay.vue:239` 至 `app/components/MailDisplay.vue:289`
- `app/components/MailDisplay.vue:305` 至 `app/components/MailDisplay.vue:318`
- `app/pages/user/[id]/notifications.vue:53` 至 `app/pages/user/[id]/notifications.vue:94`

**缺口**

- 如果这些按钮是通知中心产品功能，需要新增 API/状态字段：归档、垃圾箱、稍后提醒、标签、星标、静音。
- 如果只是从 mail 示例组件继承来的 UI，应删除未接线按钮，避免用户误以为功能可用。

### 7. 账户安全、隐私与账号生命周期

**当前状态**

- v2 设置可以保存 `two_factor_enabled`、`login_alerts`、`show_online_status`、`allow_dm_from_strangers` 等字段。
- 登录接口只校验账号密码并发 token，没有读取 `two_factor_enabled`，也没有二次验证挑战。
- `allow_dm_from_strangers` 只有设置字段；聊天/私信功能本身尚未实现。
- `show_online_status` 只有设置字段；在线状态服务尚未实现。
- 没有发现删除账号/注销账号 API 或页面流程。

**证据**

- `app/pages/account/settings.vue:35` 至 `app/pages/account/settings.vue:43`
- `app/pages/account/settings.vue:73` 至 `app/pages/account/settings.vue:87`
- `app/pages/account/settings.vue:174` 至 `app/pages/account/settings.vue:186`
- `app/pages/account/settings.vue:238` 至 `app/pages/account/settings.vue:248`
- `server/services/v2/users.ts:365` 至 `server/services/v2/users.ts:383`
- `server/services/v2/users.ts:419` 至 `server/services/v2/users.ts:468`
- `server/services/v2/auth.ts:535` 至 `server/services/v2/auth.ts:664`

**缺口**

- 2FA：启用流程、密钥/验证码绑定、恢复码、登录挑战、信任设备、禁用校验。
- 登录提醒：检测新设备/新 IP，写通知或发邮件，尊重用户设置。
- 在线状态：心跳、状态存储、隐私开关生效、前端展示。
- 私信开关：依赖私信/聊天模型，后续聊天发送权限应读取该设置。
- 删除账号：冷静期、二次确认、数据匿名化/软删除、会话撤销。

## P2 待补强或应清理项

### 8. 推荐反馈只是空接收

**当前状态**

- `/api/v2/recommendations/feedback` 会校验 `resource_type`、`resource_id`、`action`，然后直接返回 `{ accepted: true }`。
- 推荐用户接口是按粉丝数/帖子数排序排除已关注/拉黑用户，可用但还不是个性化推荐。

**证据**

- `server/services/v2/posts.ts:989` 至 `server/services/v2/posts.ts:997`
- `server/services/v2/users.ts:783` 至 `server/services/v2/users.ts:820`

**缺口**

- 需要推荐反馈表或事件日志。
- 需要在推荐查询中消费反馈信号，例如“不感兴趣”“已隐藏”“类似内容减少”。
- 需要推荐解释、去重、冷启动与安全过滤策略。

### 9. 导航与辅助入口占位

**当前状态**

- 侧边栏 secondary 的 support/feedback URL 仍是 `#`。
- projects 导航数据存在但组件被 TODO 注释掉。

**证据**

- `app/components/AppSidebar.vue:145` 至 `app/components/AppSidebar.vue:153`
- `app/components/AppSidebar.vue:232` 至 `app/components/AppSidebar.vue:239`

**缺口**

- support/feedback 若作为产品入口，需要真实页面或外链。
- projects 若不做，应删除相关数据；若保留，应实现对应页面。

### 10. 诊断/测试页面仍在正式路由树中

**当前状态**

- `app/pages/test.vue` 使用 mock 评论和 toast 测试。
- `app/pages/ws/index.vue` 是 WebSocket 诊断页。
- `app/pages/test-token-refresh.vue` 是 Token 刷新诊断页。

**证据**

- `app/pages/test.vue:13` 至 `app/pages/test.vue:35`
- `app/pages/ws/index.vue:45` 至 `app/pages/ws/index.vue:54`
- `app/pages/test-token-refresh.vue:1` 至 `app/pages/test-token-refresh.vue:107`

**缺口**

- 生产环境需要隐藏、加权限或移动到内部 diagnostics 路由。
- 这些页面不应被误认为产品功能完成度的一部分。

### 11. 自动化质量闸门不足

**当前状态**

- `package.json` 只有 build/dev/generate/preview/start/typecheck/docker 等脚本，没有 test/lint 脚本。
- 项目有 `eslint.config.mjs`，但没有标准 `lint` script。
- 长期路线图也标注“尚未形成标准化测试脚本与质量闸门”。

**证据**

- `package.json:5` 至 `package.json:18`
- `doc/NekoTribe长期最终可执行路线图.md:47`
- `doc/NekoTribe长期最终可执行路线图.md:616`

**缺口**

- 增加 `lint`、`test`、`test:e2e` 或至少 `check` 聚合脚本。
- 为核心服务层补单元测试，为登录/发帖/群组/通知补 API 冒烟测试。
- 为前端关键路径补 Playwright 或 Nuxt 测试，防止 mock 页面长期混入正式功能。

## 已基本实现但仍需验收的能力

这些能力不应再简单归类为“未实现”，但需要业务验收和边界测试：

| 模块 | 当前实现基础 | 后续验收重点 |
| --- | --- | --- |
| 认证 | v2 OTP、注册、登录、刷新 token、退出、会话列表/撤销 | 失败重试、限流、邮件配置、2FA 接入 |
| 帖子主线 | 列表、发布、删除、点赞、收藏、评论、回复列表、转发、热门 | 编辑、我的点赞、回复入口、媒体描述 |
| 用户关系 | 关注、粉丝、互相关注、拉黑、静音、推荐用户 | 推荐质量、隐私设置生效 |
| 通知 | 列表、已读/未读、批量已读、删除、恢复 | 实时推送、偏好过滤、邮箱 UI 清理 |
| 群组基础 | 发现、我的群组、创建、加入/退出、详情、成员/帖子列表、邀请创建/响应后端 | 管理动作、设置、邀请收件箱、分类/标签 |
| 账户 | 资料、头像、邮箱、设置、会话、处置记录、申诉 | 删除账号、2FA、在线状态、登录提醒 |

## 建议实施顺序

1. 先做 P0：聊天数据模型/API/WebSocket 鉴权、审核后端闭环、实时通知基础。
2. 再补 P1：群组管理动作、推文编辑/回复入口/我的点赞、账户安全约束。
3. 同步清理 P2：隐藏诊断页、去掉未接线按钮、补质量脚本。
4. 每补一个模块都保留一条“前端入口 -> service -> API -> DB/事件 -> UI 刷新”的验收链路，避免继续出现只有 UI 或只有后端的半完成状态。
