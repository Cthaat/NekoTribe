# NekoTribe Flutter 前端重构验收文档

> 验收日期：2026-05-24 11:17:30 +08:00  
> 分支：`Flutter`  
> 验收依据：`doc/NekoTribe-Flutter前端迁移执行文档.md`、`app/api/v2/*.ts`、`app/services/*.ts`、`server/api/v2/**`、`app/pages/**`  
> 结论：Flutter 客户端已补齐一批 Nuxt 生产面路由、API 合同和响应式显示能力；静态分析、单测、Web build、Windows build 均已通过。未持有可用登录/审核账号，因此已登录业务闭环仍需人工账号复验。

## 一、已验证命令

| 命令 | 结果 |
| --- | --- |
| `flutter analyze` | 通过，No issues found |
| `flutter test` | 通过，20/20 |
| `flutter build web` | 通过，输出 `build/web` |
| `flutter build windows` | 通过，输出 `build/windows/x64/runner/Release/nekotribe.exe` |

说明：`flutter build web` 会提示 `flutter_secure_storage_web` 不兼容 Wasm dry run；这是依赖使用 `dart:html`/`dart:js_util` 的提示，不影响当前 JS Web build。

## 二、本轮修正范围

### 2.1 API 合同

- Posts：统一 `page_size`；修正 `/likes`、`/bookmarks`、`/retweets`、`/replies`、评论点赞、编辑、删除、推荐反馈。
- Users：数字 user ID 用于 profile、follow、followers、following；邮箱变更体对齐 `new_email`、`verification_id`、`code`。
- Groups：slug 详情使用 `/api/v2/groups/by-slug/{slug}`；成员、帖子、邀请动作使用数字 group ID；邀请响应使用 `/api/v2/groups/invites/{invite_id}/responses`；补齐群帖详情、评论、评论点赞/删除。
- Chat：reaction 使用 `POST/DELETE /reactions`；pin 使用 `PUT /pin-status`；补齐 channel read/mute API。
- Notifications：补齐单条 read-status、restore-status，并在 UI 中支持筛选、单条已读/未读、删除/恢复。
- Moderation：内容动作使用 `/content/{post_id}/actions`；用户动作使用 `/users/{user_id}/actions`，body 使用 `ban/unban/mute/unmute/note`、`reason`、`duration_hours`、`note`。
- Network：兼容 30001 入口的 Nuxt 外层错误 envelope：`{ error, statusCode, data: { code, message, data, meta } }`。

### 2.2 路由和页面

- 生产路由表补齐 `/posts/:postId/edit`、`/users/:userId/posts`、`/groups/:slug/manage`、`/groups/:slug/posts/:postId`、`/chat/groups/:groupId/channels/:channelId`。
- Account alias 补齐 `/account`、`/account/overview`、`/account/profile`、`/account/settings`、`/account/appearance`、`/account/billing`、`/account/pro`、`/account/security`、`/account/active`、`/account/statements`、`/account/posts`、`/account/likes`、`/account/bookmarks`。
- Moderation 补齐 `/moderation/users` 和 `/moderation/appeals`；审核中心新增 Users 标签，可搜索、筛选、ban/unban/mute/unmute/note。
- Public read-only 路由保持不强制跳登录；需要登录的公开页动作统一跳 `/auth/login` 并显示提示。
- Profile 页补齐 direct-message 入口；Account 页补齐 profile edit 入口。

### 2.3 Web 显示验证

已在本地静态 Web build 上使用 Chrome DevTools Protocol 截图：

| 宽度 | 截图 |
| --- | --- |
| 390px | `frontend_flutter/build/visual-check/flutter-web-final-390.png` |
| 800px | `frontend_flutter/build/visual-check/flutter-web-final-800.png` |
| 1280px | `frontend_flutter/build/visual-check/flutter-web-final-1280.png` |

结果：三档宽度均能正常绘制 Material 3 shell、顶部标签、底部导航或桌面 NavigationRail、错误态和登录 CTA；未观察到首屏空白、明显文字溢出或主操作不可达。

## 三、当前限制和后续复验项

- 未登录访问 `30001` 的 feed API 当前返回 `40101 请先登录`，Flutter 已正确展示错误态与登录 CTA。若产品要求未登录完整浏览 feed，需要后端公开查询策略配合；本轮未修改后端。
- 将 Flutter Web 静态文件从 `5174` 这类独立端口服务时，请求 `30001` 会遇到浏览器 CORS 限制。部署验收应把 Flutter Web 与 API 反代放在同源，或使用本地代理。
- 未提供真实用户、群组成员、审核员账号，本轮未完成登录后发帖、群组邀请、私信/群聊实时、通知资源跳转、审核处罚、SentimentFlow 开关的人工闭环验证。
- Windows build 已通过编译；未在 Windows release 程序内执行登录后全链路手工操作。

## 四、验收结论

本轮不再保留“全部阶段已完美完成”的旧结论。当前可确认的是：

- Flutter 工程可分析、可测试、可构建 Web 与 Windows。
- 高风险 v2 API 路径、方法、query/body 已通过合同测试覆盖。
- Nuxt 生产路由的主要 Flutter parity surface 已注册并具备页面入口。
- 公开页未登录动作不会静默失败，会引导登录。
- Web 首屏响应式显示已在 390px、800px、1280px 截图通过。

下一步若要宣布完整业务 parity，需要使用真实账号完成登录态 live smoke，并在同源 Web 部署或代理环境下复验所有需要认证的流程。
