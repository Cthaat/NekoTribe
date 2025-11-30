# NekoTribe 群组功能 API 文档

> 版本: 1.0.0  
> 更新日期: 2025-11-30  
> 基础路径: `/api/v1/groups`

---

## 目录

1. [概述](#概述)
2. [认证](#认证)
3. [通用响应格式](#通用响应格式)
4. [群组管理](#群组管理)
   - [创建群组](#创建群组)
   - [获取群组详情](#获取群组详情)
   - [更新群组信息](#更新群组信息)
   - [解散群组](#解散群组)
   - [群组列表](#群组列表)
   - [搜索群组](#搜索群组)
   - [热门群组](#热门群组)
5. [成员管理](#成员管理)
   - [加入群组](#加入群组)
   - [退出群组](#退出群组)
   - [获取成员列表](#获取成员列表)
   - [审批成员](#审批成员)
   - [移除成员](#移除成员)
   - [变更成员角色](#变更成员角色)
   - [禁言成员](#禁言成员)
   - [解除禁言](#解除禁言)
   - [转让群主](#转让群主)
6. [帖子管理](#帖子管理)
   - [发布帖子](#发布帖子)
   - [获取帖子详情](#获取帖子详情)
   - [获取帖子列表](#获取帖子列表)
   - [删除帖子](#删除帖子)
   - [置顶帖子](#置顶帖子)
   - [点赞帖子](#点赞帖子)
7. [评论管理](#评论管理)
   - [发表评论](#发表评论)
   - [获取评论列表](#获取评论列表)
   - [删除评论](#删除评论)
   - [点赞评论](#点赞评论)
8. [邀请管理](#邀请管理)
   - [创建邀请](#创建邀请)
   - [获取邀请列表](#获取邀请列表)
   - [验证邀请码](#验证邀请码)
   - [响应邀请](#响应邀请)
9. [审计日志](#审计日志)
   - [获取审计日志](#获取审计日志)
10. [错误码](#错误码)

---

## 概述

本文档描述了 NekoTribe 群组功能的 RESTful API 接口。群组功能允许用户创建和管理群组、发布帖子、邀请成员等社交互动。

### 特性

- 支持三种隐私模式：公开(public)、私密(private)、隐秘(secret)
- 灵活的角色权限：群主(owner)、管理员(admin)、版主(moderator)、成员(member)
- 完善的审计日志
- 邀请码/私人邀请双模式

---

## 认证

所有 API 请求需要在请求头中携带有效的 JWT Token：

```
Authorization: Bearer <token>
```

未认证的请求将返回 `401 Unauthorized` 错误。

---

## 通用响应格式

### 成功响应

```json
{
  "success": true,
  "message": "操作成功",
  "data": { ... },
  "code": 200,
  "timestamp": "2025-11-30T10:00:00.000Z"
}
```

### 错误响应

```json
{
  "success": false,
  "message": "错误描述",
  "code": 400,
  "timestamp": "2025-11-30T10:00:00.000Z"
}
```

### 分页响应

```json
{
  "success": true,
  "data": {
    "items": [...],
    "pagination": {
      "page": 1,
      "pageSize": 10,
      "totalCount": 100,
      "totalPages": 10
    }
  }
}
```

---

## 群组管理

### 创建群组

创建一个新的群组。

**请求**

```
POST /api/v1/groups
```

**请求体**

| 字段           | 类型    | 必填 | 描述                                              |
| -------------- | ------- | ---- | ------------------------------------------------- |
| name           | string  | ✓    | 群组名称，1-100字符                               |
| description    | string  |      | 群组描述，最多500字符                             |
| avatarUrl      | string  |      | 群组头像URL                                       |
| coverUrl       | string  |      | 群组封面URL                                       |
| privacy        | string  |      | 隐私设置：`public`(默认)/`private`/`secret`       |
| joinApproval   | boolean |      | 是否需要审批加入，默认false                       |
| postPermission | string  |      | 发帖权限：`all`(默认)/`moderator_up`/`admin_only` |

**请求示例**

```json
{
  "name": "技术交流群",
  "description": "分享技术文章和讨论",
  "privacy": "public",
  "joinApproval": false,
  "postPermission": "all"
}
```

**响应**

```json
{
  "success": true,
  "message": "群组创建成功",
  "data": {
    "groupId": 1001,
    "slug": "技术交流群",
    "name": "技术交流群",
    "description": "分享技术文章和讨论",
    "privacy": "public",
    "memberCount": 1,
    "createdAt": "2025-11-30T10:00:00.000Z"
  },
  "code": 200
}
```

---

### 获取群组详情

获取指定群组的详细信息。

**请求**

```
GET /api/v1/groups/:groupId
```

或

```
GET /api/v1/groups/slug/:slug
```

**路径参数**

| 参数    | 类型   | 描述     |
| ------- | ------ | -------- |
| groupId | number | 群组ID   |
| slug    | string | 群组slug |

**响应**

```json
{
  "success": true,
  "data": {
    "group": {
      "groupId": 1001,
      "name": "技术交流群",
      "slug": "技术交流群",
      "description": "分享技术文章和讨论",
      "avatarUrl": "/avatars/group-1001.jpg",
      "coverUrl": "/covers/group-1001.jpg",
      "privacy": "public",
      "privacyDesc": "公开",
      "joinApproval": false,
      "postPermission": "all",
      "memberCount": 128,
      "postCount": 456,
      "isActive": true,
      "createdAt": "2025-11-30T10:00:00.000Z",
      "owner": {
        "userId": 1,
        "username": "admin",
        "displayName": "管理员",
        "avatarUrl": "/avatars/1.jpg",
        "isVerified": true
      }
    },
    "membership": {
      "isMember": true,
      "role": "member",
      "roleDesc": "成员",
      "joinedAt": "2025-11-30T12:00:00.000Z"
    }
  },
  "code": 200
}
```

---

### 更新群组信息

更新群组的基本信息。需要管理员及以上权限。

**请求**

```
PUT /api/v1/groups/:groupId
```

**请求体**

| 字段           | 类型    | 描述         |
| -------------- | ------- | ------------ |
| name           | string  | 群组名称     |
| description    | string  | 群组描述     |
| avatarUrl      | string  | 头像URL      |
| coverUrl       | string  | 封面URL      |
| privacy        | string  | 隐私设置     |
| joinApproval   | boolean | 是否需要审批 |
| postPermission | string  | 发帖权限     |

**响应**

```json
{
  "success": true,
  "message": "群组信息已更新",
  "code": 200
}
```

---

### 解散群组

解散群组（软删除）。仅群主可操作。

**请求**

```
DELETE /api/v1/groups/:groupId
```

**响应**

```json
{
  "success": true,
  "message": "群组已解散",
  "code": 200
}
```

---

### 群组列表

获取当前用户加入的群组列表。

**请求**

```
GET /api/v1/groups/my
```

**查询参数**

| 参数     | 类型   | 默认值 | 描述                                   |
| -------- | ------ | ------ | -------------------------------------- |
| page     | number | 1      | 页码                                   |
| pageSize | number | 10     | 每页数量                               |
| role     | string |        | 筛选角色：owner/admin/moderator/member |

**响应**

```json
{
  "success": true,
  "data": {
    "groups": [
      {
        "groupId": 1001,
        "name": "技术交流群",
        "slug": "技术交流群",
        "avatarUrl": "/avatars/group-1001.jpg",
        "memberCount": 128,
        "postCount": 456,
        "myRole": "member",
        "myRoleDesc": "成员",
        "joinedAt": "2025-11-30T10:00:00.000Z"
      }
    ],
    "pagination": {
      "page": 1,
      "pageSize": 10,
      "totalCount": 5,
      "totalPages": 1
    }
  },
  "code": 200
}
```

---

### 搜索群组

搜索公开的群组。

**请求**

```
GET /api/v1/groups/search
```

**查询参数**

| 参数     | 类型   | 默认值 | 描述       |
| -------- | ------ | ------ | ---------- |
| q        | string |        | 搜索关键词 |
| page     | number | 1      | 页码       |
| pageSize | number | 10     | 每页数量   |

**响应**

```json
{
  "success": true,
  "data": {
    "groups": [
      {
        "groupId": 1001,
        "name": "技术交流群",
        "slug": "技术交流群",
        "description": "分享技术文章和讨论",
        "avatarUrl": "/avatars/group-1001.jpg",
        "memberCount": 128,
        "owner": {
          "userId": 1,
          "displayName": "管理员"
        }
      }
    ],
    "pagination": { ... }
  },
  "code": 200
}
```

---

### 热门群组

获取热门群组列表（按活跃度排序）。

**请求**

```
GET /api/v1/groups/popular
```

**查询参数**

| 参数  | 类型   | 默认值 | 描述     |
| ----- | ------ | ------ | -------- |
| limit | number | 10     | 返回数量 |

**响应**

```json
{
  "success": true,
  "data": {
    "groups": [
      {
        "groupId": 1001,
        "name": "技术交流群",
        "avatarUrl": "/avatars/group-1001.jpg",
        "memberCount": 128,
        "postCount": 456,
        "activityScore": 356.2
      }
    ]
  },
  "code": 200
}
```

---

## 成员管理

### 加入群组

申请加入群组。

**请求**

```
POST /api/v1/groups/:groupId/join
```

**请求体**

| 字段       | 类型   | 描述           |
| ---------- | ------ | -------------- |
| inviteCode | string | 邀请码（可选） |

**响应**

```json
{
  "success": true,
  "message": "成功加入群组",
  "data": {
    "memberId": 5001,
    "status": "active"
  },
  "code": 200
}
```

或（需要审批时）

```json
{
  "success": true,
  "message": "申请已提交，等待管理员审批",
  "data": {
    "memberId": 5001,
    "status": "pending"
  },
  "code": 200
}
```

---

### 退出群组

退出群组。群主需要先转让才能退出。

**请求**

```
POST /api/v1/groups/:groupId/leave
```

**响应**

```json
{
  "success": true,
  "message": "已退出群组",
  "code": 200
}
```

---

### 获取成员列表

获取群组成员列表。

**请求**

```
GET /api/v1/groups/:groupId/members
```

**查询参数**

| 参数     | 类型   | 默认值 | 描述                                  |
| -------- | ------ | ------ | ------------------------------------- |
| page     | number | 1      | 页码                                  |
| pageSize | number | 20     | 每页数量                              |
| role     | string |        | 筛选角色                              |
| status   | string | active | 筛选状态：active/pending/muted/banned |

**响应**

```json
{
  "success": true,
  "data": {
    "members": [
      {
        "memberId": 5001,
        "userId": 1,
        "username": "admin",
        "displayName": "管理员",
        "avatarUrl": "/avatars/1.jpg",
        "isVerified": true,
        "role": "owner",
        "roleDesc": "群主",
        "status": "active",
        "nickname": null,
        "joinedAt": "2025-11-30T10:00:00.000Z"
      }
    ],
    "pagination": { ... }
  },
  "code": 200
}
```

---

### 审批成员

审批待加入的成员。需要版主及以上权限。

**请求**

```
POST /api/v1/groups/:groupId/members/:memberId/approve
```

**请求体**

| 字段    | 类型    | 必填 | 描述                  |
| ------- | ------- | ---- | --------------------- |
| approve | boolean | ✓    | true=批准, false=拒绝 |

**响应**

```json
{
  "success": true,
  "message": "已批准加入",
  "code": 200
}
```

---

### 移除成员

将成员移出群组。需要版主及以上权限，且只能操作比自己权限低的成员。

**请求**

```
DELETE /api/v1/groups/:groupId/members/:userId
```

**请求体**

| 字段   | 类型   | 描述             |
| ------ | ------ | ---------------- |
| reason | string | 移除原因（可选） |

**响应**

```json
{
  "success": true,
  "message": "已移除成员",
  "code": 200
}
```

---

### 变更成员角色

变更成员的角色。

**请求**

```
PUT /api/v1/groups/:groupId/members/:userId/role
```

**请求体**

| 字段 | 类型   | 必填 | 描述                           |
| ---- | ------ | ---- | ------------------------------ |
| role | string | ✓    | 新角色：admin/moderator/member |

**响应**

```json
{
  "success": true,
  "message": "角色变更成功",
  "code": 200
}
```

---

### 禁言成员

禁言指定成员。需要版主及以上权限。

**请求**

```
POST /api/v1/groups/:groupId/members/:userId/mute
```

**请求体**

| 字段          | 类型   | 必填 | 描述             |
| ------------- | ------ | ---- | ---------------- |
| durationHours | number | ✓    | 禁言时长（小时） |
| reason        | string |      | 禁言原因         |

**响应**

```json
{
  "success": true,
  "message": "已禁言成员 24 小时",
  "code": 200
}
```

---

### 解除禁言

解除成员禁言。需要版主及以上权限。

**请求**

```
POST /api/v1/groups/:groupId/members/:userId/unmute
```

**响应**

```json
{
  "success": true,
  "message": "已解除禁言",
  "code": 200
}
```

---

### 转让群主

将群主身份转让给其他成员。

**请求**

```
POST /api/v1/groups/:groupId/transfer
```

**请求体**

| 字段       | 类型   | 必填 | 描述           |
| ---------- | ------ | ---- | -------------- |
| newOwnerId | number | ✓    | 新群主的用户ID |

**响应**

```json
{
  "success": true,
  "message": "群主转让成功",
  "code": 200
}
```

---

## 帖子管理

### 发布帖子

在群组中发布新帖子。

**请求**

```
POST /api/v1/groups/:groupId/posts
```

**请求体**

| 字段      | 类型     | 必填 | 描述                   |
| --------- | -------- | ---- | ---------------------- |
| content   | string   | ✓    | 帖子内容，最多4000字符 |
| mediaUrls | string[] |      | 媒体URL列表            |

**请求示例**

```json
{
  "content": "今天分享一个有趣的技术文章...",
  "mediaUrls": ["/media/image1.jpg", "/media/image2.jpg"]
}
```

**响应**

```json
{
  "success": true,
  "message": "帖子发布成功",
  "data": {
    "postId": 10001,
    "createdAt": "2025-11-30T10:00:00.000Z"
  },
  "code": 200
}
```

---

### 获取帖子详情

获取指定帖子的详细信息。

**请求**

```
GET /api/v1/groups/:groupId/posts/:postId
```

**响应**

```json
{
  "success": true,
  "data": {
    "post": {
      "postId": 10001,
      "groupId": 1001,
      "content": "今天分享一个有趣的技术文章...",
      "mediaUrls": ["/media/image1.jpg"],
      "isPinned": false,
      "isAnnouncement": false,
      "likesCount": 42,
      "commentsCount": 15,
      "viewsCount": 256,
      "createdAt": "2025-11-30T10:00:00.000Z",
      "author": {
        "userId": 1,
        "username": "admin",
        "displayName": "管理员",
        "avatarUrl": "/avatars/1.jpg",
        "role": "owner",
        "roleDesc": "群主"
      },
      "isLikedByMe": true
    }
  },
  "code": 200
}
```

---

### 获取帖子列表

获取群组的帖子列表（时间线）。

**请求**

```
GET /api/v1/groups/:groupId/posts
```

**查询参数**

| 参数     | 类型   | 默认值 | 描述                          |
| -------- | ------ | ------ | ----------------------------- |
| page     | number | 1      | 页码                          |
| pageSize | number | 10     | 每页数量                      |
| type     | string | all    | 类型：all/pinned/announcement |

**响应**

```json
{
  "success": true,
  "data": {
    "posts": [
      {
        "postId": 10001,
        "content": "今天分享一个有趣的技术文章...",
        "mediaUrls": [],
        "isPinned": true,
        "likesCount": 42,
        "commentsCount": 15,
        "createdAt": "2025-11-30T10:00:00.000Z",
        "author": {
          "userId": 1,
          "displayName": "管理员",
          "avatarUrl": "/avatars/1.jpg",
          "role": "owner"
        },
        "isLikedByMe": false
      }
    ],
    "pagination": { ... }
  },
  "code": 200
}
```

---

### 删除帖子

删除帖子（软删除）。作者或版主及以上可操作。

**请求**

```
DELETE /api/v1/groups/:groupId/posts/:postId
```

**请求体**

| 字段   | 类型   | 描述             |
| ------ | ------ | ---------------- |
| reason | string | 删除原因（可选） |

**响应**

```json
{
  "success": true,
  "message": "帖子已删除",
  "code": 200
}
```

---

### 置顶帖子

置顶或取消置顶帖子。需要版主及以上权限。

**请求**

```
POST /api/v1/groups/:groupId/posts/:postId/pin
```

**请求体**

| 字段 | 类型    | 必填 | 描述                      |
| ---- | ------- | ---- | ------------------------- |
| pin  | boolean | ✓    | true=置顶, false=取消置顶 |

**响应**

```json
{
  "success": true,
  "message": "帖子已置顶",
  "code": 200
}
```

---

### 点赞帖子

点赞或取消点赞帖子。

**请求**

```
POST /api/v1/groups/:groupId/posts/:postId/like
```

**请求体**

| 字段   | 类型   | 必填 | 描述               |
| ------ | ------ | ---- | ------------------ |
| action | string | ✓    | `like` 或 `unlike` |

**响应**

```json
{
  "success": true,
  "message": "点赞成功",
  "data": {
    "likesCount": 43
  },
  "code": 200
}
```

---

## 评论管理

### 发表评论

在帖子下发表评论。

**请求**

```
POST /api/v1/groups/:groupId/posts/:postId/comments
```

**请求体**

| 字段            | 类型   | 必填 | 描述                       |
| --------------- | ------ | ---- | -------------------------- |
| content         | string | ✓    | 评论内容，最多1000字符     |
| parentCommentId | number |      | 父评论ID（回复评论时使用） |
| replyToUserId   | number |      | 回复的目标用户ID           |

**响应**

```json
{
  "success": true,
  "message": "评论发布成功",
  "data": {
    "commentId": 20001,
    "createdAt": "2025-11-30T10:00:00.000Z"
  },
  "code": 200
}
```

---

### 获取评论列表

获取帖子的评论列表。

**请求**

```
GET /api/v1/groups/:groupId/posts/:postId/comments
```

**查询参数**

| 参数     | 类型   | 默认值 | 描述                        |
| -------- | ------ | ------ | --------------------------- |
| page     | number | 1      | 页码                        |
| pageSize | number | 20     | 每页数量                    |
| sort     | string | newest | 排序：newest/oldest/popular |

**响应**

```json
{
  "success": true,
  "data": {
    "comments": [
      {
        "commentId": 20001,
        "content": "很棒的分享！",
        "likesCount": 5,
        "createdAt": "2025-11-30T10:30:00.000Z",
        "author": {
          "userId": 2,
          "displayName": "用户A",
          "avatarUrl": "/avatars/2.jpg",
          "role": "member"
        },
        "replyTo": null,
        "replies": [
          {
            "commentId": 20002,
            "content": "谢谢！",
            "author": { ... },
            "replyTo": {
              "userId": 2,
              "displayName": "用户A"
            }
          }
        ],
        "isLikedByMe": false
      }
    ],
    "pagination": { ... }
  },
  "code": 200
}
```

---

### 删除评论

删除评论（软删除）。

**请求**

```
DELETE /api/v1/groups/:groupId/posts/:postId/comments/:commentId
```

**响应**

```json
{
  "success": true,
  "message": "评论已删除",
  "code": 200
}
```

---

### 点赞评论

点赞或取消点赞评论。

**请求**

```
POST /api/v1/groups/:groupId/posts/:postId/comments/:commentId/like
```

**请求体**

| 字段   | 类型   | 必填 | 描述               |
| ------ | ------ | ---- | ------------------ |
| action | string | ✓    | `like` 或 `unlike` |

**响应**

```json
{
  "success": true,
  "message": "点赞成功",
  "code": 200
}
```

---

## 邀请管理

### 创建邀请

创建群组邀请（邀请链接或私人邀请）。

**请求**

```
POST /api/v1/groups/:groupId/invites
```

**请求体**

| 字段        | 类型   | 必填 | 描述                                          |
| ----------- | ------ | ---- | --------------------------------------------- |
| inviteeId   | number |      | 被邀请用户ID（私人邀请）                      |
| maxUses     | number |      | 最大使用次数，默认1                           |
| expireHours | number |      | 过期时间（小时），默认168(7天)，0表示永不过期 |
| message     | string |      | 邀请消息                                      |

**请求示例（公开邀请链接）**

```json
{
  "maxUses": 100,
  "expireHours": 168,
  "message": "欢迎加入我们的技术群！"
}
```

**请求示例（私人邀请）**

```json
{
  "inviteeId": 123,
  "message": "邀请你加入技术群"
}
```

**响应**

```json
{
  "success": true,
  "message": "邀请创建成功",
  "data": {
    "inviteId": 3001,
    "inviteCode": "ABC123XYZ789...",
    "inviteUrl": "https://nekotribe.com/invite/ABC123XYZ789...",
    "expiresAt": "2025-12-07T10:00:00.000Z"
  },
  "code": 200
}
```

---

### 获取邀请列表

获取群组的邀请记录。需要版主及以上权限。

**请求**

```
GET /api/v1/groups/:groupId/invites
```

**查询参数**

| 参数     | 类型   | 默认值 | 描述                                        |
| -------- | ------ | ------ | ------------------------------------------- |
| page     | number | 1      | 页码                                        |
| pageSize | number | 10     | 每页数量                                    |
| status   | string |        | 筛选状态：pending/accepted/rejected/expired |

**响应**

```json
{
  "success": true,
  "data": {
    "invites": [
      {
        "inviteId": 3001,
        "inviteCode": "ABC123...",
        "status": "pending",
        "maxUses": 100,
        "usedCount": 25,
        "expiresAt": "2025-12-07T10:00:00.000Z",
        "createdAt": "2025-11-30T10:00:00.000Z",
        "inviter": {
          "userId": 1,
          "displayName": "管理员"
        },
        "invitee": null,
        "isValid": true
      }
    ],
    "pagination": { ... }
  },
  "code": 200
}
```

---

### 验证邀请码

验证邀请码是否有效。

**请求**

```
GET /api/v1/groups/invite/:inviteCode
```

**响应**

```json
{
  "success": true,
  "data": {
    "isValid": true,
    "group": {
      "groupId": 1001,
      "name": "技术交流群",
      "avatarUrl": "/avatars/group-1001.jpg",
      "memberCount": 128,
      "privacy": "private"
    },
    "inviter": {
      "userId": 1,
      "displayName": "管理员",
      "avatarUrl": "/avatars/1.jpg"
    },
    "message": "欢迎加入我们的技术群！"
  },
  "code": 200
}
```

---

### 响应邀请

响应私人邀请。

**请求**

```
POST /api/v1/groups/invites/:inviteId/respond
```

**请求体**

| 字段   | 类型    | 必填 | 描述                  |
| ------ | ------- | ---- | --------------------- |
| accept | boolean | ✓    | true=接受, false=拒绝 |

**响应**

```json
{
  "success": true,
  "message": "已加入群组",
  "code": 200
}
```

---

## 审计日志

### 获取审计日志

获取群组的操作日志。需要管理员及以上权限。

**请求**

```
GET /api/v1/groups/:groupId/audit-logs
```

**查询参数**

| 参数      | 类型   | 默认值 | 描述                |
| --------- | ------ | ------ | ------------------- |
| page      | number | 1      | 页码                |
| pageSize  | number | 20     | 每页数量            |
| action    | string |        | 筛选操作类型        |
| actorId   | number |        | 筛选操作者          |
| startDate | string |        | 开始日期 (ISO 8601) |
| endDate   | string |        | 结束日期 (ISO 8601) |

**响应**

```json
{
  "success": true,
  "data": {
    "logs": [
      {
        "logId": 50001,
        "action": "remove_member",
        "actionDesc": "移除成员",
        "details": "{\"reason\": \"违规发言\"}",
        "createdAt": "2025-11-30T10:00:00.000Z",
        "actor": {
          "userId": 1,
          "displayName": "管理员",
          "avatarUrl": "/avatars/1.jpg"
        },
        "targetUser": {
          "userId": 5,
          "displayName": "违规用户"
        },
        "targetPost": null,
        "targetComment": null
      }
    ],
    "pagination": { ... }
  },
  "code": 200
}
```

---

## 错误码

| 错误码 | HTTP状态码 | 描述                   |
| ------ | ---------- | ---------------------- |
| 400    | 400        | 请求参数错误           |
| 401    | 401        | 未认证/Token无效       |
| 403    | 403        | 权限不足               |
| 404    | 404        | 资源不存在             |
| 409    | 409        | 资源冲突（如已是成员） |
| 422    | 422        | 业务逻辑错误           |
| 500    | 500        | 服务器内部错误         |

### 常见错误消息

| 消息                 | 说明                             |
| -------------------- | -------------------------------- |
| 群组不存在           | 指定的群组ID不存在或已被删除     |
| 群组已被封禁         | 群组因违规被封禁                 |
| 您不是群组成员       | 需要先加入群组                   |
| 您没有权限执行此操作 | 角色权限不足                     |
| 群主不能退出群组     | 需要先转让群主                   |
| 邀请码无效或已过期   | 邀请码不存在、已被使用完或已过期 |
| 该群组仅限邀请加入   | 隐秘群组需要邀请码               |
| 您已经是群组成员     | 重复加入                         |
| 只有群主可以解散群组 | 权限限制                         |

---

## 附录

### 角色权限矩阵

| 操作         | 群主 | 管理员 | 版主 |    成员    |
| ------------ | :--: | :----: | :--: | :--------: |
| 更新群组信息 |  ✓   |   ✓    |  ✗   |     ✗      |
| 解散群组     |  ✓   |   ✗    |  ✗   |     ✗      |
| 转让群主     |  ✓   |   ✗    |  ✗   |     ✗      |
| 设置管理员   |  ✓   |   ✗    |  ✗   |     ✗      |
| 设置版主     |  ✓   |   ✓    |  ✗   |     ✗      |
| 审批成员     |  ✓   |   ✓    |  ✓   |     ✗      |
| 移除成员     |  ✓   |   ✓    | ✓\*  |     ✗      |
| 禁言成员     |  ✓   |   ✓    | ✓\*  |     ✗      |
| 置顶帖子     |  ✓   |   ✓    |  ✓   |     ✗      |
| 删除他人帖子 |  ✓   |   ✓    |  ✓   |     ✗      |
| 发帖         |  ✓   |   ✓    |  ✓   | 取决于设置 |
| 查看审计日志 |  ✓   |   ✓    |  ✗   |     ✗      |

\*版主只能操作普通成员

### 隐私模式说明

| 模式    | 可见性                     | 加入方式         |
| ------- | -------------------------- | ---------------- |
| public  | 所有人可见                 | 直接加入或需审批 |
| private | 仅成员可见内容，群组可搜索 | 需申请/邀请      |
| secret  | 仅成员可见，不可搜索       | 仅限邀请         |

---

_文档结束_
