# NekoTribe Flutter 前端重构验收文档

> 验收日期：2026-05-25 20:43:54 +08:00
> 分支：`Flutter`
> 验收依据：`doc/NekoTribe-Flutter前端迁移执行文档.md`、`app/api/v2/*.ts`、`app/services/*.ts`、`server/api/v2/**`、`app/pages/**`
> 结论：Flutter 客户端继续补齐 Nuxt 生产面路由、API 合同和响应式显示能力；静态分析、单测、Web build、Windows build 均已通过。本轮已把本地 `30001` app 容器更新到包含 CORS middleware 与 JSON token 兼容的镜像，并使用 `edge` 测试账号完成 Flutter Web 静态预览跨源登录 smoke。

## 一、已验证命令

| 命令 | 结果 |
| --- | --- |
| `flutter analyze` | 通过，No issues found |
| `flutter test` | 通过，94/94 |
| `flutter build web` | 通过，输出 `build/web` |
| `flutter build windows` | 通过，输出 `build/windows/x64/runner/Release/nekotribe.exe` |
| `node --test server/utils/auth-token-response.test.ts server/utils/cors.test.ts` | 通过，5/5 |
| `npx nuxi prepare` | 通过，生成 `.nuxt` 类型 |
| `NODE_OPTIONS=--max-old-space-size=4096 yarn build` | 通过，输出 `.output` |
| CORS middleware 定向检查 | 通过，`esbuild` 可打包 `server/middleware/00-cors.ts`，`tsc` 可检查 `server/utils/cors.ts` |
| `OPTIONS /api/v2/auth/tokens` live smoke | 通过，`204`，返回 `Access-Control-Allow-Origin: http://localhost:5174` |
| `POST /api/v2/auth/tokens` live smoke | 通过，测试账号 `edge` 登录成功，响应 JSON 包含 `access_token` 和 `refresh_token` |
| `GET /api/v2/users/me` live smoke | 通过，Bearer token 返回当前用户 `edge` |
| `PATCH /api/v2/auth/tokens/current` live smoke | 通过，JSON body `refresh_token` 可刷新并返回新的 token 字符串 |
| Flutter Web CDP login smoke | 通过，`http://127.0.0.1:5174/#/auth/login` 登录后进入 `#/feed`，本地安全存储写入 access/refresh token，并请求主页动态列表成功 |
| `POST /api/v2/posts` metadata live smoke | 通过，`edge` 创建测试帖返回 `mentioned`、`Shanghai`、`flutterparity/smoke`，随后删除测试帖 |
| `PUT /api/v2/posts/{id}` metadata live smoke | 通过，测试帖更新为 `mentioned`、`Shanghai`、`afteredit/flutterparity`，随后删除测试帖 |
| `POST /api/v2/groups` metadata live smoke | 通过，`edge` 创建测试群组返回 `private`、`tech`、`flutterparity/smoke`，随后进入清理流程 |
| `PATCH /api/v2/groups/{id}` metadata live smoke | 通过，测试群组更新为 `secret`、`art`、`afteredit/flutterparity`、`join_approval=false`、`post_permission=admin_only` |
| `POST /api/v2/groups/{id}/invites` live smoke | 通过，创建邀请后列表读取确认 `max_uses=7`、`used_count=0`、`is_valid=true`，随后删除测试群组 |
| `POST /api/v2/media` + `POST /api/v2/groups` media live smoke | 通过，`edge` 上传 1x1 PNG 返回 `public_url`，创建测试群组持久化 `avatar_url` 与 `cover_url`，随后删除测试群组 |
| Chat channel media/reply/edit/reaction/pin live smoke | 通过，`edge` 在频道 2 创建临时 base/reply 消息，附件上传返回 `media_id=600300`，验证 `media_ids`、`reply_to_message_id`、编辑、reaction/unreaction、pin/unpin，随后删除临时消息和媒体 |
| Chat channel management live smoke | 通过，`edge` 在群组 3 创建临时频道 `channel_id=3`，验证频道更新、静音/取消静音、删除，随后清理临时频道 |
| ChannelScreen realtime event widget tests | 通过，覆盖后端/Nuxt `chat_message`、`chat_message_updated`、`chat_message_deleted`、`chat_reaction_updated` 事件形状 |
| SentimentFlow raw proxy live shape smoke | 通过，`edge` 调用 `predict` 返回原始上游结构 `label=neutral`、`confidence=0.5`、概率数组、`model_name=关键词基线` |
| SentimentFlow/PostCard/Channel/AppShell widget regression tests | 通过，覆盖情感分析原始响应显示、BERT/LSTM `model` 透传、帖子 AI 分析入口、首页收藏不清除点赞、首页转发入口、三点菜单固定、群聊工具栏、侧边栏发布入口 |

说明：`flutter build web` 会提示 `flutter_secure_storage_web` 不兼容 Wasm dry run；这是依赖使用 `dart:html`/`dart:js_util` 的提示，不影响当前 JS Web build。

Nuxt 全量 `yarn build` 已在 `NODE_OPTIONS=--max-old-space-size=4096` 下通过。Docker 完整重建曾受 Docker Hub `node:22-alpine` 元数据网络错误影响；本轮本地运行容器通过既有 Linux 镜像基底复制新 `.output` 产物完成更新，避免把 Windows `server/node_modules` 带入 Linux 容器。

## 二、本轮修正范围

### 2.1 API 合同

- Posts：统一 `page_size`；修正 `/likes`、`/bookmarks`、`/retweets`、`/replies`、评论点赞、编辑、删除、推荐反馈；发帖/编辑标签使用后端合同 `tag_names`，并覆盖 `mentioned` 可见性与位置字段。
- Users：数字 user ID 用于 profile、follow、followers、following；邮箱变更体对齐 `new_email`、`verification_id`、`code`。
- Groups：slug 详情使用 `/api/v2/groups/by-slug/{slug}`；成员、帖子、邀请动作使用数字 group ID；邀请响应使用 `/api/v2/groups/invites/{invite_id}/responses`；创建/管理上传并提交 `avatar_url`、`cover_url`、`privacy`、`category`、`tags`、`join_approval`、`post_permission`；邀请创建提交 `max_uses`、`expire_hours`；成员管理补齐 pending 审批/拒绝、成员搜索、所有权转让；补齐群帖详情、评论、评论点赞/删除。
- Chat：reaction 使用 `POST/DELETE /reactions`；pin 使用 `PUT /pin-status`；频道消息发送补齐 `media_ids`、`reply_to_message_id`；频道管理补齐 `PATCH /chat/channels/{id}`、`DELETE /chat/channels/{id}`、`PUT /mute-status`；频道实时同步兼容服务端 `data.message` / `data.message_id` 事件 envelope。
- Notifications：补齐单条 read-status、restore-status，并在 UI 中支持筛选、单条已读/未读、删除/恢复。
- Moderation：内容动作使用 `/content/{post_id}/actions`；用户动作使用 `/users/{user_id}/actions`，body 使用 `ban/unban/mute/unmute/note`、`reason`、`duration_hours`、`note`。
- Network：兼容 30001 入口的 Nuxt 外层错误 envelope：`{ error, statusCode, data: { code, message, data, meta } }`。
- Backend CORS：新增 `server/middleware/00-cors.ts` 和 `server/utils/cors.ts`，允许 Flutter Web 本地预览来源，`OPTIONS` 可在认证中间件前返回 `204`，并设置 `Access-Control-Allow-Origin`、`Access-Control-Allow-Credentials`、`Access-Control-Allow-Headers`、`Access-Control-Allow-Methods`、`Access-Control-Max-Age`、`Vary: Origin`。
- Auth token：登录和刷新响应的 `tokens` 数据现在包含 `access_token`、`refresh_token`、`session_id`、过期时间；刷新接口在没有 Cookie 时可读取 JSON body 中的 `refresh_token`，用于 Flutter Web/桌面客户端无法读取 `HttpOnly Set-Cookie` 的场景，同时保留 Cookie 兼容 Nuxt Web。
- SentimentFlow：代理路径会返回原始上游 JSON，不一定是 NekoTribe v2 envelope；Flutter `ApiClient` 现在会把无 `code/meta/message+data` 的 2xx Map 当作原始数据传给解码器，`V2SentimentPrediction` 同时兼容嵌套 `prediction` 与真实上游 `score/label/probabilities/model_name` 结构；预测请求会和 Nuxt 一样把 `model_id` 归一化为 `model=bert/lstm` 传给上游，避免选择 BERT 时仍走关键词基线。
- Posts viewer state：点赞与收藏接口返回的是局部 viewer 状态时，`PostCard` 只合并当前操作字段，避免收藏响应把已有点赞状态覆盖为 false。

### 2.2 路由和页面

- 生产路由表补齐 `/posts/:postId/edit`、`/users/:userId/posts`、`/groups/:slug/manage`、`/groups/:slug/posts/:postId`、`/chat/groups/:groupId/channels/:channelId`。
- Account alias 补齐 `/account`、`/account/overview`、`/account/profile`、`/account/settings`、`/account/appearance`、`/account/billing`、`/account/pro`、`/account/security`、`/account/active`、`/account/statements`、`/account/posts`、`/account/likes`、`/account/bookmarks`。
- Moderation 补齐 `/moderation/users` 和 `/moderation/appeals`；审核中心新增 Users 标签，可搜索、筛选、ban/unban/mute/unmute/note。
- Public read-only 路由保持不强制跳登录；需要登录的公开页动作统一跳 `/auth/login` 并显示提示。
- Profile 页补齐 direct-message 入口；Account 页补齐 profile edit 入口。
- 桌面侧边栏“发布”入口改为进入 `/meow` 发帖页，不再误进 `/account/profile` 资料编辑页。
- SentimentFlow：补齐 Flutter API 解析、模型/统计接口、独立页面、设置页模型与 Top-K 控制、发帖/卡片情感分析入口。
- 首页帖子交互：收藏操作不会再取消当前点赞状态；卡片操作区补齐网页端可见转发/引用按钮和转发数；三点菜单固定在卡片右上角，不再随作者/正文长度漂移；相关回归测试覆盖已点赞帖子点击收藏后的 UI、`onChanged` 状态、转发提交和菜单定位。
- 媒体与账号：补齐帖子/群帖媒体 lightbox；头像上传改为 `/api/v2/users/me/avatar` multipart `avatar` 字段。
- 发帖/编辑：补齐网页端 composer/editor 的 280 字限制、`mentioned` 可见性、位置输入、正文 `#标签` 与手动标签合并去重，并在 create/update 时提交 `tag_names`。
- 群组创建/管理：补齐网页端头像/封面上传、privacy/category/tags、入组审核、发帖权限、邀请次数/有效小时、pending 成员审批/拒绝、成员搜索、所有权转让、删除确认；头像/封面与元数据通过 widget 测试与真实 `edge` 账号 media/create/update/invite/delete smoke，成员管理通过 widget 合同测试覆盖。
- 频道聊天：补齐网页端附件上传、图片选择、表情、@ 提及、# 频道、贴纸/礼物工具入口、回复预览与发送、消息编辑/删除、反应汇总点击取消/添加、置顶/取消置顶，并兼容后端/Nuxt 频道实时事件；通过 widget 测试覆盖 UI 行为，并用真实 `edge` 账号完成 media/reply/edit/reaction/pin/delete API smoke。
- 频道管理：补齐网页端频道分类输入、频道静音/取消静音、编辑、删除确认；频道选择器原地刷新操作结果，并用真实 `edge` 账号完成 create/update/mute/delete API smoke。
- Web 显示：连接错误改为短文案，Web 使用系统中文字体 fallback；Feed 顶部标签在 390px 下完整显示。

### 2.3 Web 显示验证

已在本地静态 Web build 上使用 Chrome DevTools Protocol 截图：

| 宽度 | 截图 |
| --- | --- |
| 390px | `frontend_flutter/build/visual-check/flutter-web-final-390.png` |
| 800px | `frontend_flutter/build/visual-check/flutter-web-final-800.png` |
| 1280px | `frontend_flutter/build/visual-check/flutter-web-final-1280.png` |

结果：三档宽度均能正常绘制 Material 3 shell、顶部标签、底部导航或桌面 NavigationRail、错误态和重试 CTA；截图像素检查非空白。390px 下已复验短错误文案、中文字体和 Feed 顶部 `首页/发现/关注` 完整显示。

## 三、当前限制和后续复验项

- 当前 `30001` 容器健康，并已用本分支 `.output` 产物更新到包含 CORS 与 JSON token 兼容的本地镜像；Flutter Web 静态端口到 `30001` 的登录、token 持久化、主页动态拉取 smoke 已通过。
- 本轮使用普通测试账号 `edge` 完成认证链路复验；审核功能仍需要具备审核权限的账号复验。
- Windows build 已通过编译；未在 Windows release 程序内执行登录后全链路手工操作。

## 四、验收结论

本轮不再保留“全部阶段已完美完成”的旧结论。当前可确认的是：

- Flutter 工程可分析、可测试、可构建 Web 与 Windows。
- 高风险 v2 API 路径、方法、query/body 已通过合同测试覆盖。
- 本地源代码已加入 Flutter Web 跨源预检兼容层，并有 CORS 单元测试覆盖。
- v2 auth 响应已补齐 Flutter 所需 token 字符串，刷新接口支持 JSON `refresh_token` fallback。
- Flutter 发帖与编辑已补齐网页端基础元数据能力，并通过 widget 合同测试与真实 `edge` 账号 create/update/delete smoke。
- Flutter 群组创建与管理已补齐网页端头像/封面媒体上传、基础元数据、邀请参数、pending 成员审批/拒绝、成员搜索、所有权转让和删除确认能力，并通过 widget 合同测试与真实 `edge` 账号 media/create/update/invite/delete smoke。
- Flutter 频道聊天已补齐网页端附件、回复、编辑/删除、反应汇总、置顶和服务端实时事件同步能力，并通过 widget 测试与真实 `edge` 账号 API smoke。
- Flutter 频道管理已补齐网页端创建分类、静音/取消静音、编辑和删除能力，并通过 widget 测试与真实 `edge` 账号 API smoke。
- Flutter SentimentFlow 已修复原始代理响应解析，并按网页端规则透传 `model=bert/lstm`，独立情感分析页和帖子 AI 情感分析入口可显示真实 label、confidence 与概率分布。
- Flutter 首页帖子卡片已修复收藏/点赞状态串线，收藏不会清除当前点赞；可见转发入口、转发数和右上角固定三点菜单已补齐。
- Flutter 桌面侧边栏发布按钮已指向发帖页，群聊输入栏已补齐图片、表情、@、#、贴纸/礼物等网页端工具入口。
- 本地 `30001` app 容器已包含本轮后端兼容改造，Flutter Web 跨源登录 smoke 已通过。
- Nuxt 生产路由的主要 Flutter parity surface 已注册并具备页面入口。
- 公开页未登录动作不会静默失败，会引导登录。
- Web 首屏响应式显示已在 390px、800px、1280px 截图通过。

下一步若要宣布完整业务 parity，需要继续按 Nuxt 页面清单做业务级操作复验，尤其是 Flutter 桌面内的群聊手工流、通知实时推送和需要审核权限的管理流程。
