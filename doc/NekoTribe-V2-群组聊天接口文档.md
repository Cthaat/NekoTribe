# NekoTribe API v2 群组聊天接口文档

版本：2.0.0
日期：2026-05-09
基础路径：`/api/v2`

## 1. 全局规范

- 认证：本文件所有 REST 接口均需要 v2 登录态，支持 `Authorization: Bearer <access_token>` 或登录后由浏览器携带 `access_token` Cookie。
- 响应结构：

```json
{
  "code": 200,
  "message": "success",
  "data": {},
  "meta": null
}
```

- 分页结构：`meta.page`、`meta.page_size`、`meta.total`、`meta.has_next`。
- JSON 字段：统一使用 `snake_case`。
- 附件：聊天消息附件复用既有 `POST /api/v2/media` 上传接口，发送消息时传入返回的 `media_id`。
- 实时：消息写入、编辑、删除、置顶、反应变更通过 REST 完成；WebSocket 只负责频道订阅和事件推送。

## 2. 错误码

| code | HTTP | 说明 |
| --- | --- | --- |
| 40001 | 400 | 请求参数错误 |
| 40101 | 401 | 未认证或 token 无效 |
| 40301 | 403 | 权限不足 |
| 40401 | 404 | 资源不存在 |
| 40901 | 409 | 资源冲突 |
| 42201 | 422 | 业务规则不允许 |
| 50001 | 500 | 服务器内部错误 |

## 3. 权限规则

- 用户必须是群组 `active` 或 `muted` 成员才可访问群组聊天。
- `muted` 成员可以读取频道和消息，但不能发送或编辑消息。
- 私密频道第一版仅允许 `owner`、`admin`、`moderator` 访问。
- 公告频道仅允许 `owner`、`admin`、`moderator` 发送消息。
- 频道创建、编辑、删除需要 `owner`、`admin`、`moderator`。
- 消息编辑仅允许作者本人。
- 消息删除允许作者本人或群组管理角色。
- 消息置顶/取消置顶仅允许群组管理角色。

## 4. 数据模型

### V2ChatGroup

```json
{
  "group_id": 1,
  "name": "V2 Core Team",
  "avatar_url": "/storage/groups/core.png",
  "member_count": 12,
  "channel_count": 2,
  "unread_count": 5,
  "membership": {
    "is_member": true,
    "role": "owner",
    "status": "active",
    "joined_at": "2026-05-09T02:00:00.000Z",
    "can_manage": true
  }
}
```

### V2ChatChannel

```json
{
  "channel_id": 1,
  "group_id": 1,
  "name": "综合讨论",
  "type": "text",
  "category": "文字频道",
  "position": 20,
  "is_private": false,
  "is_muted_by_me": false,
  "unread_count": 3,
  "last_message": {
    "message_id": 100,
    "content": "今晚继续联调",
    "author_name": "Neko",
    "created_at": "2026-05-09T02:30:00.000Z"
  },
  "created_at": "2026-05-09T02:00:00.000Z",
  "updated_at": "2026-05-09T02:30:00.000Z",
  "can_manage": true
}
```

字段说明：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `type` | `text` / `announcement` / `voice` / `video` | 第一版只有 `text` 和 `announcement` 支持文字消息 |
| `is_private` | boolean | 是否私密频道 |
| `is_muted_by_me` | boolean | 当前用户是否静音该频道 |
| `unread_count` | number | 当前用户未读消息数 |
| `can_manage` | boolean | 当前用户是否可管理该频道 |

### V2ChatMember

```json
{
  "user_id": 1001,
  "username": "neko",
  "display_name": "Neko",
  "avatar_url": "/storage/default-avatar.png",
  "role": "admin",
  "status": "active",
  "online_status": "online"
}
```

### V2ChatMessage

```json
{
  "message_id": 100,
  "channel_id": 1,
  "group_id": 1,
  "message_type": "text",
  "content": "今晚继续联调",
  "author": {
    "user_id": 1001,
    "username": "neko",
    "display_name": "Neko",
    "avatar_url": "/storage/default-avatar.png",
    "bio": "",
    "location": "",
    "website": "",
    "is_verified": 0,
    "followers_count": 0,
    "following_count": 0,
    "posts_count": 0,
    "likes_count": 0,
    "relationship": {
      "is_self": true,
      "is_following": false,
      "is_blocked": false,
      "is_blocking": false,
      "relation": "self"
    }
  },
  "reply_to": null,
  "media": [],
  "reactions": [
    {
      "emoji": "👍",
      "count": 2,
      "reacted_by_me": true
    }
  ],
  "is_pinned": false,
  "is_deleted": false,
  "can_delete": true,
  "can_pin": true,
  "created_at": "2026-05-09T02:30:00.000Z",
  "updated_at": "2026-05-09T02:30:00.000Z",
  "edited_at": null,
  "deleted_at": null
}
```

## 5. 群组聊天接口

### 5.1 GET /api/v2/chat/groups

获取当前用户可访问的聊天群组列表。服务端会为每个没有聊天频道的群组懒创建默认频道：`公告板` 和 `综合讨论`。

认证：需要

Query：

| 参数 | 类型 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- | --- |
| `page` | number | 否 | `1` | 页码 |
| `page_size` | number | 否 | `20` | 每页数量，最大 `100` |

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "group_id": 1,
      "name": "V2 Core Team",
      "avatar_url": "/storage/groups/core.png",
      "member_count": 12,
      "channel_count": 2,
      "unread_count": 5,
      "membership": {
        "is_member": true,
        "role": "owner",
        "status": "active",
        "joined_at": "2026-05-09T02:00:00.000Z",
        "can_manage": true
      }
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 1,
    "has_next": false
  }
}
```

### 5.2 GET /api/v2/chat/groups/{id}/channels

获取指定群组的频道列表。

认证：需要

Path：

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `id` | number | 是 | 群组 ID |

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "channel_id": 1,
      "group_id": 1,
      "name": "公告板",
      "type": "announcement",
      "category": "公告",
      "position": 10,
      "is_private": false,
      "is_muted_by_me": false,
      "unread_count": 0,
      "last_message": null,
      "created_at": "2026-05-09T02:00:00.000Z",
      "updated_at": "2026-05-09T02:00:00.000Z",
      "can_manage": true
    }
  ],
  "meta": null
}
```

### 5.3 POST /api/v2/chat/groups/{id}/channels

创建聊天频道。

认证：需要

权限：群组 `owner`、`admin`、`moderator`

Path：

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `id` | number | 是 | 群组 ID |

请求体：

```json
{
  "name": "技术交流",
  "type": "text",
  "category": "文字频道",
  "is_private": false
}
```

字段说明：

| 字段 | 类型 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- | --- |
| `name` | string | 是 | 无 | 频道名称 |
| `type` | string | 否 | `text` | `text` / `announcement` / `voice` / `video` |
| `category` | string | 否 | `文字频道` | 频道分类 |
| `is_private` | boolean | 否 | `false` | 是否私密频道 |

成功响应：`data` 为 `V2ChatChannel`。

### 5.4 PATCH /api/v2/chat/channels/{channel_id}

编辑聊天频道。

认证：需要

权限：群组 `owner`、`admin`、`moderator`

Path：

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `channel_id` | number | 是 | 频道 ID |

请求体：

```json
{
  "name": "技术讨论",
  "category": "文字频道",
  "is_private": true
}
```

字段说明：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `name` | string | 否 | 新频道名称 |
| `category` | string | 否 | 新频道分类 |
| `is_private` | boolean | 否 | 是否私密 |

成功响应：`data` 为 `V2ChatChannel`。

### 5.5 DELETE /api/v2/chat/channels/{channel_id}

删除聊天频道。当前实现为软删除，频道不再展示。

认证：需要

权限：群组 `owner`、`admin`、`moderator`

Path：

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `channel_id` | number | 是 | 频道 ID |

成功响应：

```json
{
  "code": 200,
  "message": "chat channel deleted",
  "data": null,
  "meta": null
}
```

### 5.6 GET /api/v2/chat/groups/{id}/members

获取群组聊天成员列表。

认证：需要

Path：

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `id` | number | 是 | 群组 ID |

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "user_id": 1001,
      "username": "neko",
      "display_name": "Neko",
      "avatar_url": "/storage/default-avatar.png",
      "role": "owner",
      "status": "active",
      "online_status": "online"
    }
  ],
  "meta": null
}
```

## 6. 频道消息接口

### 6.1 GET /api/v2/chat/channels/{channel_id}/messages

分页获取频道消息。第一页加载成功且存在消息时，服务端会自动把最后一条消息标记为已读。

认证：需要

Path：

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `channel_id` | number | 是 | 频道 ID |

Query：

| 参数 | 类型 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- | --- |
| `page` | number | 否 | `1` | 页码 |
| `page_size` | number | 否 | `20` | 每页数量，最大 `100` |
| `q` | string | 否 | 空 | 按消息内容模糊搜索 |

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "message_id": 100,
      "channel_id": 1,
      "group_id": 1,
      "message_type": "text",
      "content": "今晚继续联调",
      "author": {
        "user_id": 1001,
        "username": "neko",
        "display_name": "Neko",
        "avatar_url": "/storage/default-avatar.png",
        "bio": "",
        "location": "",
        "website": "",
        "is_verified": 0,
        "followers_count": 0,
        "following_count": 0,
        "posts_count": 0,
        "likes_count": 0,
        "relationship": {
          "is_self": true,
          "is_following": false,
          "is_blocked": false,
          "is_blocking": false,
          "relation": "self"
        }
      },
      "reply_to": null,
      "media": [],
      "reactions": [],
      "is_pinned": false,
      "is_deleted": false,
      "can_delete": true,
      "can_pin": true,
      "created_at": "2026-05-09T02:30:00.000Z",
      "updated_at": "2026-05-09T02:30:00.000Z",
      "edited_at": null,
      "deleted_at": null
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 1,
    "has_next": false
  }
}
```

### 6.2 POST /api/v2/chat/channels/{channel_id}/messages

发送频道消息。

认证：需要

权限：

- 用户必须是该群组 `active` 成员。
- `announcement` 频道仅管理角色可发。
- `voice` / `video` 频道第一版不支持发送文字消息。

Path：

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `channel_id` | number | 是 | 频道 ID |

请求体：

```json
{
  "content": "今晚继续联调",
  "reply_to_message_id": null
}
```

字段说明：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `content` | string | 否 | 消息文本；当无附件时必填 |
| `reply_to_message_id` | number / null | 否 | 回复目标消息 ID，必须属于同一频道 |
| `media_ids` | number[] | 否 | 附件媒体 ID，必须先调用 `POST /api/v2/media` 上传或登记媒体，并使用返回的、属于当前用户且状态为 `ready` 的 `media_id` |

附件消息示例：

```json
{
  "content": "今晚继续联调",
  "reply_to_message_id": null,
  "media_ids": [123]
}
```

成功响应：`data` 为 `V2ChatMessage`。

实时事件：成功后频道内订阅用户会收到 `chat_message`。

### 6.3 PATCH /api/v2/chat/messages/{message_id}

编辑消息内容。

认证：需要

权限：仅消息作者本人，且当前群组成员状态必须为 `active`。

Path：

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `message_id` | number | 是 | 消息 ID |

请求体：

```json
{
  "content": "今晚 9 点继续联调"
}
```

成功响应：`data` 为更新后的 `V2ChatMessage`。

实时事件：成功后频道内订阅用户会收到 `chat_message_updated`。

### 6.4 DELETE /api/v2/chat/messages/{message_id}

删除消息。当前实现为软删除。

认证：需要

权限：消息作者本人或群组管理角色。

Path：

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `message_id` | number | 是 | 消息 ID |

成功响应：

```json
{
  "code": 200,
  "message": "chat message deleted",
  "data": null,
  "meta": null
}
```

实时事件：成功后频道内订阅用户会收到 `chat_message_deleted`。

### 6.5 PUT /api/v2/chat/messages/{message_id}/pin-status

设置消息置顶状态。

认证：需要

权限：群组 `owner`、`admin`、`moderator`

Path：

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `message_id` | number | 是 | 消息 ID |

请求体：

```json
{
  "is_pinned": true
}
```

成功响应：`data` 为更新后的 `V2ChatMessage`。

实时事件：成功后频道内订阅用户会收到 `chat_message_updated`。

### 6.6 POST /api/v2/chat/messages/{message_id}/reactions

添加消息表情反应。同一用户对同一消息同一表情只保留一条记录。

认证：需要

Path：

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `message_id` | number | 是 | 消息 ID |

请求体：

```json
{
  "emoji": "👍"
}
```

成功响应：`data` 为更新后的 `V2ChatMessage`。

实时事件：成功后频道内订阅用户会收到 `chat_reaction_updated`。

### 6.7 DELETE /api/v2/chat/messages/{message_id}/reactions

删除消息表情反应。

认证：需要

注意：该接口使用 `DELETE` 请求体传递 `emoji`。如果客户端或代理不支持 DELETE body，需要在客户端层做兼容处理。

Path：

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `message_id` | number | 是 | 消息 ID |

请求体：

```json
{
  "emoji": "👍"
}
```

成功响应：`data` 为更新后的 `V2ChatMessage`。

实时事件：成功后频道内订阅用户会收到 `chat_reaction_updated`。

### 6.8 PUT /api/v2/chat/channels/{channel_id}/read-status

设置频道已读状态。

认证：需要

Path：

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `channel_id` | number | 是 | 频道 ID |

请求体：

```json
{
  "last_read_message_id": 100
}
```

字段说明：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `last_read_message_id` | number / null | 否 | 为空时服务端取当前频道最新未删除消息 |

成功响应：

```json
{
  "code": 200,
  "message": "chat read status updated",
  "data": {
    "channel_id": 1,
    "last_read_message_id": 100,
    "unread_count": 0
  },
  "meta": null
}
```

### 6.9 PUT /api/v2/chat/channels/{channel_id}/mute-status

设置当前用户对频道的静音状态。

认证：需要

Path：

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `channel_id` | number | 是 | 频道 ID |

请求体：

```json
{
  "is_muted": true
}
```

成功响应：

```json
{
  "code": 200,
  "message": "chat channel mute status updated",
  "data": {
    "channel_id": 1,
    "is_muted": true
  },
  "meta": null
}
```

## 7. WebSocket 实时协议

路径：`/_ws`

认证：

- 浏览器同源连接时可自动携带 `access_token` Cookie。
- 也支持 query：`/_ws?token=<access_token>`。
- 也支持 `Authorization: Bearer <access_token>`。

连接成功响应：

```json
{
  "type": "system_notification",
  "data": {
    "message": "WebSocket connected",
    "session_id": "ws_1760000000000_xxxxxx",
    "user_id": 1001
  },
  "timestamp": 1760000000000
}
```

连接失败响应：

```json
{
  "type": "error",
  "data": {
    "message": "WebSocket 未认证"
  },
  "timestamp": 1760000000000
}
```

### 7.1 chat_join_channel

订阅聊天频道。服务端会校验用户是否有权限访问该频道。

客户端发送：

```json
{
  "type": "chat_join_channel",
  "data": {
    "channelId": 1
  }
}
```

成功响应：

```json
{
  "type": "system_notification",
  "data": {
    "message": "chat channel joined",
    "channel_id": 1,
    "room": "chat:channel:1"
  },
  "timestamp": 1760000000000
}
```

### 7.2 chat_leave_channel

取消订阅聊天频道。

客户端发送：

```json
{
  "type": "chat_leave_channel",
  "data": {
    "channelId": 1
  }
}
```

### 7.3 ping

心跳检测。

客户端发送：

```json
{
  "type": "ping"
}
```

服务端响应：

```json
{
  "type": "pong",
  "data": {
    "timestamp": 1760000000000
  },
  "timestamp": 1760000000000
}
```

### 7.4 服务端事件

#### chat_message

新消息事件。

```json
{
  "type": "chat_message",
  "room": "chat:channel:1",
  "data": {
    "channel_id": 1,
    "server_id": "ws_server_xxx",
    "message": {}
  },
  "timestamp": 1760000000000
}
```

`data.message` 为 `V2ChatMessage`。

#### chat_message_updated

消息内容或置顶状态更新事件。

```json
{
  "type": "chat_message_updated",
  "room": "chat:channel:1",
  "data": {
    "channel_id": 1,
    "server_id": "ws_server_xxx",
    "message": {}
  },
  "timestamp": 1760000000000
}
```

`data.message` 为更新后的 `V2ChatMessage`。

#### chat_message_deleted

消息删除事件。

```json
{
  "type": "chat_message_deleted",
  "room": "chat:channel:1",
  "data": {
    "channel_id": 1,
    "server_id": "ws_server_xxx",
    "message_id": 100
  },
  "timestamp": 1760000000000
}
```

#### chat_reaction_updated

消息表情反应更新事件。

```json
{
  "type": "chat_reaction_updated",
  "room": "chat:channel:1",
  "data": {
    "channel_id": 1,
    "server_id": "ws_server_xxx",
    "message": {}
  },
  "timestamp": 1760000000000
}
```

`data.message` 为更新后的 `V2ChatMessage`。

## 8. 前端调用顺序建议

1. 调用 `GET /api/v2/chat/groups` 获取当前用户聊天群组。
2. 选择群组后并行调用：
   - `GET /api/v2/chat/groups/{id}/channels`
   - `GET /api/v2/chat/groups/{id}/members`
3. 选择文字或公告频道后调用：
   - `GET /api/v2/chat/channels/{channel_id}/messages`
4. 建立 `/_ws` 连接并发送 `chat_join_channel`。
5. 发送消息时：
   - 如有附件，先调用 `POST /api/v2/media`。
   - 再调用 `POST /api/v2/chat/channels/{channel_id}/messages`。
6. 收到 `chat_message`、`chat_message_updated`、`chat_message_deleted`、`chat_reaction_updated` 后按 `message_id` 合并或删除本地消息。

## 9. 已知限制

- 第一版没有私信接口。
- 第一版私密频道没有独立成员白名单，仅管理角色可见。
- `voice` / `video` 频道只建模，不提供语音/视频业务能力。
- 已读状态只返回计数，不返回具体已读成员列表。
- WebSocket 只做订阅和推送，发送消息必须走 REST。
- 频道删除为软删除，消息仍保留在数据库中。
