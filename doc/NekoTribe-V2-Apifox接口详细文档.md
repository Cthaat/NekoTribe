# NekoTribe API v2 Apifox 接口详细文档

版本：2.0.0
日期：2026-04-26
基础路径：`/api/v2`

## 全局规范

- 认证：除 Auth 中明确公开的接口外，均使用 `Authorization: Bearer <token>`。
- 响应结构：`{ "code": 200, "message": "success", "data": {}, "meta": null }`。
- 分页结构：`meta.page`、`meta.page_size`、`meta.total`、`meta.has_next`。
- JSON 字段：统一使用 `snake_case`。
- 不开放接口：v1 的 `system/config`、`test/test-oracle`、普通客户端发送通知接口不纳入正式 v2 开放契约。

## 错误码

| code | HTTP | 说明 |
| --- | --- | --- |
| 40001 | 400 | 请求参数错误 |
| 40101 | 401 | 未认证或 token 无效 |
| 40301 | 403 | 权限不足 |
| 40401 | 404 | 资源不存在 |
| 40901 | 409 | 资源冲突 |
| 42201 | 422 | 业务规则不允许 |
| 50001 | 500 | 服务器内部错误 |

## Auth

### POST /api/v2/auth/otp

创建邮箱验证码 OTP

认证：不需要

参数：

无

请求体：

```json
{
  "account": "demo@example.com",
  "type": "register",
  "channel": "email"
}
```

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "account": "demo@example.com",
    "verification_id": "otp_9d6f",
    "expires_at": "2026-04-26T01:05:00Z"
  },
  "meta": null
}
```


### POST /api/v2/auth/otp/verification

校验 OTP

认证：不需要

参数：

无

请求体：

```json
{
  "account": "demo@example.com",
  "type": "register",
  "verification_id": "otp_9d6f",
  "code": "123456"
}
```

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "account": "demo@example.com",
    "verified": true,
    "verified_at": "2026-04-26T01:03:00Z"
  },
  "meta": null
}
```


### POST /api/v2/auth/registration

注册用户

认证：不需要

参数：

无

请求体：

```json
{
  "email": "demo@example.com",
  "username": "demo",
  "password": "Password123",
  "confirm_password": "Password123",
  "display_name": "Demo",
  "bio": "hello",
  "location": "Shanghai",
  "phone": "13800138000",
  "birth_date": "2000-01-01",
  "verification_id": "otp_9d6f",
  "agree_to_terms": true
}
```

成功响应：

```json
{
  "code": 200,
  "message": "registration success",
  "data": {
    "user": {
      "user_id": 1001,
      "username": "demo",
      "display_name": "Demo",
      "avatar_url": "/upload/avatars/1001.png",
      "bio": "hello",
      "location": "Shanghai",
      "website": "https://example.com",
      "is_verified": 1,
      "followers_count": 10,
      "following_count": 20,
      "posts_count": 30,
      "likes_count": 40,
      "relationship": {
        "is_self": false,
        "is_following": true,
        "is_blocked": false,
        "is_blocking": false,
        "relation": "following"
      },
      "email": "demo@example.com",
      "phone": "13800138000",
      "birth_date": "2000-01-01",
      "email_verified_at": "2026-04-26T01:00:00Z",
      "is_active": 1,
      "status": "active",
      "created_at": "2026-04-01T00:00:00Z",
      "updated_at": "2026-04-26T01:00:00Z"
    }
  },
  "meta": null
}
```


### POST /api/v2/auth/tokens

登录并创建会话

认证：不需要

参数：

无

请求体：

```json
{
  "account": "demo@example.com",
  "password": "Password123",
  "remember_me": true
}
```

成功响应：

```json
{
  "code": 200,
  "message": "login success",
  "data": {
    "user": {
      "user_id": 1001,
      "username": "demo",
      "display_name": "Demo",
      "avatar_url": "/upload/avatars/1001.png",
      "bio": "hello",
      "location": "Shanghai",
      "website": "https://example.com",
      "is_verified": 1,
      "followers_count": 10,
      "following_count": 20,
      "posts_count": 30,
      "likes_count": 40,
      "relationship": {
        "is_self": false,
        "is_following": true,
        "is_blocked": false,
        "is_blocking": false,
        "relation": "following"
      },
      "email": "demo@example.com",
      "phone": "13800138000",
      "birth_date": "2000-01-01",
      "email_verified_at": "2026-04-26T01:00:00Z",
      "is_active": 1,
      "status": "active",
      "created_at": "2026-04-01T00:00:00Z",
      "updated_at": "2026-04-26T01:00:00Z"
    },
    "tokens": {
      "session_id": "sess_9d6f",
      "access_token_expires_at": "2026-04-26T03:00:00Z",
      "refresh_token_expires_at": "2026-05-26T01:00:00Z"
    }
  },
  "meta": null
}
```


### PATCH /api/v2/auth/tokens/current

刷新当前会话 token

认证：需要

参数：

无

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "session_id": "sess_9d6f",
    "access_token_expires_at": "2026-04-26T03:00:00Z",
    "refresh_token_expires_at": "2026-05-26T01:00:00Z"
  },
  "meta": null
}
```


### DELETE /api/v2/auth/tokens/current

退出当前会话

认证：需要

参数：

无

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "logout success",
  "data": null,
  "meta": null
}
```


### POST /api/v2/auth/password-reset

重置密码

认证：不需要

参数：

无

请求体：

```json
{
  "email": "demo@example.com",
  "verification_id": "otp_9d6f",
  "code": "123456",
  "new_password": "NewPassword123"
}
```

成功响应：

```json
{
  "code": 200,
  "message": "password reset success",
  "data": null,
  "meta": null
}
```


### GET /api/v2/auth/sessions

获取我的登录会话

认证：需要

参数：

无

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "session_id": "sess_9d6f",
      "device_info": "Chrome on Windows",
      "ip_address": "127.0.0.1",
      "last_accessed_at": "2026-04-26T01:00:00Z",
      "created_at": "2026-04-26T01:00:00Z",
      "is_current": true
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 1,
    "has_next": true
  }
}
```


### DELETE /api/v2/auth/sessions/{id}

注销指定会话

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 会话 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "session revoked",
  "data": null,
  "meta": null
}
```


### DELETE /api/v2/auth/sessions/others

注销其他会话

认证：需要

参数：

无

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "other sessions revoked",
  "data": {
    "revoked_count": 2
  },
  "meta": null
}
```


## Users

### GET /api/v2/users/me

获取当前用户资料

认证：需要

参数：

无

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "user_id": 1001,
    "username": "demo",
    "display_name": "Demo",
    "avatar_url": "/upload/avatars/1001.png",
    "bio": "hello",
    "location": "Shanghai",
    "website": "https://example.com",
    "is_verified": 1,
    "followers_count": 10,
    "following_count": 20,
    "posts_count": 30,
    "likes_count": 40,
    "relationship": {
      "is_self": false,
      "is_following": true,
      "is_blocked": false,
      "is_blocking": false,
      "relation": "following"
    },
    "email": "demo@example.com",
    "phone": "13800138000",
    "birth_date": "2000-01-01",
    "email_verified_at": "2026-04-26T01:00:00Z",
    "is_active": 1,
    "status": "active",
    "created_at": "2026-04-01T00:00:00Z",
    "updated_at": "2026-04-26T01:00:00Z"
  },
  "meta": null
}
```


### PATCH /api/v2/users/me

更新当前用户资料

认证：需要

参数：

无

请求体：

```json
{
  "display_name": "Demo",
  "bio": "hello",
  "location": "Shanghai",
  "website": "https://example.com",
  "birth_date": "2000-01-01",
  "phone": "13800138000"
}
```

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "user_id": 1001,
    "username": "demo",
    "display_name": "Demo",
    "avatar_url": "/upload/avatars/1001.png",
    "bio": "hello",
    "location": "Shanghai",
    "website": "https://example.com",
    "is_verified": 1,
    "followers_count": 10,
    "following_count": 20,
    "posts_count": 30,
    "likes_count": 40,
    "relationship": {
      "is_self": false,
      "is_following": true,
      "is_blocked": false,
      "is_blocking": false,
      "relation": "following"
    },
    "email": "demo@example.com",
    "phone": "13800138000",
    "birth_date": "2000-01-01",
    "email_verified_at": "2026-04-26T01:00:00Z",
    "is_active": 1,
    "status": "active",
    "created_at": "2026-04-01T00:00:00Z",
    "updated_at": "2026-04-26T01:00:00Z"
  },
  "meta": null
}
```


### PUT /api/v2/users/me/avatar

替换当前用户头像

认证：需要

参数：

无

请求体（multipart/form-data）：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `file` | file | 是 | 头像文件，jpg/png/gif，最大 2MB |

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "avatar_url": "/upload/avatars/1001.png",
    "avatar_media_id": 600001
  },
  "meta": null
}
```


### PATCH /api/v2/users/me/email

修改当前用户邮箱

认证：需要

参数：

无

请求体：

```json
{
  "new_email": "new@example.com",
  "verification_id": "otp_9d6f",
  "code": "123456"
}
```

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "email": "new@example.com",
    "email_verified_at": "2026-04-26T01:00:00Z"
  },
  "meta": null
}
```


### GET /api/v2/users/me/settings

获取当前用户设置

认证：需要

参数：

无

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "user_id": 1001,
    "two_factor_enabled": false,
    "login_alerts": true,
    "profile_visibility": "public",
    "show_online_status": true,
    "allow_dm_from_strangers": false,
    "push_notification_enabled": true,
    "email_notification_enabled": true,
    "updated_at": "2026-04-26T01:00:00Z"
  },
  "meta": null
}
```


### PATCH /api/v2/users/me/settings

更新当前用户设置

认证：需要

参数：

无

请求体：

```json
{
  "login_alerts": true,
  "profile_visibility": "public",
  "show_online_status": true,
  "allow_dm_from_strangers": false,
  "push_notification_enabled": true,
  "email_notification_enabled": true
}
```

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "user_id": 1001,
    "login_alerts": true,
    "profile_visibility": "public",
    "updated_at": "2026-04-26T01:00:00Z"
  },
  "meta": null
}
```


### GET /api/v2/users/me/account-statements

获取账户处置记录

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |
| `status` | query | 否 | all \| unread \| read \| resolved \| dismissed \| appealed | 状态筛选 | all |
| `type` | query | 否 | all \| info \| warning \| strike \| suspension | 类型筛选 | all |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "statement_id": 900001,
      "type": "warning",
      "title": "Potential policy violation",
      "message": "Please review community guidelines.",
      "policy_code": "CG-101",
      "status": "unread",
      "created_at": "2026-04-26T01:00:00Z",
      "updated_at": "2026-04-26T01:00:00Z"
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 1,
    "has_next": true
  }
}
```


### PATCH /api/v2/users/me/account-statements/{id}

更新账户处置记录状态

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 处置记录 ID | - |

请求体：

```json
{
  "action": "mark_read"
}
```

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "statement_id": 900001,
    "status": "read",
    "updated_at": "2026-04-26T01:00:00Z"
  },
  "meta": null
}
```


### POST /api/v2/users/me/account-statements/{id}/appeals

提交处置申诉

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 处置记录 ID | - |

请求体：

```json
{
  "appeal_message": "I believe this action should be reviewed."
}
```

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "statement_id": 900001,
    "status": "appealed",
    "appeal_id": 1000001,
    "appeal_status": "pending"
  },
  "meta": null
}
```


### GET /api/v2/users

搜索用户

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `q` | query | 否 | string | 搜索关键词 | demo |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |
| `sort` | query | 否 | popular \| newest \| oldest \| followers | 排序 | popular |
| `verified` | query | 否 | boolean | 仅认证用户 | false |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "user_id": 1001,
      "username": "demo",
      "display_name": "Demo",
      "avatar_url": "/upload/avatars/1001.png",
      "bio": "hello",
      "location": "Shanghai",
      "website": "https://example.com",
      "is_verified": 1,
      "followers_count": 10,
      "following_count": 20,
      "posts_count": 30,
      "likes_count": 40,
      "relationship": {
        "is_self": false,
        "is_following": true,
        "is_blocked": false,
        "is_blocking": false,
        "relation": "following"
      }
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 1,
    "has_next": true
  }
}
```


### GET /api/v2/users/recommendations

获取推荐用户

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `limit` | query | 否 | integer | 返回数量 | 10 |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "user_id": 1001,
      "username": "demo",
      "display_name": "Demo",
      "avatar_url": "/upload/avatars/1001.png",
      "bio": "hello",
      "location": "Shanghai",
      "website": "https://example.com",
      "is_verified": 1,
      "followers_count": 10,
      "following_count": 20,
      "posts_count": 30,
      "likes_count": 40,
      "relationship": {
        "is_self": false,
        "is_following": true,
        "is_blocked": false,
        "is_blocking": false,
        "relation": "following"
      }
    }
  ],
  "meta": {
    "limit": 10
  }
}
```


### GET /api/v2/users/{id}

获取用户公开资料

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 用户 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "user_id": 1001,
    "username": "demo",
    "display_name": "Demo",
    "avatar_url": "/upload/avatars/1001.png",
    "bio": "hello",
    "location": "Shanghai",
    "website": "https://example.com",
    "is_verified": 1,
    "followers_count": 10,
    "following_count": 20,
    "posts_count": 30,
    "likes_count": 40,
    "relationship": {
      "is_self": false,
      "is_following": true,
      "is_blocked": false,
      "is_blocking": false,
      "relation": "following"
    }
  },
  "meta": null
}
```


### GET /api/v2/users/{id}/analytics

获取用户分析数据

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 用户 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "user_id": 1001,
    "total_posts": 30,
    "posts_this_week": 5,
    "posts_this_month": 12,
    "total_likes_received": 80,
    "avg_likes_per_post": 2.67,
    "total_likes_given": 40,
    "total_comments_made": 18,
    "engagement_score": 72.5
  },
  "meta": null
}
```


### GET /api/v2/users/{id}/posts

获取指定用户帖子

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 用户 ID | - |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |
| `sort` | query | 否 | newest \| oldest \| popular | 排序 | newest |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "post_id": 100001,
      "author": {
        "user_id": 1001,
        "username": "demo",
        "display_name": "Demo",
        "avatar_url": "/upload/avatars/1001.png",
        "bio": "hello",
        "location": "Shanghai",
        "website": "https://example.com",
        "is_verified": 1,
        "followers_count": 10,
        "following_count": 20,
        "posts_count": 30,
        "likes_count": 40,
        "relationship": {
          "is_self": false,
          "is_following": true,
          "is_blocked": false,
          "is_blocking": false,
          "relation": "following"
        }
      },
      "content": "hello world #nuxt",
      "post_type": "post",
      "visibility": "public",
      "language": "zh",
      "location": "Shanghai",
      "reply_to_post_id": null,
      "repost_of_post_id": null,
      "quoted_post_id": null,
      "media": [
        {
          "media_id": 600001,
          "media_type": "image",
          "file_name": "cat.png",
          "public_url": "/upload/media/600001.png",
          "file_size": 102400,
          "mime_type": "image/png",
          "width": 1024,
          "height": 768,
          "duration": null,
          "thumbnail_url": "/upload/media/600001-thumb.png",
          "alt_text": "cat",
          "status": "ready",
          "created_at": "2026-04-26T01:00:00Z"
        }
      ],
      "tags": [
        "nuxt"
      ],
      "mentions": [],
      "stats": {
        "likes_count": 12,
        "comments_count": 3,
        "replies_count": 2,
        "retweets_count": 1,
        "views_count": 100,
        "engagement_score": 8.5
      },
      "viewer_state": {
        "is_liked": false,
        "is_bookmarked": false,
        "can_delete": false
      },
      "created_at": "2026-04-26T01:00:00Z",
      "updated_at": "2026-04-26T01:00:00Z"
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 30,
    "has_next": true
  }
}
```


### GET /api/v2/users/me/posts

获取我的帖子

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "post_id": 100001,
      "author": {
        "user_id": 1001,
        "username": "demo",
        "display_name": "Demo",
        "avatar_url": "/upload/avatars/1001.png",
        "bio": "hello",
        "location": "Shanghai",
        "website": "https://example.com",
        "is_verified": 1,
        "followers_count": 10,
        "following_count": 20,
        "posts_count": 30,
        "likes_count": 40,
        "relationship": {
          "is_self": false,
          "is_following": true,
          "is_blocked": false,
          "is_blocking": false,
          "relation": "following"
        }
      },
      "content": "hello world #nuxt",
      "post_type": "post",
      "visibility": "public",
      "language": "zh",
      "location": "Shanghai",
      "reply_to_post_id": null,
      "repost_of_post_id": null,
      "quoted_post_id": null,
      "media": [
        {
          "media_id": 600001,
          "media_type": "image",
          "file_name": "cat.png",
          "public_url": "/upload/media/600001.png",
          "file_size": 102400,
          "mime_type": "image/png",
          "width": 1024,
          "height": 768,
          "duration": null,
          "thumbnail_url": "/upload/media/600001-thumb.png",
          "alt_text": "cat",
          "status": "ready",
          "created_at": "2026-04-26T01:00:00Z"
        }
      ],
      "tags": [
        "nuxt"
      ],
      "mentions": [],
      "stats": {
        "likes_count": 12,
        "comments_count": 3,
        "replies_count": 2,
        "retweets_count": 1,
        "views_count": 100,
        "engagement_score": 8.5
      },
      "viewer_state": {
        "is_liked": false,
        "is_bookmarked": false,
        "can_delete": false
      },
      "created_at": "2026-04-26T01:00:00Z",
      "updated_at": "2026-04-26T01:00:00Z"
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 30,
    "has_next": true
  }
}
```


### GET /api/v2/users/me/bookmarks

获取我的收藏帖子

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "post_id": 100001,
      "author": {
        "user_id": 1001,
        "username": "demo",
        "display_name": "Demo",
        "avatar_url": "/upload/avatars/1001.png",
        "bio": "hello",
        "location": "Shanghai",
        "website": "https://example.com",
        "is_verified": 1,
        "followers_count": 10,
        "following_count": 20,
        "posts_count": 30,
        "likes_count": 40,
        "relationship": {
          "is_self": false,
          "is_following": true,
          "is_blocked": false,
          "is_blocking": false,
          "relation": "following"
        }
      },
      "content": "hello world #nuxt",
      "post_type": "post",
      "visibility": "public",
      "language": "zh",
      "location": "Shanghai",
      "reply_to_post_id": null,
      "repost_of_post_id": null,
      "quoted_post_id": null,
      "media": [
        {
          "media_id": 600001,
          "media_type": "image",
          "file_name": "cat.png",
          "public_url": "/upload/media/600001.png",
          "file_size": 102400,
          "mime_type": "image/png",
          "width": 1024,
          "height": 768,
          "duration": null,
          "thumbnail_url": "/upload/media/600001-thumb.png",
          "alt_text": "cat",
          "status": "ready",
          "created_at": "2026-04-26T01:00:00Z"
        }
      ],
      "tags": [
        "nuxt"
      ],
      "mentions": [],
      "stats": {
        "likes_count": 12,
        "comments_count": 3,
        "replies_count": 2,
        "retweets_count": 1,
        "views_count": 100,
        "engagement_score": 8.5
      },
      "viewer_state": {
        "is_liked": false,
        "is_bookmarked": false,
        "can_delete": false
      },
      "created_at": "2026-04-26T01:00:00Z",
      "updated_at": "2026-04-26T01:00:00Z"
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 10,
    "has_next": true
  }
}
```


## Relationships

### POST /api/v2/users/{id}/followers

关注用户

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 目标用户 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "target_user_id": 1002,
    "relationship": "following",
    "followers_count": 11
  },
  "meta": null
}
```


### DELETE /api/v2/users/{id}/followers

取消关注用户

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 目标用户 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "target_user_id": 1002,
    "relationship": "none",
    "followers_count": 10
  },
  "meta": null
}
```


### GET /api/v2/users/{id}/followers

获取粉丝列表

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 用户 ID | - |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "user_id": 1001,
      "username": "demo",
      "display_name": "Demo",
      "avatar_url": "/upload/avatars/1001.png",
      "bio": "hello",
      "location": "Shanghai",
      "website": "https://example.com",
      "is_verified": 1,
      "followers_count": 10,
      "following_count": 20,
      "posts_count": 30,
      "likes_count": 40,
      "relationship": {
        "is_self": false,
        "is_following": true,
        "is_blocked": false,
        "is_blocking": false,
        "relation": "following"
      }
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 10,
    "has_next": true
  }
}
```


### GET /api/v2/users/{id}/following

获取关注列表

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 用户 ID | - |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "user_id": 1001,
      "username": "demo",
      "display_name": "Demo",
      "avatar_url": "/upload/avatars/1001.png",
      "bio": "hello",
      "location": "Shanghai",
      "website": "https://example.com",
      "is_verified": 1,
      "followers_count": 10,
      "following_count": 20,
      "posts_count": 30,
      "likes_count": 40,
      "relationship": {
        "is_self": false,
        "is_following": true,
        "is_blocked": false,
        "is_blocking": false,
        "relation": "following"
      }
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 20,
    "has_next": true
  }
}
```


### GET /api/v2/users/{id}/mutual-following

获取共同关注

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 用户 ID | - |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "user_id": 1001,
      "username": "demo",
      "display_name": "Demo",
      "avatar_url": "/upload/avatars/1001.png",
      "bio": "hello",
      "location": "Shanghai",
      "website": "https://example.com",
      "is_verified": 1,
      "followers_count": 10,
      "following_count": 20,
      "posts_count": 30,
      "likes_count": 40,
      "relationship": {
        "is_self": false,
        "is_following": true,
        "is_blocked": false,
        "is_blocking": false,
        "relation": "following"
      }
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 5,
    "has_next": true
  }
}
```


### GET /api/v2/users/me/blocks

获取我的屏蔽列表

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "user_id": 1001,
      "username": "demo",
      "display_name": "Demo",
      "avatar_url": "/upload/avatars/1001.png",
      "bio": "hello",
      "location": "Shanghai",
      "website": "https://example.com",
      "is_verified": 1,
      "followers_count": 10,
      "following_count": 20,
      "posts_count": 30,
      "likes_count": 40,
      "relationship": {
        "is_self": false,
        "is_following": true,
        "is_blocked": false,
        "is_blocking": false,
        "relation": "following"
      }
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 1,
    "has_next": true
  }
}
```


### POST /api/v2/users/me/blocks/{target_id}

屏蔽用户

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `target_id` | path | 是 | integer | 目标用户 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "target_user_id": 1002,
    "relationship": "blocking"
  },
  "meta": null
}
```


### DELETE /api/v2/users/me/blocks/{target_id}

取消屏蔽用户

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `target_id` | path | 是 | integer | 目标用户 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "target_user_id": 1002,
    "relationship": "none"
  },
  "meta": null
}
```


### GET /api/v2/users/me/mutes

获取我的静音列表

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "user_id": 1001,
      "username": "demo",
      "display_name": "Demo",
      "avatar_url": "/upload/avatars/1001.png",
      "bio": "hello",
      "location": "Shanghai",
      "website": "https://example.com",
      "is_verified": 1,
      "followers_count": 10,
      "following_count": 20,
      "posts_count": 30,
      "likes_count": 40,
      "relationship": {
        "is_self": false,
        "is_following": true,
        "is_blocked": false,
        "is_blocking": false,
        "relation": "following"
      },
      "expires_at": "2026-04-27T01:00:00Z"
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 1,
    "has_next": true
  }
}
```


### POST /api/v2/users/me/mutes/{target_id}

静音用户

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `target_id` | path | 是 | integer | 目标用户 ID | - |

请求体：

```json
{
  "expires_at": "2026-04-27T01:00:00Z"
}
```

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "target_user_id": 1002,
    "relationship": "muted",
    "expires_at": "2026-04-27T01:00:00Z"
  },
  "meta": null
}
```


### DELETE /api/v2/users/me/mutes/{target_id}

取消静音用户

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `target_id` | path | 是 | integer | 目标用户 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "target_user_id": 1002,
    "relationship": "none"
  },
  "meta": null
}
```


## Posts

### GET /api/v2/posts

获取帖子列表或搜索帖子

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `timeline` | query | 否 | home \| mentions | 时间线类型 | home |
| `q` | query | 否 | string | 搜索关键词；传入时执行搜索 | nuxt |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |
| `sort` | query | 否 | newest \| oldest \| popular | 排序 | newest |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "post_id": 100001,
      "author": {
        "user_id": 1001,
        "username": "demo",
        "display_name": "Demo",
        "avatar_url": "/upload/avatars/1001.png",
        "bio": "hello",
        "location": "Shanghai",
        "website": "https://example.com",
        "is_verified": 1,
        "followers_count": 10,
        "following_count": 20,
        "posts_count": 30,
        "likes_count": 40,
        "relationship": {
          "is_self": false,
          "is_following": true,
          "is_blocked": false,
          "is_blocking": false,
          "relation": "following"
        }
      },
      "content": "hello world #nuxt",
      "post_type": "post",
      "visibility": "public",
      "language": "zh",
      "location": "Shanghai",
      "reply_to_post_id": null,
      "repost_of_post_id": null,
      "quoted_post_id": null,
      "media": [
        {
          "media_id": 600001,
          "media_type": "image",
          "file_name": "cat.png",
          "public_url": "/upload/media/600001.png",
          "file_size": 102400,
          "mime_type": "image/png",
          "width": 1024,
          "height": 768,
          "duration": null,
          "thumbnail_url": "/upload/media/600001-thumb.png",
          "alt_text": "cat",
          "status": "ready",
          "created_at": "2026-04-26T01:00:00Z"
        }
      ],
      "tags": [
        "nuxt"
      ],
      "mentions": [],
      "stats": {
        "likes_count": 12,
        "comments_count": 3,
        "replies_count": 2,
        "retweets_count": 1,
        "views_count": 100,
        "engagement_score": 8.5
      },
      "viewer_state": {
        "is_liked": false,
        "is_bookmarked": false,
        "can_delete": false
      },
      "created_at": "2026-04-26T01:00:00Z",
      "updated_at": "2026-04-26T01:00:00Z"
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 100,
    "has_next": true
  }
}
```


### POST /api/v2/posts

创建帖子

认证：需要

参数：

无

请求体：

```json
{
  "content": "hello world",
  "visibility": "public",
  "media_ids": [
    600001
  ],
  "tag_names": [
    "nuxt"
  ],
  "mention_user_ids": [
    1002
  ],
  "reply_to_post_id": null,
  "repost_of_post_id": null,
  "quoted_post_id": null,
  "location": "Shanghai"
}
```

成功响应：

```json
{
  "code": 200,
  "message": "post created",
  "data": {
    "post_id": 100001,
    "author": {
      "user_id": 1001,
      "username": "demo",
      "display_name": "Demo",
      "avatar_url": "/upload/avatars/1001.png",
      "bio": "hello",
      "location": "Shanghai",
      "website": "https://example.com",
      "is_verified": 1,
      "followers_count": 10,
      "following_count": 20,
      "posts_count": 30,
      "likes_count": 40,
      "relationship": {
        "is_self": false,
        "is_following": true,
        "is_blocked": false,
        "is_blocking": false,
        "relation": "following"
      }
    },
    "content": "hello world #nuxt",
    "post_type": "post",
    "visibility": "public",
    "language": "zh",
    "location": "Shanghai",
    "reply_to_post_id": null,
    "repost_of_post_id": null,
    "quoted_post_id": null,
    "media": [
      {
        "media_id": 600001,
        "media_type": "image",
        "file_name": "cat.png",
        "public_url": "/upload/media/600001.png",
        "file_size": 102400,
        "mime_type": "image/png",
        "width": 1024,
        "height": 768,
        "duration": null,
        "thumbnail_url": "/upload/media/600001-thumb.png",
        "alt_text": "cat",
        "status": "ready",
        "created_at": "2026-04-26T01:00:00Z"
      }
    ],
    "tags": [
      "nuxt"
    ],
    "mentions": [],
    "stats": {
      "likes_count": 12,
      "comments_count": 3,
      "replies_count": 2,
      "retweets_count": 1,
      "views_count": 100,
      "engagement_score": 8.5
    },
    "viewer_state": {
      "is_liked": false,
      "is_bookmarked": false,
      "can_delete": false
    },
    "created_at": "2026-04-26T01:00:00Z",
    "updated_at": "2026-04-26T01:00:00Z"
  },
  "meta": null
}
```


### GET /api/v2/posts/trending

获取热门帖子

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "post_id": 100001,
      "author": {
        "user_id": 1001,
        "username": "demo",
        "display_name": "Demo",
        "avatar_url": "/upload/avatars/1001.png",
        "bio": "hello",
        "location": "Shanghai",
        "website": "https://example.com",
        "is_verified": 1,
        "followers_count": 10,
        "following_count": 20,
        "posts_count": 30,
        "likes_count": 40,
        "relationship": {
          "is_self": false,
          "is_following": true,
          "is_blocked": false,
          "is_blocking": false,
          "relation": "following"
        }
      },
      "content": "hello world #nuxt",
      "post_type": "post",
      "visibility": "public",
      "language": "zh",
      "location": "Shanghai",
      "reply_to_post_id": null,
      "repost_of_post_id": null,
      "quoted_post_id": null,
      "media": [
        {
          "media_id": 600001,
          "media_type": "image",
          "file_name": "cat.png",
          "public_url": "/upload/media/600001.png",
          "file_size": 102400,
          "mime_type": "image/png",
          "width": 1024,
          "height": 768,
          "duration": null,
          "thumbnail_url": "/upload/media/600001-thumb.png",
          "alt_text": "cat",
          "status": "ready",
          "created_at": "2026-04-26T01:00:00Z"
        }
      ],
      "tags": [
        "nuxt"
      ],
      "mentions": [],
      "stats": {
        "likes_count": 12,
        "comments_count": 3,
        "replies_count": 2,
        "retweets_count": 1,
        "views_count": 100,
        "engagement_score": 8.5
      },
      "viewer_state": {
        "is_liked": false,
        "is_bookmarked": false,
        "can_delete": false
      },
      "created_at": "2026-04-26T01:00:00Z",
      "updated_at": "2026-04-26T01:00:00Z"
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 100,
    "has_next": true
  }
}
```


### GET /api/v2/posts/{id}

获取帖子详情

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 帖子 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "post_id": 100001,
    "author": {
      "user_id": 1001,
      "username": "demo",
      "display_name": "Demo",
      "avatar_url": "/upload/avatars/1001.png",
      "bio": "hello",
      "location": "Shanghai",
      "website": "https://example.com",
      "is_verified": 1,
      "followers_count": 10,
      "following_count": 20,
      "posts_count": 30,
      "likes_count": 40,
      "relationship": {
        "is_self": false,
        "is_following": true,
        "is_blocked": false,
        "is_blocking": false,
        "relation": "following"
      }
    },
    "content": "hello world #nuxt",
    "post_type": "post",
    "visibility": "public",
    "language": "zh",
    "location": "Shanghai",
    "reply_to_post_id": null,
    "repost_of_post_id": null,
    "quoted_post_id": null,
    "media": [
      {
        "media_id": 600001,
        "media_type": "image",
        "file_name": "cat.png",
        "public_url": "/upload/media/600001.png",
        "file_size": 102400,
        "mime_type": "image/png",
        "width": 1024,
        "height": 768,
        "duration": null,
        "thumbnail_url": "/upload/media/600001-thumb.png",
        "alt_text": "cat",
        "status": "ready",
        "created_at": "2026-04-26T01:00:00Z"
      }
    ],
    "tags": [
      "nuxt"
    ],
    "mentions": [],
    "stats": {
      "likes_count": 12,
      "comments_count": 3,
      "replies_count": 2,
      "retweets_count": 1,
      "views_count": 100,
      "engagement_score": 8.5
    },
    "viewer_state": {
      "is_liked": false,
      "is_bookmarked": false,
      "can_delete": false
    },
    "created_at": "2026-04-26T01:00:00Z",
    "updated_at": "2026-04-26T01:00:00Z"
  },
  "meta": null
}
```


### DELETE /api/v2/posts/{id}

删除帖子

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 帖子 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "post deleted",
  "data": null,
  "meta": null
}
```


### GET /api/v2/posts/{id}/replies

获取帖子回复流

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 帖子 ID | - |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "post_id": 100001,
      "author": {
        "user_id": 1001,
        "username": "demo",
        "display_name": "Demo",
        "avatar_url": "/upload/avatars/1001.png",
        "bio": "hello",
        "location": "Shanghai",
        "website": "https://example.com",
        "is_verified": 1,
        "followers_count": 10,
        "following_count": 20,
        "posts_count": 30,
        "likes_count": 40,
        "relationship": {
          "is_self": false,
          "is_following": true,
          "is_blocked": false,
          "is_blocking": false,
          "relation": "following"
        }
      },
      "content": "hello world #nuxt",
      "post_type": "post",
      "visibility": "public",
      "language": "zh",
      "location": "Shanghai",
      "reply_to_post_id": null,
      "repost_of_post_id": null,
      "quoted_post_id": null,
      "media": [
        {
          "media_id": 600001,
          "media_type": "image",
          "file_name": "cat.png",
          "public_url": "/upload/media/600001.png",
          "file_size": 102400,
          "mime_type": "image/png",
          "width": 1024,
          "height": 768,
          "duration": null,
          "thumbnail_url": "/upload/media/600001-thumb.png",
          "alt_text": "cat",
          "status": "ready",
          "created_at": "2026-04-26T01:00:00Z"
        }
      ],
      "tags": [
        "nuxt"
      ],
      "mentions": [],
      "stats": {
        "likes_count": 12,
        "comments_count": 3,
        "replies_count": 2,
        "retweets_count": 1,
        "views_count": 100,
        "engagement_score": 8.5
      },
      "viewer_state": {
        "is_liked": false,
        "is_bookmarked": false,
        "can_delete": false
      },
      "created_at": "2026-04-26T01:00:00Z",
      "updated_at": "2026-04-26T01:00:00Z"
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 2,
    "has_next": true
  }
}
```


### GET /api/v2/posts/{id}/retweets

获取帖子转发列表

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 帖子 ID | - |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "post_id": 100001,
      "author": {
        "user_id": 1001,
        "username": "demo",
        "display_name": "Demo",
        "avatar_url": "/upload/avatars/1001.png",
        "bio": "hello",
        "location": "Shanghai",
        "website": "https://example.com",
        "is_verified": 1,
        "followers_count": 10,
        "following_count": 20,
        "posts_count": 30,
        "likes_count": 40,
        "relationship": {
          "is_self": false,
          "is_following": true,
          "is_blocked": false,
          "is_blocking": false,
          "relation": "following"
        }
      },
      "content": "hello world #nuxt",
      "post_type": "post",
      "visibility": "public",
      "language": "zh",
      "location": "Shanghai",
      "reply_to_post_id": null,
      "repost_of_post_id": null,
      "quoted_post_id": null,
      "media": [
        {
          "media_id": 600001,
          "media_type": "image",
          "file_name": "cat.png",
          "public_url": "/upload/media/600001.png",
          "file_size": 102400,
          "mime_type": "image/png",
          "width": 1024,
          "height": 768,
          "duration": null,
          "thumbnail_url": "/upload/media/600001-thumb.png",
          "alt_text": "cat",
          "status": "ready",
          "created_at": "2026-04-26T01:00:00Z"
        }
      ],
      "tags": [
        "nuxt"
      ],
      "mentions": [],
      "stats": {
        "likes_count": 12,
        "comments_count": 3,
        "replies_count": 2,
        "retweets_count": 1,
        "views_count": 100,
        "engagement_score": 8.5
      },
      "viewer_state": {
        "is_liked": false,
        "is_bookmarked": false,
        "can_delete": false
      },
      "created_at": "2026-04-26T01:00:00Z",
      "updated_at": "2026-04-26T01:00:00Z"
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 1,
    "has_next": true
  }
}
```


### POST /api/v2/posts/{id}/retweets

创建转发

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 原帖 ID | - |

请求体：

```json
{
  "content": "",
  "visibility": "public"
}
```

成功响应：

```json
{
  "code": 200,
  "message": "retweet created",
  "data": {
    "post_id": 100001,
    "author": {
      "user_id": 1001,
      "username": "demo",
      "display_name": "Demo",
      "avatar_url": "/upload/avatars/1001.png",
      "bio": "hello",
      "location": "Shanghai",
      "website": "https://example.com",
      "is_verified": 1,
      "followers_count": 10,
      "following_count": 20,
      "posts_count": 30,
      "likes_count": 40,
      "relationship": {
        "is_self": false,
        "is_following": true,
        "is_blocked": false,
        "is_blocking": false,
        "relation": "following"
      }
    },
    "content": "hello world #nuxt",
    "post_type": "repost",
    "visibility": "public",
    "language": "zh",
    "location": "Shanghai",
    "reply_to_post_id": null,
    "repost_of_post_id": 100001,
    "quoted_post_id": null,
    "media": [
      {
        "media_id": 600001,
        "media_type": "image",
        "file_name": "cat.png",
        "public_url": "/upload/media/600001.png",
        "file_size": 102400,
        "mime_type": "image/png",
        "width": 1024,
        "height": 768,
        "duration": null,
        "thumbnail_url": "/upload/media/600001-thumb.png",
        "alt_text": "cat",
        "status": "ready",
        "created_at": "2026-04-26T01:00:00Z"
      }
    ],
    "tags": [
      "nuxt"
    ],
    "mentions": [],
    "stats": {
      "likes_count": 12,
      "comments_count": 3,
      "replies_count": 2,
      "retweets_count": 1,
      "views_count": 100,
      "engagement_score": 8.5
    },
    "viewer_state": {
      "is_liked": false,
      "is_bookmarked": false,
      "can_delete": false
    },
    "created_at": "2026-04-26T01:00:00Z",
    "updated_at": "2026-04-26T01:00:00Z"
  },
  "meta": null
}
```


### GET /api/v2/posts/{id}/likes

获取帖子点赞用户

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 帖子 ID | - |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "user_id": 1001,
      "username": "demo",
      "display_name": "Demo",
      "avatar_url": "/upload/avatars/1001.png",
      "bio": "hello",
      "location": "Shanghai",
      "website": "https://example.com",
      "is_verified": 1,
      "followers_count": 10,
      "following_count": 20,
      "posts_count": 30,
      "likes_count": 40,
      "relationship": {
        "is_self": false,
        "is_following": true,
        "is_blocked": false,
        "is_blocking": false,
        "relation": "following"
      }
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 12,
    "has_next": true
  }
}
```


### POST /api/v2/posts/{id}/likes

点赞帖子

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 帖子 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "post_id": 100001,
    "is_liked": true,
    "likes_count": 13
  },
  "meta": null
}
```


### DELETE /api/v2/posts/{id}/likes

取消点赞帖子

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 帖子 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "post_id": 100001,
    "is_liked": false,
    "likes_count": 12
  },
  "meta": null
}
```


### POST /api/v2/posts/{id}/bookmarks

收藏帖子

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 帖子 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "post_id": 100001,
    "is_bookmarked": true
  },
  "meta": null
}
```


### DELETE /api/v2/posts/{id}/bookmarks

取消收藏帖子

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 帖子 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "post_id": 100001,
    "is_bookmarked": false
  },
  "meta": null
}
```


### GET /api/v2/posts/{id}/comments

获取帖子评论

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 帖子 ID | - |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |
| `sort` | query | 否 | newest \| oldest \| popular | 排序 | newest |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "comment_id": 400001,
      "post_id": 100001,
      "author": {
        "user_id": 1001,
        "username": "demo",
        "display_name": "Demo",
        "avatar_url": "/upload/avatars/1001.png",
        "bio": "hello",
        "location": "Shanghai",
        "website": "https://example.com",
        "is_verified": 1,
        "followers_count": 10,
        "following_count": 20,
        "posts_count": 30,
        "likes_count": 40,
        "relationship": {
          "is_self": false,
          "is_following": true,
          "is_blocked": false,
          "is_blocking": false,
          "relation": "following"
        }
      },
      "parent_comment_id": null,
      "root_comment_id": null,
      "content": "good",
      "stats": {
        "likes_count": 1,
        "replies_count": 0
      },
      "viewer_state": {
        "is_liked": false,
        "can_delete": false
      },
      "created_at": "2026-04-26T01:10:00Z",
      "updated_at": "2026-04-26T01:10:00Z"
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 3,
    "has_next": true
  }
}
```


### POST /api/v2/posts/{id}/comments

发表评论

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 帖子 ID | - |

请求体：

```json
{
  "content": "good",
  "parent_comment_id": null
}
```

成功响应：

```json
{
  "code": 200,
  "message": "comment created",
  "data": {
    "comment_id": 400001,
    "post_id": 100001,
    "author": {
      "user_id": 1001,
      "username": "demo",
      "display_name": "Demo",
      "avatar_url": "/upload/avatars/1001.png",
      "bio": "hello",
      "location": "Shanghai",
      "website": "https://example.com",
      "is_verified": 1,
      "followers_count": 10,
      "following_count": 20,
      "posts_count": 30,
      "likes_count": 40,
      "relationship": {
        "is_self": false,
        "is_following": true,
        "is_blocked": false,
        "is_blocking": false,
        "relation": "following"
      }
    },
    "parent_comment_id": null,
    "root_comment_id": null,
    "content": "good",
    "stats": {
      "likes_count": 1,
      "replies_count": 0
    },
    "viewer_state": {
      "is_liked": false,
      "can_delete": false
    },
    "created_at": "2026-04-26T01:10:00Z",
    "updated_at": "2026-04-26T01:10:00Z"
  },
  "meta": null
}
```


### GET /api/v2/posts/{id}/analytics

获取帖子分析数据

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 帖子 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "post_id": 100001,
    "views_count": 100,
    "likes_count": 12,
    "comments_count": 3,
    "replies_count": 2,
    "retweets_count": 1,
    "engagement_score": 8.5,
    "like_rate": 0.12
  },
  "meta": null
}
```


## Comments

### DELETE /api/v2/comments/{id}

删除评论

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 评论 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "comment deleted",
  "data": null,
  "meta": null
}
```


### POST /api/v2/comments/{id}/likes

点赞评论

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 评论 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "comment_id": 400001,
    "is_liked": true,
    "likes_count": 2
  },
  "meta": null
}
```


### DELETE /api/v2/comments/{id}/likes

取消点赞评论

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 评论 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "comment_id": 400001,
    "is_liked": false,
    "likes_count": 1
  },
  "meta": null
}
```


## Media

### POST /api/v2/media

上传媒体资源

认证：需要

参数：

无

请求体（multipart/form-data）：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `file` | file | 是 | 媒体文件，图片最多 10MB |
| `alt_text` | string | 否 | 替代文本 |

成功响应：

```json
{
  "code": 200,
  "message": "media uploaded",
  "data": {
    "media_id": 600001,
    "media_type": "image",
    "file_name": "cat.png",
    "public_url": "/upload/media/600001.png",
    "file_size": 102400,
    "mime_type": "image/png",
    "width": 1024,
    "height": 768,
    "duration": null,
    "thumbnail_url": "/upload/media/600001-thumb.png",
    "alt_text": "cat",
    "status": "ready",
    "created_at": "2026-04-26T01:00:00Z"
  },
  "meta": null
}
```


### DELETE /api/v2/media/{id}

删除媒体资源

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 媒体 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "media deleted",
  "data": null,
  "meta": null
}
```


## Tags

### GET /api/v2/tags

搜索话题

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `q` | query | 否 | string | 话题关键词 | nuxt |
| `limit` | query | 否 | integer | 返回数量 | 10 |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "tag_id": 700001,
      "name": "nuxt",
      "usage_count": 20,
      "trending_score": 9.5,
      "is_trending": 1
    }
  ],
  "meta": {
    "limit": 10
  }
}
```


### GET /api/v2/tags/trending

获取热门话题

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `limit` | query | 否 | integer | 返回数量 | 10 |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "tag_id": 700001,
      "name": "nuxt",
      "usage_count": 20,
      "trending_score": 9.5,
      "is_trending": 1
    }
  ],
  "meta": {
    "updated_at": "2026-04-26T01:00:00Z"
  }
}
```


### GET /api/v2/tags/{name}/posts

获取话题下帖子

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `name` | path | 是 | string | 话题名称 | - |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |
| `sort` | query | 否 | popular \| newest \| oldest | 排序 | popular |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "post_id": 100001,
      "author": {
        "user_id": 1001,
        "username": "demo",
        "display_name": "Demo",
        "avatar_url": "/upload/avatars/1001.png",
        "bio": "hello",
        "location": "Shanghai",
        "website": "https://example.com",
        "is_verified": 1,
        "followers_count": 10,
        "following_count": 20,
        "posts_count": 30,
        "likes_count": 40,
        "relationship": {
          "is_self": false,
          "is_following": true,
          "is_blocked": false,
          "is_blocking": false,
          "relation": "following"
        }
      },
      "content": "hello world #nuxt",
      "post_type": "post",
      "visibility": "public",
      "language": "zh",
      "location": "Shanghai",
      "reply_to_post_id": null,
      "repost_of_post_id": null,
      "quoted_post_id": null,
      "media": [
        {
          "media_id": 600001,
          "media_type": "image",
          "file_name": "cat.png",
          "public_url": "/upload/media/600001.png",
          "file_size": 102400,
          "mime_type": "image/png",
          "width": 1024,
          "height": 768,
          "duration": null,
          "thumbnail_url": "/upload/media/600001-thumb.png",
          "alt_text": "cat",
          "status": "ready",
          "created_at": "2026-04-26T01:00:00Z"
        }
      ],
      "tags": [
        "nuxt"
      ],
      "mentions": [],
      "stats": {
        "likes_count": 12,
        "comments_count": 3,
        "replies_count": 2,
        "retweets_count": 1,
        "views_count": 100,
        "engagement_score": 8.5
      },
      "viewer_state": {
        "is_liked": false,
        "is_bookmarked": false,
        "can_delete": false
      },
      "created_at": "2026-04-26T01:00:00Z",
      "updated_at": "2026-04-26T01:00:00Z"
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 20,
    "has_next": true
  }
}
```


### GET /api/v2/tags/{name}/analytics

获取话题分析数据

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `name` | path | 是 | string | 话题名称 | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "name": "nuxt",
    "total_posts": 20,
    "total_authors": 5,
    "total_likes": 100,
    "total_views": 1000,
    "tweets_today": 2,
    "weekly_growth_rate": 10.5,
    "avg_engagement_score": 8.5
  },
  "meta": null
}
```


## Recommendations

### POST /api/v2/recommendations/feedback

提交推荐反馈

认证：需要

参数：

无

请求体：

```json
{
  "resource_type": "post",
  "resource_id": 100001,
  "action": "not_interested",
  "reason": "irrelevant"
}
```

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "accepted": true
  },
  "meta": null
}
```


## Notifications

### GET /api/v2/notifications

获取通知列表

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `type` | query | 否 | all \| like \| repost \| comment \| reply \| follow \| mention \| group_invite \| system | 通知类型 | all |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |
| `unread_only` | query | 否 | boolean | 仅未读 | false |
| `show_deleted` | query | 否 | boolean | 显示已删除 | false |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "notification_id": 800001,
      "type": "follow",
      "title": "New follower",
      "message": "demo 关注了你",
      "actor": {
        "user_id": 1001,
        "username": "demo",
        "display_name": "Demo",
        "avatar_url": "/upload/avatars/1001.png",
        "bio": "hello",
        "location": "Shanghai",
        "website": "https://example.com",
        "is_verified": 1,
        "followers_count": 10,
        "following_count": 20,
        "posts_count": 30,
        "likes_count": 40,
        "relationship": {
          "is_self": false,
          "is_following": true,
          "is_blocked": false,
          "is_blocking": false,
          "relation": "following"
        }
      },
      "resource_type": "user",
      "resource_id": 1001,
      "priority": "normal",
      "is_read": 0,
      "read_at": null,
      "created_at": "2026-04-26T01:00:00Z"
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 1,
    "has_next": true
  }
}
```


### PUT /api/v2/notifications/{id}/read-status

更新单条通知已读状态

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 通知 ID | - |

请求体：

```json
{
  "is_read": true
}
```

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "notification_id": 800001,
    "is_read": 1,
    "read_at": "2026-04-26T01:00:00Z"
  },
  "meta": null
}
```


### PUT /api/v2/notifications/read-status

批量标记通知已读

认证：需要

参数：

无

请求体：

```json
{
  "notification_ids": [
    800001,
    800002
  ],
  "is_read": true
}
```

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "updated_count": 2
  },
  "meta": null
}
```


### DELETE /api/v2/notifications/{id}

删除通知

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 通知 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "notification deleted",
  "data": null,
  "meta": null
}
```


### PUT /api/v2/notifications/{id}/restore-status

恢复通知

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 通知 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "notification_id": 800001,
    "deleted_at": null
  },
  "meta": null
}
```


## Groups

### GET /api/v2/groups

搜索/发现群组

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `q` | query | 否 | string | 搜索关键词 | tech |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |
| `privacy` | query | 否 | public \| private | 隐私筛选 | public |
| `sort` | query | 否 | popular \| newest | 排序 | popular |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "group_id": 1,
      "name": "技术交流群",
      "slug": "tech-group",
      "description": "分享技术文章和讨论",
      "avatar_url": "/upload/groups/1.png",
      "cover_url": "/upload/groups/1-cover.png",
      "owner": {
        "user_id": 1001,
        "username": "demo",
        "display_name": "Demo",
        "avatar_url": "/upload/avatars/1001.png",
        "bio": "hello",
        "location": "Shanghai",
        "website": "https://example.com",
        "is_verified": 1,
        "followers_count": 10,
        "following_count": 20,
        "posts_count": 30,
        "likes_count": 40,
        "relationship": {
          "is_self": false,
          "is_following": true,
          "is_blocked": false,
          "is_blocking": false,
          "relation": "following"
        }
      },
      "privacy": "public",
      "privacy_desc": "公开",
      "join_approval": false,
      "post_permission": "all",
      "member_count": 128,
      "post_count": 456,
      "is_active": 1,
      "membership": {
        "is_member": true,
        "role": "member",
        "status": "active",
        "joined_at": "2026-04-26T01:00:00Z"
      },
      "created_at": "2026-04-26T01:00:00Z",
      "updated_at": "2026-04-26T01:00:00Z"
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 100,
    "has_next": true
  }
}
```


### POST /api/v2/groups

创建群组

认证：需要

参数：

无

请求体：

```json
{
  "name": "技术交流群",
  "description": "分享技术文章和讨论",
  "avatar_url": null,
  "cover_url": null,
  "privacy": "public",
  "join_approval": false,
  "post_permission": "all"
}
```

成功响应：

```json
{
  "code": 200,
  "message": "group created",
  "data": {
    "group_id": 1,
    "name": "技术交流群",
    "slug": "tech-group",
    "description": "分享技术文章和讨论",
    "avatar_url": "/upload/groups/1.png",
    "cover_url": "/upload/groups/1-cover.png",
    "owner": {
      "user_id": 1001,
      "username": "demo",
      "display_name": "Demo",
      "avatar_url": "/upload/avatars/1001.png",
      "bio": "hello",
      "location": "Shanghai",
      "website": "https://example.com",
      "is_verified": 1,
      "followers_count": 10,
      "following_count": 20,
      "posts_count": 30,
      "likes_count": 40,
      "relationship": {
        "is_self": false,
        "is_following": true,
        "is_blocked": false,
        "is_blocking": false,
        "relation": "following"
      }
    },
    "privacy": "public",
    "privacy_desc": "公开",
    "join_approval": false,
    "post_permission": "all",
    "member_count": 128,
    "post_count": 456,
    "is_active": 1,
    "membership": {
      "is_member": true,
      "role": "member",
      "status": "active",
      "joined_at": "2026-04-26T01:00:00Z"
    },
    "created_at": "2026-04-26T01:00:00Z",
    "updated_at": "2026-04-26T01:00:00Z"
  },
  "meta": null
}
```


### GET /api/v2/groups/popular

获取热门群组

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `limit` | query | 否 | integer | 返回数量 | 10 |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "group_id": 1,
      "name": "技术交流群",
      "slug": "tech-group",
      "description": "分享技术文章和讨论",
      "avatar_url": "/upload/groups/1.png",
      "cover_url": "/upload/groups/1-cover.png",
      "owner": {
        "user_id": 1001,
        "username": "demo",
        "display_name": "Demo",
        "avatar_url": "/upload/avatars/1001.png",
        "bio": "hello",
        "location": "Shanghai",
        "website": "https://example.com",
        "is_verified": 1,
        "followers_count": 10,
        "following_count": 20,
        "posts_count": 30,
        "likes_count": 40,
        "relationship": {
          "is_self": false,
          "is_following": true,
          "is_blocked": false,
          "is_blocking": false,
          "relation": "following"
        }
      },
      "privacy": "public",
      "privacy_desc": "公开",
      "join_approval": false,
      "post_permission": "all",
      "member_count": 128,
      "post_count": 456,
      "is_active": 1,
      "membership": {
        "is_member": true,
        "role": "member",
        "status": "active",
        "joined_at": "2026-04-26T01:00:00Z"
      },
      "created_at": "2026-04-26T01:00:00Z",
      "updated_at": "2026-04-26T01:00:00Z",
      "activity_score": 356.2
    }
  ],
  "meta": {
    "limit": 10
  }
}
```


### GET /api/v2/users/me/groups

获取我加入的群组

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |
| `role` | query | 否 | owner \| admin \| moderator \| member | 角色筛选 | member |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "group_id": 1,
      "name": "技术交流群",
      "slug": "tech-group",
      "description": "分享技术文章和讨论",
      "avatar_url": "/upload/groups/1.png",
      "cover_url": "/upload/groups/1-cover.png",
      "owner": {
        "user_id": 1001,
        "username": "demo",
        "display_name": "Demo",
        "avatar_url": "/upload/avatars/1001.png",
        "bio": "hello",
        "location": "Shanghai",
        "website": "https://example.com",
        "is_verified": 1,
        "followers_count": 10,
        "following_count": 20,
        "posts_count": 30,
        "likes_count": 40,
        "relationship": {
          "is_self": false,
          "is_following": true,
          "is_blocked": false,
          "is_blocking": false,
          "relation": "following"
        }
      },
      "privacy": "public",
      "privacy_desc": "公开",
      "join_approval": false,
      "post_permission": "all",
      "member_count": 128,
      "post_count": 456,
      "is_active": 1,
      "membership": {
        "is_member": true,
        "role": "member",
        "status": "active",
        "joined_at": "2026-04-26T01:00:00Z"
      },
      "created_at": "2026-04-26T01:00:00Z",
      "updated_at": "2026-04-26T01:00:00Z"
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 5,
    "has_next": true
  }
}
```


### GET /api/v2/groups/by-slug/{slug}

通过 slug 获取群组详情

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `slug` | path | 是 | string | 群组 slug | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "group_id": 1,
    "name": "技术交流群",
    "slug": "tech-group",
    "description": "分享技术文章和讨论",
    "avatar_url": "/upload/groups/1.png",
    "cover_url": "/upload/groups/1-cover.png",
    "owner": {
      "user_id": 1001,
      "username": "demo",
      "display_name": "Demo",
      "avatar_url": "/upload/avatars/1001.png",
      "bio": "hello",
      "location": "Shanghai",
      "website": "https://example.com",
      "is_verified": 1,
      "followers_count": 10,
      "following_count": 20,
      "posts_count": 30,
      "likes_count": 40,
      "relationship": {
        "is_self": false,
        "is_following": true,
        "is_blocked": false,
        "is_blocking": false,
        "relation": "following"
      }
    },
    "privacy": "public",
    "privacy_desc": "公开",
    "join_approval": false,
    "post_permission": "all",
    "member_count": 128,
    "post_count": 456,
    "is_active": 1,
    "membership": {
      "is_member": true,
      "role": "member",
      "status": "active",
      "joined_at": "2026-04-26T01:00:00Z"
    },
    "created_at": "2026-04-26T01:00:00Z",
    "updated_at": "2026-04-26T01:00:00Z"
  },
  "meta": null
}
```


### GET /api/v2/groups/{id}

获取群组详情

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "group_id": 1,
    "name": "技术交流群",
    "slug": "tech-group",
    "description": "分享技术文章和讨论",
    "avatar_url": "/upload/groups/1.png",
    "cover_url": "/upload/groups/1-cover.png",
    "owner": {
      "user_id": 1001,
      "username": "demo",
      "display_name": "Demo",
      "avatar_url": "/upload/avatars/1001.png",
      "bio": "hello",
      "location": "Shanghai",
      "website": "https://example.com",
      "is_verified": 1,
      "followers_count": 10,
      "following_count": 20,
      "posts_count": 30,
      "likes_count": 40,
      "relationship": {
        "is_self": false,
        "is_following": true,
        "is_blocked": false,
        "is_blocking": false,
        "relation": "following"
      }
    },
    "privacy": "public",
    "privacy_desc": "公开",
    "join_approval": false,
    "post_permission": "all",
    "member_count": 128,
    "post_count": 456,
    "is_active": 1,
    "membership": {
      "is_member": true,
      "role": "member",
      "status": "active",
      "joined_at": "2026-04-26T01:00:00Z"
    },
    "created_at": "2026-04-26T01:00:00Z",
    "updated_at": "2026-04-26T01:00:00Z"
  },
  "meta": null
}
```


### PATCH /api/v2/groups/{id}

更新群组信息

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |

请求体：

```json
{
  "name": "技术交流群",
  "description": "分享技术文章和讨论",
  "avatar_url": "/upload/groups/1.png",
  "cover_url": "/upload/groups/1-cover.png",
  "privacy": "public",
  "join_approval": false,
  "post_permission": "all"
}
```

成功响应：

```json
{
  "code": 200,
  "message": "group updated",
  "data": {
    "group_id": 1,
    "name": "技术交流群",
    "slug": "tech-group",
    "description": "分享技术文章和讨论",
    "avatar_url": "/upload/groups/1.png",
    "cover_url": "/upload/groups/1-cover.png",
    "owner": {
      "user_id": 1001,
      "username": "demo",
      "display_name": "Demo",
      "avatar_url": "/upload/avatars/1001.png",
      "bio": "hello",
      "location": "Shanghai",
      "website": "https://example.com",
      "is_verified": 1,
      "followers_count": 10,
      "following_count": 20,
      "posts_count": 30,
      "likes_count": 40,
      "relationship": {
        "is_self": false,
        "is_following": true,
        "is_blocked": false,
        "is_blocking": false,
        "relation": "following"
      }
    },
    "privacy": "public",
    "privacy_desc": "公开",
    "join_approval": false,
    "post_permission": "all",
    "member_count": 128,
    "post_count": 456,
    "is_active": 1,
    "membership": {
      "is_member": true,
      "role": "member",
      "status": "active",
      "joined_at": "2026-04-26T01:00:00Z"
    },
    "created_at": "2026-04-26T01:00:00Z",
    "updated_at": "2026-04-26T01:00:00Z"
  },
  "meta": null
}
```


### DELETE /api/v2/groups/{id}

解散群组

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "group deleted",
  "data": null,
  "meta": null
}
```


### POST /api/v2/groups/{id}/members/current

加入群组

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |

请求体：

```json
{
  "invite_code": "ABC123"
}
```

成功响应：

```json
{
  "code": 200,
  "message": "joined",
  "data": {
    "member_id": 1,
    "group_id": 1,
    "user_id": 1001,
    "role": "member",
    "status": "active"
  },
  "meta": null
}
```


### DELETE /api/v2/groups/{id}/members/current

退出群组

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "left group",
  "data": null,
  "meta": null
}
```


### GET /api/v2/groups/{id}/members

获取群组成员

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |
| `role` | query | 否 | string | 角色筛选 | member |
| `status` | query | 否 | pending \| active \| muted \| banned | 状态筛选 | active |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "member_id": 1,
      "user": {
        "user_id": 1001,
        "username": "demo",
        "display_name": "Demo",
        "avatar_url": "/upload/avatars/1001.png",
        "bio": "hello",
        "location": "Shanghai",
        "website": "https://example.com",
        "is_verified": 1,
        "followers_count": 10,
        "following_count": 20,
        "posts_count": 30,
        "likes_count": 40,
        "relationship": {
          "is_self": false,
          "is_following": true,
          "is_blocked": false,
          "is_blocking": false,
          "relation": "following"
        }
      },
      "role": "owner",
      "role_desc": "群主",
      "status": "active",
      "nickname": null,
      "joined_at": "2026-04-26T01:00:00Z"
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 128,
    "has_next": true
  }
}
```


### PUT /api/v2/groups/{id}/members/{member_id}/approval-status

审批群组成员

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |
| `member_id` | path | 是 | integer | 成员记录 ID | - |

请求体：

```json
{
  "approved": true
}
```

成功响应：

```json
{
  "code": 200,
  "message": "member approved",
  "data": {
    "member_id": 1,
    "status": "active"
  },
  "meta": null
}
```


### DELETE /api/v2/groups/{id}/members/{user_id}

移除群组成员

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |
| `user_id` | path | 是 | integer | 用户 ID | - |

请求体：

```json
{
  "reason": "违规发言"
}
```

成功响应：

```json
{
  "code": 200,
  "message": "member removed",
  "data": null,
  "meta": null
}
```


### PATCH /api/v2/groups/{id}/members/{user_id}/role

变更成员角色

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |
| `user_id` | path | 是 | integer | 用户 ID | - |

请求体：

```json
{
  "role": "moderator"
}
```

成功响应：

```json
{
  "code": 200,
  "message": "role updated",
  "data": {
    "user_id": 1002,
    "role": "moderator"
  },
  "meta": null
}
```


### PUT /api/v2/groups/{id}/members/{user_id}/mute-status

禁言成员

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |
| `user_id` | path | 是 | integer | 用户 ID | - |

请求体：

```json
{
  "duration_hours": 24,
  "reason": "刷屏"
}
```

成功响应：

```json
{
  "code": 200,
  "message": "member muted",
  "data": {
    "user_id": 1002,
    "status": "muted",
    "mute_until": "2026-04-27T01:00:00Z"
  },
  "meta": null
}
```


### DELETE /api/v2/groups/{id}/members/{user_id}/mute-status

解除成员禁言

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |
| `user_id` | path | 是 | integer | 用户 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "member unmuted",
  "data": {
    "user_id": 1002,
    "status": "active"
  },
  "meta": null
}
```


### PUT /api/v2/groups/{id}/ownership

转让群主

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |

请求体：

```json
{
  "new_owner_id": 1002
}
```

成功响应：

```json
{
  "code": 200,
  "message": "ownership transferred",
  "data": {
    "group_id": 1,
    "owner_id": 1002
  },
  "meta": null
}
```


### GET /api/v2/groups/{id}/posts

获取群组帖子

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |
| `type` | query | 否 | all \| pinned \| announcement | 类型 | all |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "post_id": 1,
      "group_id": 1,
      "author": {
        "user_id": 1001,
        "username": "demo",
        "display_name": "Demo",
        "avatar_url": "/upload/avatars/1001.png",
        "bio": "hello",
        "location": "Shanghai",
        "website": "https://example.com",
        "is_verified": 1,
        "followers_count": 10,
        "following_count": 20,
        "posts_count": 30,
        "likes_count": 40,
        "relationship": {
          "is_self": false,
          "is_following": true,
          "is_blocked": false,
          "is_blocking": false,
          "relation": "following"
        }
      },
      "content": "群组帖子内容",
      "media_urls": [
        "/upload/media/1.png"
      ],
      "is_pinned": false,
      "is_announcement": false,
      "likes_count": 42,
      "comments_count": 15,
      "views_count": 256,
      "is_liked_by_me": false,
      "created_at": "2026-04-26T01:00:00Z",
      "updated_at": "2026-04-26T01:00:00Z"
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 456,
    "has_next": true
  }
}
```


### POST /api/v2/groups/{id}/posts

发布群组帖子

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |

请求体：

```json
{
  "content": "群组帖子内容",
  "media_urls": [
    "/upload/media/1.png"
  ]
}
```

成功响应：

```json
{
  "code": 200,
  "message": "group post created",
  "data": {
    "post_id": 1,
    "group_id": 1,
    "author": {
      "user_id": 1001,
      "username": "demo",
      "display_name": "Demo",
      "avatar_url": "/upload/avatars/1001.png",
      "bio": "hello",
      "location": "Shanghai",
      "website": "https://example.com",
      "is_verified": 1,
      "followers_count": 10,
      "following_count": 20,
      "posts_count": 30,
      "likes_count": 40,
      "relationship": {
        "is_self": false,
        "is_following": true,
        "is_blocked": false,
        "is_blocking": false,
        "relation": "following"
      }
    },
    "content": "群组帖子内容",
    "media_urls": [
      "/upload/media/1.png"
    ],
    "is_pinned": false,
    "is_announcement": false,
    "likes_count": 42,
    "comments_count": 15,
    "views_count": 256,
    "is_liked_by_me": false,
    "created_at": "2026-04-26T01:00:00Z",
    "updated_at": "2026-04-26T01:00:00Z"
  },
  "meta": null
}
```


### GET /api/v2/groups/{id}/posts/{post_id}

获取群组帖子详情

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |
| `post_id` | path | 是 | integer | 群组帖子 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "post_id": 1,
    "group_id": 1,
    "author": {
      "user_id": 1001,
      "username": "demo",
      "display_name": "Demo",
      "avatar_url": "/upload/avatars/1001.png",
      "bio": "hello",
      "location": "Shanghai",
      "website": "https://example.com",
      "is_verified": 1,
      "followers_count": 10,
      "following_count": 20,
      "posts_count": 30,
      "likes_count": 40,
      "relationship": {
        "is_self": false,
        "is_following": true,
        "is_blocked": false,
        "is_blocking": false,
        "relation": "following"
      }
    },
    "content": "群组帖子内容",
    "media_urls": [
      "/upload/media/1.png"
    ],
    "is_pinned": false,
    "is_announcement": false,
    "likes_count": 42,
    "comments_count": 15,
    "views_count": 256,
    "is_liked_by_me": false,
    "created_at": "2026-04-26T01:00:00Z",
    "updated_at": "2026-04-26T01:00:00Z"
  },
  "meta": null
}
```


### DELETE /api/v2/groups/{id}/posts/{post_id}

删除群组帖子

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |
| `post_id` | path | 是 | integer | 群组帖子 ID | - |

请求体：

```json
{
  "reason": "违规内容"
}
```

成功响应：

```json
{
  "code": 200,
  "message": "group post deleted",
  "data": null,
  "meta": null
}
```


### PUT /api/v2/groups/{id}/posts/{post_id}/pin-status

更新群组帖子置顶状态

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |
| `post_id` | path | 是 | integer | 群组帖子 ID | - |

请求体：

```json
{
  "is_pinned": true
}
```

成功响应：

```json
{
  "code": 200,
  "message": "pin status updated",
  "data": {
    "post_id": 1,
    "is_pinned": true
  },
  "meta": null
}
```


### POST /api/v2/groups/{id}/posts/{post_id}/likes

点赞群组帖子

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |
| `post_id` | path | 是 | integer | 群组帖子 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "post_id": 1,
    "is_liked": true,
    "likes_count": 43
  },
  "meta": null
}
```


### DELETE /api/v2/groups/{id}/posts/{post_id}/likes

取消点赞群组帖子

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |
| `post_id` | path | 是 | integer | 群组帖子 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "post_id": 1,
    "is_liked": false,
    "likes_count": 42
  },
  "meta": null
}
```


### GET /api/v2/groups/{id}/posts/{post_id}/comments

获取群组帖子评论

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |
| `post_id` | path | 是 | integer | 群组帖子 ID | - |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |
| `sort` | query | 否 | newest \| oldest \| popular | 排序 | newest |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "comment_id": 1,
      "post_id": 1,
      "author": {
        "user_id": 1001,
        "username": "demo",
        "display_name": "Demo",
        "avatar_url": "/upload/avatars/1001.png",
        "bio": "hello",
        "location": "Shanghai",
        "website": "https://example.com",
        "is_verified": 1,
        "followers_count": 10,
        "following_count": 20,
        "posts_count": 30,
        "likes_count": 40,
        "relationship": {
          "is_self": false,
          "is_following": true,
          "is_blocked": false,
          "is_blocking": false,
          "relation": "following"
        }
      },
      "parent_comment_id": null,
      "reply_to_user": null,
      "content": "群组评论",
      "likes_count": 5,
      "is_liked_by_me": false,
      "created_at": "2026-04-26T01:00:00Z",
      "updated_at": "2026-04-26T01:00:00Z"
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 15,
    "has_next": true
  }
}
```


### POST /api/v2/groups/{id}/posts/{post_id}/comments

发布群组评论

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |
| `post_id` | path | 是 | integer | 群组帖子 ID | - |

请求体：

```json
{
  "content": "群组评论",
  "parent_comment_id": null,
  "reply_to_user_id": null
}
```

成功响应：

```json
{
  "code": 200,
  "message": "group comment created",
  "data": {
    "comment_id": 1,
    "post_id": 1,
    "author": {
      "user_id": 1001,
      "username": "demo",
      "display_name": "Demo",
      "avatar_url": "/upload/avatars/1001.png",
      "bio": "hello",
      "location": "Shanghai",
      "website": "https://example.com",
      "is_verified": 1,
      "followers_count": 10,
      "following_count": 20,
      "posts_count": 30,
      "likes_count": 40,
      "relationship": {
        "is_self": false,
        "is_following": true,
        "is_blocked": false,
        "is_blocking": false,
        "relation": "following"
      }
    },
    "parent_comment_id": null,
    "reply_to_user": null,
    "content": "群组评论",
    "likes_count": 5,
    "is_liked_by_me": false,
    "created_at": "2026-04-26T01:00:00Z",
    "updated_at": "2026-04-26T01:00:00Z"
  },
  "meta": null
}
```


### DELETE /api/v2/groups/{id}/posts/{post_id}/comments/{comment_id}

删除群组评论

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |
| `post_id` | path | 是 | integer | 群组帖子 ID | - |
| `comment_id` | path | 是 | integer | 群组评论 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "group comment deleted",
  "data": null,
  "meta": null
}
```


### POST /api/v2/groups/{id}/posts/{post_id}/comments/{comment_id}/likes

点赞群组评论

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |
| `post_id` | path | 是 | integer | 群组帖子 ID | - |
| `comment_id` | path | 是 | integer | 群组评论 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "comment_id": 1,
    "is_liked": true,
    "likes_count": 6
  },
  "meta": null
}
```


### DELETE /api/v2/groups/{id}/posts/{post_id}/comments/{comment_id}/likes

取消点赞群组评论

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |
| `post_id` | path | 是 | integer | 群组帖子 ID | - |
| `comment_id` | path | 是 | integer | 群组评论 ID | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "comment_id": 1,
    "is_liked": false,
    "likes_count": 5
  },
  "meta": null
}
```


### POST /api/v2/groups/{id}/invites

创建群组邀请

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |

请求体：

```json
{
  "invitee_id": null,
  "max_uses": 100,
  "expire_hours": 168,
  "message": "欢迎加入"
}
```

成功响应：

```json
{
  "code": 200,
  "message": "invite created",
  "data": {
    "invite_id": 1,
    "invite_code": "ABC123",
    "invite_url": "https://nekotribe.com/invite/ABC123",
    "expires_at": "2026-05-03T01:00:00Z"
  },
  "meta": null
}
```


### GET /api/v2/groups/{id}/invites

获取群组邀请列表

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |
| `status` | query | 否 | pending \| accepted \| rejected \| expired | 状态筛选 | pending |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "invite_id": 1,
      "invite_code": "ABC123",
      "status": "pending",
      "max_uses": 100,
      "used_count": 0,
      "expires_at": "2026-05-03T01:00:00Z",
      "inviter": {
        "user_id": 1001,
        "username": "demo",
        "display_name": "Demo",
        "avatar_url": "/upload/avatars/1001.png",
        "bio": "hello",
        "location": "Shanghai",
        "website": "https://example.com",
        "is_verified": 1,
        "followers_count": 10,
        "following_count": 20,
        "posts_count": 30,
        "likes_count": 40,
        "relationship": {
          "is_self": false,
          "is_following": true,
          "is_blocked": false,
          "is_blocking": false,
          "relation": "following"
        }
      },
      "invitee": null,
      "is_valid": true
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 1,
    "has_next": true
  }
}
```


### GET /api/v2/groups/invite-codes/{code}

验证邀请码

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `code` | path | 是 | string | 邀请码 | - |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "is_valid": true,
    "group": {
      "group_id": 1,
      "name": "技术交流群",
      "slug": "tech-group",
      "description": "分享技术文章和讨论",
      "avatar_url": "/upload/groups/1.png",
      "cover_url": "/upload/groups/1-cover.png",
      "owner": {
        "user_id": 1001,
        "username": "demo",
        "display_name": "Demo",
        "avatar_url": "/upload/avatars/1001.png",
        "bio": "hello",
        "location": "Shanghai",
        "website": "https://example.com",
        "is_verified": 1,
        "followers_count": 10,
        "following_count": 20,
        "posts_count": 30,
        "likes_count": 40,
        "relationship": {
          "is_self": false,
          "is_following": true,
          "is_blocked": false,
          "is_blocking": false,
          "relation": "following"
        }
      },
      "privacy": "public",
      "privacy_desc": "公开",
      "join_approval": false,
      "post_permission": "all",
      "member_count": 128,
      "post_count": 456,
      "is_active": 1,
      "membership": {
        "is_member": true,
        "role": "member",
        "status": "active",
        "joined_at": "2026-04-26T01:00:00Z"
      },
      "created_at": "2026-04-26T01:00:00Z",
      "updated_at": "2026-04-26T01:00:00Z"
    },
    "inviter": {
      "user_id": 1001,
      "username": "demo",
      "display_name": "Demo",
      "avatar_url": "/upload/avatars/1001.png",
      "bio": "hello",
      "location": "Shanghai",
      "website": "https://example.com",
      "is_verified": 1,
      "followers_count": 10,
      "following_count": 20,
      "posts_count": 30,
      "likes_count": 40,
      "relationship": {
        "is_self": false,
        "is_following": true,
        "is_blocked": false,
        "is_blocking": false,
        "relation": "following"
      }
    },
    "message": "欢迎加入"
  },
  "meta": null
}
```


### POST /api/v2/groups/invites/{invite_id}/responses

响应私人邀请

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `invite_id` | path | 是 | integer | 邀请 ID | - |

请求体：

```json
{
  "accept": true
}
```

成功响应：

```json
{
  "code": 200,
  "message": "invite accepted",
  "data": {
    "invite_id": 1,
    "status": "accepted",
    "group_id": 1
  },
  "meta": null
}
```


### GET /api/v2/groups/{id}/audit-logs

获取群组审计日志

认证：需要

参数：

| 名称 | 位置 | 必填 | 类型 | 说明 | 示例 |
| --- | --- | --- | --- | --- | --- |
| `id` | path | 是 | integer | 群组 ID | - |
| `page` | query | 否 | integer | 页码 | 1 |
| `page_size` | query | 否 | integer | 每页数量 | 20 |
| `action` | query | 否 | string | 动作筛选 | remove_member |
| `actor_id` | query | 否 | integer | 操作者 ID | 1001 |
| `start_date` | query | 否 | string | 开始时间 ISO8601 | 2026-04-01T00:00:00Z |
| `end_date` | query | 否 | string | 结束时间 ISO8601 | 2026-04-30T23:59:59Z |

请求体：无

成功响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {
      "log_id": 1,
      "group_id": 1,
      "actor": {
        "user_id": 1001,
        "username": "demo",
        "display_name": "Demo",
        "avatar_url": "/upload/avatars/1001.png",
        "bio": "hello",
        "location": "Shanghai",
        "website": "https://example.com",
        "is_verified": 1,
        "followers_count": 10,
        "following_count": 20,
        "posts_count": 30,
        "likes_count": 40,
        "relationship": {
          "is_self": false,
          "is_following": true,
          "is_blocked": false,
          "is_blocking": false,
          "relation": "following"
        }
      },
      "target_user": null,
      "target_post_id": null,
      "target_comment_id": null,
      "action": "remove_member",
      "details": {
        "reason": "违规发言"
      },
      "ip_address": "127.0.0.1",
      "created_at": "2026-04-26T01:00:00Z"
    }
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 1,
    "has_next": true
  }
}
```

