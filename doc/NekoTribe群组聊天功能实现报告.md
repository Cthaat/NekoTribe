# NekoTribe 群组聊天功能实现报告

## 1. 实现范围

本次完成的是群组内频道聊天的第一版真实接入，替换 `app/pages/chat.vue` 原来的页面内模拟群组、频道、成员和消息数据。

已实现能力：

- 群组聊天入口：读取当前用户已加入的群组。
- 频道列表：按群组加载真实频道，支持默认频道懒创建。
- 成员列表：读取群组成员并映射到聊天侧栏。
- 消息列表：分页加载频道消息，支持搜索和向上加载更多。
- 消息发送：支持文本、回复、附件上传后关联消息。
- 消息操作：支持编辑、删除、置顶/取消置顶。
- 表情反应：支持添加/取消表情反应。
- 频道管理：支持创建、编辑、删除频道。
- 频道静音：支持当前用户对频道静音/取消静音。
- 实时通信：WebSocket 已改为 v2 登录态鉴权，并按聊天频道房间订阅消息事件。

第一版暂不包含私信、频道级独立成员白名单、语音/视频通话、输入中状态、完整在线状态服务、消息撤回与审计展示。

## 2. 数据库变化

变更文件：`doc/neko_tribe-oracle-v2.sql`

新增序列：

- `seq_chat_channel_id`
- `seq_chat_message_id`
- `seq_chat_message_media_id`

新增表：

- `n_chat_channels`：群组频道主表，保存频道名称、类型、分类、排序、私密状态、最后消息、消息计数。
- `n_chat_messages`：频道消息表，保存文本、系统消息、回复关系、置顶、删除、编辑时间。
- `n_chat_message_media`：聊天消息与 `n_media_assets` 的附件关联表。
- `n_chat_message_reactions`：消息表情反应表，以 `message_id + user_id + emoji` 去重。
- `n_chat_channel_reads`：用户频道已读状态表。
- `n_chat_channel_mutes`：用户频道静音状态表。

新增索引：

- 频道按群组、删除状态、排序查询。
- 消息按频道/群组/作者/回复/置顶查询。
- 附件、反应、已读、静音的高频关联索引。

新增触发器：

- `trg_chat_channels_id`
- `trg_chat_messages_id`
- `trg_chat_message_media_id`
- `trg_chat_channels_updated_at`
- `trg_chat_messages_updated_at`

其他 SQL 调整：

- 为新增聊天表补充 `neko_readonly` 只读授权。
- `DBMS_STATS` 增加聊天相关表统计信息采集。
- 建库完成提示增加“群组聊天”。

## 3. 后端变化

新增服务：`server/services/v2/chat.ts`

核心职责：

- 校验群组成员与频道访问权限。
- 对群组懒创建默认频道：`公告板` 和 `综合讨论`。
- 查询聊天群组、频道、成员、消息。
- 创建/更新/删除频道。
- 创建/编辑/删除消息。
- 设置消息置顶状态。
- 添加/删除消息表情反应。
- 设置频道已读和静音状态。
- 写入消息后发布 WebSocket 事件。

新增 v2 REST API：

- `GET /api/v2/chat/groups`
- `GET /api/v2/chat/groups/:id/channels`
- `POST /api/v2/chat/groups/:id/channels`
- `GET /api/v2/chat/groups/:id/members`
- `PATCH /api/v2/chat/channels/:channel_id`
- `DELETE /api/v2/chat/channels/:channel_id`
- `GET /api/v2/chat/channels/:channel_id/messages`
- `POST /api/v2/chat/channels/:channel_id/messages`
- `PUT /api/v2/chat/channels/:channel_id/read-status`
- `PUT /api/v2/chat/channels/:channel_id/mute-status`
- `PATCH /api/v2/chat/messages/:message_id`
- `DELETE /api/v2/chat/messages/:message_id`
- `PUT /api/v2/chat/messages/:message_id/pin-status`
- `POST /api/v2/chat/messages/:message_id/reactions`
- `DELETE /api/v2/chat/messages/:message_id/reactions`

权限规则：

- 用户必须是群组 `active` 或 `muted` 成员才可访问频道。
- `muted` 成员可读不可发送/编辑。
- 私密频道第一版仅允许 `owner/admin/moderator` 访问。
- 公告频道仅允许 `owner/admin/moderator` 发送。
- 频道创建、编辑、删除需要 `owner/admin/moderator`。
- 消息编辑仅允许作者本人。
- 消息删除允许作者本人或群组管理角色。
- 消息置顶仅允许群组管理角色。

WebSocket 变化：

- `server/routes/_ws.ts` 改为 v2 token 鉴权。
- 连接时从 query、Authorization header 或 `access_token` cookie 提取 token。
- 校验 `n_auth_sessions` 未撤销且 access token 未过期。
- 支持客户端消息：
  - `chat_join_channel`
  - `chat_leave_channel`
  - `ping`
- 加入频道时会二次校验频道访问权限。
- 服务端推送事件：
  - `chat_message`
  - `chat_message_updated`
  - `chat_message_deleted`
  - `chat_reaction_updated`
  - `system_notification`
  - `pong`
  - `error`

Oracle 连接变化：

- 新增 `server/utils/oracle.ts`，把 Oracle pool 初始化、取连接、关闭连接抽到可复用工具。
- `server/plugins/02-oracle.ts` 继续负责把 `getOracleConnection` 挂到请求上下文。
- WebSocket 路由可复用同一套 Oracle 连接池做登录态与频道权限校验。

## 4. 前端变化

新增 API 客户端：`app/api/v2/chat.ts`

- 封装聊天群组、频道、成员、消息、反应、置顶、已读、静音接口。
- 已在 `app/api/v2/index.ts` 导出。

新增前端映射服务：`app/services/chat.ts`

- 将 `V2ChatGroup` 映射为聊天页群组 VM。
- 将 `V2ChatChannel` 映射为 `ChatChannelList` 使用的频道模型。
- 将 `V2ChatMember` 映射为 `ChatMemberList` 使用的成员模型。
- 将 `V2ChatMessage` 映射为 `ChatMessage` 使用的消息模型。
- 统一处理头像与媒体资源 URL。

聊天页：`app/pages/chat.vue`

- 移除全部模拟数据。
- 页面初始化时加载当前用户群组、频道、成员、消息。
- 支持切换群组和频道。
- 支持发送文本、回复和附件消息。
- 附件先通过现有 `v2UploadMedia` 上传，再把 `media_id` 传给聊天消息接口。
- 支持搜索消息、加载更多历史消息。
- 接入 WebSocket，当前频道收到消息时增量更新消息列表；非当前频道收到新消息时更新频道预览与未读数。
- 支持频道创建、编辑、删除、静音。
- 支持消息编辑、删除、置顶、反应。

组件调整：

- `ChatChannelList.vue`
  - 支持群组下拉切换。
  - 支持显示当前登录用户名称。
  - 支持 `moderator` 角色相关展示。
- `ChatRoom.vue`
  - 新增 `currentUserId`，移除固定当前用户 ID 为 1 的假设。
  - 发送事件携带回复消息 ID。
  - 新增发送中禁用状态。
- `ChatMessage.vue`
  - 支持 `moderator` 角色。
  - 增加 `canDelete`、`canPin` 控制操作入口。
  - 增加 `channelId`，用于前端实时事件和本地合并。
- `ChatMemberList.vue`
  - 支持 `moderator` 角色展示。
- `i18n/locales/zh.json`、`i18n/locales/en.json`
  - 补充聊天加载、发送、频道管理、消息编辑、反应失败等提示文案。

## 5. 实时事件示例

客户端订阅频道：

```json
{
  "type": "chat_join_channel",
  "data": {
    "channelId": 1
  }
}
```

服务端推送新消息：

```json
{
  "type": "chat_message",
  "room": "chat:channel:1",
  "data": {
    "channel_id": 1,
    "message": {},
    "server_id": "ws_server_xxx"
  },
  "timestamp": 1760000000000
}
```

服务端推送消息删除：

```json
{
  "type": "chat_message_deleted",
  "room": "chat:channel:1",
  "data": {
    "channel_id": 1,
    "message_id": 100
  },
  "timestamp": 1760000000000
}
```

## 6. 验证结果

已执行：

```bash
yarn typecheck
git diff --check
node -e "JSON.parse(...zh/en locale files...)"
```

结果：

- `git diff --check` 通过，没有空白错误；仅有 Git 提示 LF/CRLF 换行转换警告。
- `zh.json`、`en.json` 通过 JSON 解析校验。
- `yarn typecheck` 未通过，但新增聊天相关文件的类型错误已清除。
- 当前剩余失败来自项目既有问题，集中在：
  - `app/api/v2/groups.ts`、`app/api/v2/posts.ts` 既有 query 泛型约束。
  - `app/components/ui/auto-form/*` 与当前 Zod v4 类型不兼容。
  - 多个 v1 API 依赖未被当前 tsconfig 识别的全局类型。
  - 既有 `server/utils/v2.ts`、`server/services/v2/*` 全局 v2 类型未被 server typecheck 正确纳入。
  - `vue-router/volar/sfc-route-blocks` 包导出解析警告。

开发服务器：

- 已启动 Nuxt dev server：`http://127.0.0.1:3001`
- 当前本机 Redis `0.0.0.0:6379` 未连通，访问时可能出现 Redis 降级日志；聊天 REST/WS 还需要本地 Oracle 已执行本次更新后的 v2 SQL。

## 7. 后续建议

- 为聊天补独立迁移脚本，避免只依赖完整基线 SQL。
- 增加频道级成员白名单表，实现真正的私密频道成员授权。
- 增加消息撤回、审计日志和管理员删除原因。
- 增加已读回执列表和未读计数跨端同步。
- 增加输入中状态、在线状态和断线恢复后的增量拉取。
- 将前端 prompt/confirm 替换成项目统一 Dialog 组件。
