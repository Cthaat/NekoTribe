# NekoTribe V2 接口与 Oracle 重构总设计

## 1. 文档目标

本文档基于当前仓库的后端实现、Oracle SQL 脚本、文件存储工具和 Nuxt Nitro 路由结构整理，目标是：

- 给现有 `server/api/v1/**` 接口做一次完整的 V2 资源化重设计。
- 统一路径、命名、响应结构、控制层职责、SQL 组织方式。
- 修复当前仓库中已经存在的接口语义问题、结构问题、安全问题和数据库设计问题。
- 为后续按 `server/api/v2/**` 和 Oracle DDL 分文件逐步改造提供总蓝图。

本文档只做设计，不直接修改现有业务代码。

## 2. 本次阅读范围

本次设计结论来自以下现有文件和目录：

- `server/api/v1/**`
- `server/utils/**`
- `server/plugins/**`
- `server/middleware/**`
- `server/routes/_ws.ts`
- `data/neko_tribe-oracle.sql`
- `doc/neko_tribe-oracle.sql`
- `doc/neko_tribe-oracle - with-group.sql`
- `data/oracle-init/**`
- `nuxt.config.ts`

## 3. 当前后端现状概览

### 3.1 当前技术组织方式

当前仓库后端主要是以下模式：

- 使用 Nuxt Nitro 文件路由，接口路径基本直接由 `server/api/v1/**` 决定。
- 控制器逻辑、参数校验、SQL、响应拼装大多写在同一个接口文件中。
- Oracle 通过 `event.context.getOracleConnection` 惰性注入。
- Redis 通过 `event.context.redis` 惰性注入。
- JWT、Cookie、会话表、验证码 Redis、文件上传、通知、统计都已经有初版实现。
- 一部分“账户设置/会话/申诉”功能仍是本地 JSON 文件存储，不是数据库正式模型。

### 3.2 当前主要模块

现有 V1 模块大致包括：

- `auth`
- `users`
- `follow`
- `tweets`
- `interactions`
- `hashtags`
- `notifications`
- `analytics`
- `account`
- `system`
- `test`
- `ws`

### 3.3 当前接口实现风格

目前接口整体是“功能导向”而不是“资源导向”：

- 动作型路径较多，如 `get-verification`、`send-tweets`、`action`。
- 列表接口通过 `type=home`、`type=user`、`type=trending` 等参数复用一个路由。
- 不少接口在文件名、HTTP 方法、真实语义之间不一致。
- 响应数据存在深层嵌套和字段风格不统一的问题。

## 4. 当前仓库存在的问题总表

## 4.1 路由与语义问题

| 现有位置 | 当前问题 | V2 解决方案 |
| --- | --- | --- |
| `server/api/v1/auth/logout.get.ts` | `GET` 修改服务端状态，不符合 REST | 改为 `DELETE /api/v2/auth/tokens/current` |
| `server/api/v1/auth/refresh.get.ts` | `GET` 刷新 token，不符合 REST | 改为 `PATCH /api/v2/auth/tokens/current` |
| `server/api/v1/auth/get-verification.post.ts` | `get-verification` 是动作命名 | 改为 `POST /api/v2/auth/otp` |
| `server/api/v1/auth/check-verification.post.ts` | 校验行为仍是动作命名 | 改为 `POST /api/v2/auth/otp/verification` |
| `server/api/v1/tweets/send-tweets.post.ts` | `send-tweets` 不像资源创建 | 改为 `POST /api/v2/posts` |
| `server/api/v1/tweets/list.get.ts` | 一个列表接口承载 home、user、mention、bookmark、trending 多种语义 | 拆成 `GET /posts`、`GET /users/{id}/posts`、`GET /posts/trending`、`GET /users/me/bookmarks` |
| `server/api/v1/tweets/search.post.ts` | 文件名是 `post`，代码却读取 query，接口语义混乱 | 改为 `GET /api/v2/posts?q=...` |
| `server/api/v1/follow/action.post.ts` | follow/unfollow/block/unblock 混在一个 action 字段 | 拆为资源创建和删除 |
| `server/api/v1/interactions/like.post.ts` | 点赞和取消点赞靠 body action 区分 | 拆为 `POST/DELETE /posts/{id}/likes` |
| `server/api/v1/interactions/bookmark.post.ts` | 收藏和取消收藏靠 body action 区分 | 拆为 `POST/DELETE /posts/{id}/bookmarks` |
| `server/api/v1/interactions/comment.post.ts` | 评论接口未体现帖子从属关系 | 改为 `POST /posts/{id}/comments` |
| `server/api/v1/hashtags/search.get.ts` | `hashtags` 与未来接口设计中的 `tags` 不一致 | 统一改为 `/api/v2/tags` |
| `server/api/v1/notifications/list.get.ts` | `list` 冗余 | 改为 `GET /api/v2/notifications` |
| `server/api/v1/notifications/read-all.put.ts` | 批量状态变更命名不统一 | 改为 `PUT /api/v2/notifications/read-status` |

## 4.2 响应结构问题

| 现有位置 | 当前问题 | V2 解决方案 |
| --- | --- | --- |
| `server/type.d.ts` | 全局 `Response` / `ErrorResponse` 与各模块局部类型定义重复 | 建立统一响应 DTO |
| `server/api/v1/users/me.get.ts` | `data.userData.userInfo` 多层嵌套 | 扁平化为 `data.username`、`data.display_name` 等 |
| `server/api/v1/users/[userId].get.ts` | 同样存在 `data.userData.userInfo` 嵌套 | 统一扁平结构 |
| `server/api/v1/auth/login.post.ts` | `data.user.userInfo` 深层嵌套 | 改为 `data.user` 与 `data.tokens` |
| 多个接口 | 同时存在 `success`、`code`、`timestamp`、`message` 的不一致组合 | 统一为 `code/message/data/meta` |
| 多个分页接口 | 分页信息散落在 `data.page`、`data.totalCount` 等字段中 | 统一移动到 `meta` |

## 4.3 安全问题

| 现有位置 | 当前问题 | V2 解决方案 |
| --- | --- | --- |
| `server/api/v1/auth/login.post.ts` | 返回 `passwordHash` 给前端 | V2 禁止任何密码哈希出现在响应中 |
| `server/api/v1/users/me.get.ts` | 返回 `passwordHash` 给前端 | V2 禁止返回 |
| `server/api/v1/auth/login.post.ts` | 数据库会话表存储原始 access token 和 refresh token CLOB | 改为只存 `refresh_token_hash` 和 `access_jti/session_id` |
| `server/middleware/auth.ts` | 只放行 `/api/v1/auth/**`，V2 上线后会误拦截 `/api/v2/auth/**` | 中间件按版本白名单统一处理 |
| 上传接口 | 媒体与头像路径、数据库引用、物理文件删除逻辑耦合较深 | 改为统一媒体资源中心 |

## 4.4 文件结构问题

| 现有位置 | 当前问题 | V2 解决方案 |
| --- | --- | --- |
| `server/api/v1/**` | 路由文件直接拼 SQL 和业务逻辑，文件职责过重 | 路由、控制器、服务、仓储、SQL 分层 |
| `server/utils/userSettingsStore.ts` | 账户设置使用本地 JSON 文件存储 | 迁移到 Oracle `n_user_settings` |
| `server/utils/sessionsStore.ts` | 会话列表使用本地 JSON 文件存储，与真实登录会话模型分离 | 统一迁移到 `n_auth_sessions` |
| `server/utils/statementsStore.ts` | 账户状态与申诉使用本地 JSON 文件存储 | 迁移到 `n_account_statements` 和 `n_statement_appeals` |
| `server/api/v1/account/**` | 一部分账户接口走文件存储，一部分鉴权又依赖 Oracle | V2 合并成统一账户域模型 |
| `server/api/v1/system/config.get.ts` | 配置接口直接读文件返回给前端，边界较弱 | 保留为内部接口，不纳入开放 API |
| `server/api/v1/test/test-oracle.get.ts` | 测试接口暴露数据库联通性 | 生产环境移除 |

## 4.5 代码层逻辑问题

以下问题是本次阅读中已经确认的具体实现问题：

- `server/api/v1/users/me.put.ts`
  - 用 `UPDATE` 之后判断 `userInfo.rows?.length === 0`，但更新语句不返回 `rows`，应判断 `rowsAffected`。
- `server/api/v1/interactions/like.post.ts`
  - `body.likeType === 'like' || 'unlike' || ...` 写法恒真，实际不会正确校验 action。
- `server/api/v1/interactions/bookmark.post.ts`
  - `body.bookmarkType === 'mark' || 'unmark'` 同样恒真。
- `server/api/v1/hashtags/[tag]/tweets.get.ts`
  - 存在硬编码 `1147`。
  - 用 `h.hashtag_id = LOWER(:tag)`，路径参数名叫 tag，但 SQL 按 id 比较，语义错误。
- `server/api/v1/notifications/read-all.put.ts`
  - 读取了 `notificationId` 路径参数，但接口本质是“全部已读”，参数没有意义。
- `server/api/v1/follow/[userId]/followers.get.ts`
  - join 和查询方向不清晰，容易把关注者/被关注者查反。
- `server/api/v1/follow/[userId]/following.get.ts`
  - 同样存在 follower/following 方向混乱风险。
- `server/api/v1/tweets/[tweetId]/retweets.get.ts`
  - 统计 SQL 写的是 `reply_to_tweet_id = :tweetId`，不是 `retweet_of_tweet_id = :tweetId`。
- `server/api/v1/tweets/[tweetId].get.ts`
  - `v_tweet_details` 中媒体是 `LISTAGG` 字符串，但接口类型定义成数组。

## 4.6 Oracle 脚本与对象设计问题

以下问题来自现有 `data/neko_tribe-oracle.sql` 和文档 SQL：

- `sp_manage_follow` 使用 `seq_user_id.nextval` 生成 `follow_id`，序列选错。
- `sp_create_tweet` 创建 hashtag 时也使用 `seq_user_id.nextval`，序列选错。
- `sp_delete_comment` 过程定义中形参列表有多余逗号，DDL 本身存在错误风险。
- `n_follows` 用 `follow_type` 混装 `follow`、`block`、`mute`，后续资源化很难管理。
- `n_likes` 把评论点赞和帖子点赞都塞进 `tweet_id`，表语义不清。
- `v_comprehensive_timeline.is_from_following` 不是面向当前 viewer 计算，而是“只要有人关注该作者就标记”，语义错误。
- 代码中使用 `v_hashtag_trends`，SQL 中没有定义同名视图，接口和数据库对象不一致。
- `n_user_sessions` 直接存原始 access token / refresh token CLOB，不利于安全和索引。

## 5. V2 全局设计规范

### 5.1 统一前缀

所有开放接口统一以：

```text
/api/v2
```

开头。

### 5.2 命名规范

- 路径使用 `kebab-case`
- JSON 字段使用 `snake_case`
- 路径参数统一使用 `{id}`、`{target_id}`、`{post_id}` 这类语义明确的命名

### 5.3 HTTP 方法语义

- `POST`
  - 创建资源
  - 例如登录、发帖、点赞、评论、关注
- `GET`
  - 查询资源
  - 例如列表、详情、搜索、统计
- `PATCH`
  - 局部修改
  - 例如刷新 token、更新用户资料、修改邮箱
- `PUT`
  - 完整替换或明确的状态资源覆盖
  - 例如头像上传、通知 read-status 更新
- `DELETE`
  - 删除或取消关系
  - 例如登出、删除帖子、取消点赞、取关

### 5.4 统一响应结构

```json
{
  "code": 200,
  "message": "success",
  "data": {},
  "meta": null
}
```

分页响应：

```json
{
  "code": 200,
  "message": "success",
  "data": [
    {}
  ],
  "meta": {
    "page": 1,
    "page_size": 20,
    "total": 100,
    "has_next": true
  }
}
```

错误响应：

```json
{
  "code": 40001,
  "message": "invalid request",
  "data": null,
  "meta": null
}
```

### 5.5 DTO 约束

- 禁止返回 `password_hash`
- 禁止返回数据库内部调试字段
- 禁止多层业务嵌套，例如：
  - 不要 `data.userData.userInfo.username`
  - 直接返回 `data.username`

## 6. 推荐目录结构

## 6.1 推荐后端目录

```text
server/
  api/
    v2/
      auth/
        otp.post.ts
        otp/
          verification.post.ts
        registration.post.ts
        tokens.post.ts
        tokens/
          current.delete.ts
          current.patch.ts
        password-reset.post.ts
        sessions/
          index.get.ts
          [id].delete.ts
          others.delete.ts
      users/
        index.get.ts
        me.get.ts
        me.patch.ts
        me/
          avatar.put.ts
          email.patch.ts
          blocks.get.ts
          blocks/
            [targetId].post.ts
            [targetId].delete.ts
          settings.get.ts
          settings.patch.ts
          account-statements.get.ts
          account-statements/
            [id].patch.ts
            [id]/
              appeals.post.ts
          bookmarks.get.ts
          posts.get.ts
        recommendations.get.ts
        [id].get.ts
        [id]/
          followers.get.ts
          followers.post.ts
          followers.delete.ts
          following.get.ts
          mutual-following.get.ts
          posts.get.ts
          analytics.get.ts
      posts/
        index.get.ts
        index.post.ts
        trending.get.ts
        [id].get.ts
        [id].delete.ts
        [id]/
          likes.get.ts
          likes.post.ts
          likes.delete.ts
          bookmarks.post.ts
          bookmarks.delete.ts
          comments.get.ts
          comments.post.ts
          replies.get.ts
          retweets.get.ts
          retweets.post.ts
          analytics.get.ts
      comments/
        [id].delete.ts
        [id]/
          likes.post.ts
          likes.delete.ts
      media/
        index.post.ts
        [id].delete.ts
      tags/
        index.get.ts
        trending.get.ts
        [name]/
          posts.get.ts
          analytics.get.ts
      notifications/
        index.get.ts
        read-status.put.ts
        [id].delete.ts
        [id]/
          read-status.put.ts
          restore-status.put.ts
  controllers/
  services/
  repositories/
  dto/
  mappers/
  sql/
    oracle/
      auth/
      users/
      relationships/
      posts/
      comments/
      notifications/
      analytics/
  middleware/
  plugins/
  utils/
```

## 6.2 分层职责

- `server/api/v2/**`
  - 只负责取参、调用 controller、返回统一响应
- `server/controllers/**`
  - 负责参数规范化、权限边界、响应 DTO 组装
- `server/services/**`
  - 负责业务流程编排
- `server/repositories/**`
  - 负责 Oracle 访问
- `server/sql/oracle/**`
  - 放 SQL 模板
- `server/dto/**`
  - 定义请求和响应对象
- `server/mappers/**`
  - 负责数据库字段到响应字段的 snake_case 映射

## 7. V2 接口重设计

## 7.1 Auth

### 7.1.1 路由映射

| V1 路径 | V2 路径 | 方法 | 说明 |
| --- | --- | --- | --- |
| `/auth/get-verification` | `/api/v2/auth/otp` | `POST` | 创建 OTP 资源 |
| `/auth/check-verification` | `/api/v2/auth/otp/verification` | `POST` | 校验 OTP |
| `/auth/register` | `/api/v2/auth/registration` | `POST` | 创建注册记录 |
| `/auth/login` | `/api/v2/auth/tokens` | `POST` | 创建 token/session |
| `/auth/logout` | `/api/v2/auth/tokens/current` | `DELETE` | 销毁当前 token |
| `/auth/refresh` | `/api/v2/auth/tokens/current` | `PATCH` | 刷新当前 token |
| `/auth/reset-password` | `/api/v2/auth/password-reset` | `POST` | 创建密码重置任务 |
| `/account/sessions` | `/api/v2/auth/sessions` | `GET` | 获取会话列表 |
| `/account/sessions/{id}` | `/api/v2/auth/sessions/{id}` | `DELETE` | 注销指定会话 |
| `/account/sessions/others` | `/api/v2/auth/sessions/others` | `DELETE` | 注销其他会话 |

### 7.1.2 请求示例

发送验证码：

```json
{
  "account": "demo@example.com",
  "type": "register"
}
```

登录：

```json
{
  "account": "demo@example.com",
  "password": "******",
  "remember_me": true
}
```

### 7.1.3 响应示例

登录成功：

```json
{
  "code": 200,
  "message": "login success",
  "data": {
    "user": {
      "user_id": 1001,
      "email": "demo@example.com",
      "username": "demo",
      "display_name": "Demo",
      "avatar_url": "/upload/avatars/1001/1.png",
      "is_verified": 1
    },
    "tokens": {
      "session_id": "sess_xxx",
      "access_token_expires_at": "2026-04-23T10:00:00Z",
      "refresh_token_expires_at": "2026-05-23T10:00:00Z"
    }
  },
  "meta": null
}
```

### 7.1.4 设计要求

- `OTP` 必须是资源，不再使用 `captcha` 这种命名混搭邮箱验证码。
- 注册、改邮箱、忘记密码都统一通过 OTP 验证链路。
- `access_token` 只存在于 Cookie 或 header，不再原文保存到数据库。
- 数据库只保存：
  - `session_id`
  - `refresh_token_hash`
  - `access_jti`
  - `device_fingerprint`
  - `last_accessed_at`
  - `revoked_at`

## 7.2 Users

### 7.2.1 路由映射

| V1 路径 | V2 路径 | 方法 | 说明 |
| --- | --- | --- | --- |
| `/users/me` | `/api/v2/users/me` | `GET` | 当前用户资料 |
| `/users/me` | `/api/v2/users/me` | `PATCH` | 局部更新资料 |
| `/users/me/avatar` | `/api/v2/users/me/avatar` | `PUT` | 替换头像 |
| `/users/me/email` | `/api/v2/users/me/email` | `PATCH` | 修改邮箱 |
| `/users/{userId}` | `/api/v2/users/{id}` | `GET` | 获取用户公开资料 |
| `/users/search` | `/api/v2/users?q=...` | `GET` | 搜索用户 |
| `/users/suggestions` | `/api/v2/users/recommendations` | `GET` | 推荐用户 |
| `/users/{userId}/stats` | 合并到 `/api/v2/users/{id}` 或 `/api/v2/users/{id}/analytics` | `GET` | 公开资料与分析分离 |
| `/users/{userId}/isfollow` | 合并到 `/api/v2/users/{id}` 的 `relationship` 字段 | `GET` | 不再单独开接口 |

### 7.2.2 用户详情建议返回

```json
{
  "code": 200,
  "message": "success",
  "data": {
    "user_id": 1001,
    "username": "demo",
    "display_name": "Demo",
    "avatar_url": "/upload/avatars/1001/1.png",
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
      "is_blocked": false
    }
  },
  "meta": null
}
```

### 7.2.3 设计要求

- `GET /users/{id}` 返回公开资料。
- `GET /users/me` 返回当前用户完整资料，但仍不返回密码哈希。
- 搜索统一走 query params：
  - `q`
  - `page`
  - `page_size`
  - `sort`
  - `verified`

## 7.3 Relationships

### 7.3.1 路由映射

| V1 路径 | V2 路径 | 方法 | 说明 |
| --- | --- | --- | --- |
| `/follow/action` `follow` | `/api/v2/users/{id}/followers` | `POST` | 关注目标用户 |
| `/follow/action` `unfollow` | `/api/v2/users/{id}/followers` | `DELETE` | 取消关注 |
| `/follow/{id}/followers` | `/api/v2/users/{id}/followers` | `GET` | 粉丝列表 |
| `/follow/{id}/following` | `/api/v2/users/{id}/following` | `GET` | 关注列表 |
| `/follow/{id}/mutual-follows` | `/api/v2/users/{id}/mutual-following` | `GET` | 共同关注 |
| `/follow/blocked` | `/api/v2/users/me/blocks` | `GET` | 我的屏蔽列表 |
| `/follow/action` `block` | `/api/v2/users/me/blocks/{targetId}` | `POST` | 屏蔽用户 |
| `/follow/action` `unblock` | `/api/v2/users/me/blocks/{targetId}` | `DELETE` | 取消屏蔽 |

### 7.3.2 设计要求

- follow 不再通过 `action` 字段复用。
- block 不再和 follow 混表。
- future mute 也应单独资源化为 `/users/me/mutes/{target_id}`。

## 7.4 Posts

### 7.4.1 路由映射

| V1 路径 | V2 路径 | 方法 | 说明 |
| --- | --- | --- | --- |
| `/tweets/send-tweets` | `/api/v2/posts` | `POST` | 创建帖子 |
| `/tweets/{id}` | `/api/v2/posts/{id}` | `GET` | 帖子详情 |
| `/tweets/{id}` | `/api/v2/posts/{id}` | `DELETE` | 删除帖子 |
| `/tweets/list?type=home` | `/api/v2/posts?timeline=home` | `GET` | 首页时间线 |
| `/tweets/list?type=mention` | `/api/v2/posts?timeline=mentions` | `GET` | 提及我的帖子 |
| `/tweets/list?type=user&userId=` | `/api/v2/users/{id}/posts` | `GET` | 用户帖子列表 |
| `/tweets/list?type=my_tweets` | `/api/v2/users/me/posts` | `GET` | 我的帖子列表 |
| `/tweets/list?type=bookmark` | `/api/v2/users/me/bookmarks` | `GET` | 我的收藏帖子 |
| `/tweets/list?type=trending` | `/api/v2/posts/trending` | `GET` | 热门帖子 |
| `/tweets/search` | `/api/v2/posts?q=...` | `GET` | 搜索帖子 |
| `/tweets/[tweetId]/replies` | `/api/v2/posts/{id}/replies` | `GET` | 回复流 |
| `/tweets/[tweetId]/retweets` | `/api/v2/posts/{id}/retweets` | `GET` | 转发列表 |

### 7.4.2 发帖请求示例

```json
{
  "content": "hello world",
  "visibility": "public",
  "media_ids": [501, 502],
  "tag_names": ["oracle", "nuxt"],
  "mention_user_ids": [1002, 1003],
  "reply_to_post_id": null,
  "repost_of_post_id": null,
  "quoted_post_id": null,
  "location": "Shanghai"
}
```

### 7.4.3 设计要求

- `tweets` 全部统一更名为 `posts`。
- 媒体必须先上传再发帖。
- `timeline` 只作为 GET 列表过滤条件，不允许再把搜索条件放在 body。

## 7.5 Media

### 7.5.1 路由映射

| V1 路径 | V2 路径 | 方法 | 说明 |
| --- | --- | --- | --- |
| `/tweets/media/upload` | `/api/v2/media` | `POST` | 上传独立媒体资源 |
| `/tweets/media/{tweetId}/{mediaId}` | `/api/v2/media/{id}` | `DELETE` | 删除媒体资源 |

### 7.5.2 设计要求

- 媒体与帖子解耦。
- 上传成功后返回 `media_id`。
- 发帖时通过 `media_ids` 关联。
- 头像也建议最终复用统一媒体表，只是在用户表用 `avatar_media_id` 指向。

## 7.6 Interactions

### 7.6.1 路由映射

| V1 路径 | V2 路径 | 方法 | 说明 |
| --- | --- | --- | --- |
| `/interactions/like` | `/api/v2/posts/{id}/likes` | `POST/DELETE` | 帖子点赞 |
| 当前评论点赞复用 like | `/api/v2/comments/{id}/likes` | `POST/DELETE` | 评论点赞 |
| `/interactions/bookmark` | `/api/v2/posts/{id}/bookmarks` | `POST/DELETE` | 收藏 |
| `/interactions/comment` | `/api/v2/posts/{id}/comments` | `POST` | 新评论 |
| `/interactions/comments/{id}` | `/api/v2/comments/{id}` | `DELETE` | 删除评论 |
| `/tweets/{id}/comments` | `/api/v2/posts/{id}/comments` | `GET` | 评论列表 |
| 转发通过发帖接口实现 | `/api/v2/posts/{id}/retweets` | `POST` | 创建转发关系 |

### 7.6.2 设计要求

- 帖子点赞和评论点赞必须拆表。
- 不再允许 `like_type = likeComment` 这种混合语义。
- 评论删除后仍建议软删除，并保留 `deleted_at`。

## 7.7 Tags & Discovery

### 7.7.1 路由映射

| V1 路径 | V2 路径 | 方法 | 说明 |
| --- | --- | --- | --- |
| `/hashtags/search` | `/api/v2/tags?q=...` | `GET` | 搜索话题 |
| `/hashtags/trending` | `/api/v2/tags/trending` | `GET` | 热门话题 |
| `/hashtags/{tag}/tweets` | `/api/v2/tags/{name}/posts` | `GET` | 话题下帖子 |
| `/hashtags/stats` | `/api/v2/tags/{name}/analytics` | `GET` | 话题统计 |
| `/recommendations/feedback` | `/api/v2/recommendations/feedback` | `POST` | 推荐反馈，可保留 |

### 7.7.2 设计要求

- 路径参数必须是 tag name，不再混用 tag id。
- 如果未来需要按 id 查询，则单独提供 `/tags/{id}` 或内部解析。
- 统计类必须走分析视图或物化视图，不直接扫大表。

## 7.8 Notifications & Analytics

### 7.8.1 路由映射

| V1 路径 | V2 路径 | 方法 | 说明 |
| --- | --- | --- | --- |
| `/notifications/list` | `/api/v2/notifications` | `GET` | 通知列表 |
| `/notifications/{id}` `PUT` | `/api/v2/notifications/{id}/read-status` | `PUT` | 单条已读 |
| `/notifications/read-all` | `/api/v2/notifications/read-status` | `PUT` | 全部已读 |
| `/notifications/{id}` `DELETE` | `/api/v2/notifications/{id}` | `DELETE` | 软删除 |
| `/notifications/{id}/restore` | `/api/v2/notifications/{id}/restore-status` | `PUT` | 恢复 |
| `/analytics/users/{id}/stats` | `/api/v2/users/{id}/analytics` | `GET` | 用户分析 |
| `/analytics/tweets/{id}/stats` | `/api/v2/posts/{id}/analytics` | `GET` | 帖子分析 |

### 7.8.2 设计要求

- 通知发送接口建议转内部或管理端接口，不建议暴露给普通客户端。
- 通知偏好设置拆到独立表。
- `analytics` 返回聚合结果，不做通用对象详情返回。

## 7.9 Account Domain 补充

当前仓库里 `account` 有三类能力：

- settings
- sessions
- statements

V2 建议：

- `settings` 并入 `/users/me/settings`
- `sessions` 并入 `/auth/sessions`
- `statements` 并入 `/users/me/account-statements`

原因：

- settings 是用户资源属性
- sessions 属于认证域
- statements 是账户治理资源

## 7.10 WebSocket 与群组的兼容说明

### WebSocket

- `server/routes/_ws.ts` 不需要纳入 `/api/v2` 路径版本控制。
- 但消息体建议同步改为 snake_case，例如：
  - `join_room` 保留
  - `session_id`
  - `room_id`
  - `message_type`

### 群组

`data/oracle-init/**` 中已经存在群组相关表、视图、函数和过程。群组暂不属于本次主线改造范围，但建议后续遵循相同规范：

- `/api/v2/groups`
- `/api/v2/groups/{id}`
- `/api/v2/groups/{id}/members`
- `/api/v2/groups/{id}/posts`
- `/api/v2/groups/{id}/invites`

## 8. Oracle 表结构重设计

## 8.1 重构原则

- 把“身份数据”和“统计数据”拆开。
- 把“关系类型混装表”拆开。
- 把“帖子”和“媒体”解耦。
- 把“帖子点赞”和“评论点赞”拆表。
- 把“文件存储能力”迁移到 Oracle 正式表。
- 把“统计/趋势”从事务表里抽到读模型。

## 8.2 现有表到 V2 表映射

| 当前对象 | V2 对象 | 说明 |
| --- | --- | --- |
| `n_users` | `n_users` + `n_user_stats` | 用户基础信息与统计拆分 |
| `n_user_sessions` | `n_auth_sessions` | 会话安全重做 |
| Redis 验证码 | `n_auth_otp_events` 可选 | 审计和流程追踪 |
| `n_follows` | `n_user_follows` + `n_user_blocks` + `n_user_mutes` | 关系拆表 |
| `n_tweets` | `n_posts` | 统一 posts 语义 |
| 计数字段在 `n_tweets` | `n_post_stats` | 统计拆分 |
| `n_media` | `n_media_assets` + `n_post_media` | 媒体资源中心 |
| `n_likes` | `n_post_likes` + `n_comment_likes` | 点赞拆表 |
| `n_bookmarks` | `n_post_bookmarks` | 收藏独立 |
| `n_comments` | `n_comments` + `n_comment_stats` | 评论与统计拆分 |
| `n_hashtags` | `n_tags` | 名称统一 |
| `n_tweet_hashtags` | `n_post_tags` | 跟 posts 保持一致 |
| `n_tweet_mentions` | `n_post_mentions` | 跟 posts 保持一致 |
| `n_notifications` | `n_notifications` + `n_notification_preferences` | 主表与偏好拆分 |
| JSON 设置 | `n_user_settings` | 替换文件存储 |
| JSON statements | `n_account_statements` + `n_statement_appeals` | 替换文件存储 |

## 8.3 推荐 DDL 草案

以下 DDL 是 V2 推荐结构草案，便于后续分文件落地。

### 8.3.1 用户基础表

```sql
CREATE TABLE n_users (
    user_id NUMBER(10) PRIMARY KEY,
    email VARCHAR2(100) NOT NULL,
    username VARCHAR2(50) NOT NULL,
    password_hash VARCHAR2(255) NOT NULL,
    display_name VARCHAR2(100),
    bio VARCHAR2(500),
    location VARCHAR2(100),
    website VARCHAR2(200),
    birth_date DATE,
    phone VARCHAR2(20),
    avatar_media_id NUMBER(15),
    email_verified_at TIMESTAMP,
    is_verified NUMBER(1) DEFAULT 0 CHECK (is_verified IN (0, 1)),
    status VARCHAR2(20) DEFAULT 'active' CHECK (status IN ('active', 'disabled', 'suspended', 'pending')),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_login_at TIMESTAMP,
    created_by VARCHAR2(50) DEFAULT USER,
    updated_by VARCHAR2(50) DEFAULT USER,
    CONSTRAINT uk_users_email UNIQUE (email),
    CONSTRAINT uk_users_username UNIQUE (username)
);
```

### 8.3.2 用户统计表

```sql
CREATE TABLE n_user_stats (
    user_id NUMBER(10) PRIMARY KEY,
    followers_count NUMBER(10) DEFAULT 0,
    following_count NUMBER(10) DEFAULT 0,
    posts_count NUMBER(10) DEFAULT 0,
    likes_count NUMBER(10) DEFAULT 0,
    bookmarks_count NUMBER(10) DEFAULT 0,
    comments_count NUMBER(10) DEFAULT 0,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_user_stats_user FOREIGN KEY (user_id) REFERENCES n_users(user_id)
);
```

### 8.3.3 OTP 事件表

```sql
CREATE TABLE n_auth_otp_events (
    otp_event_id NUMBER(15) PRIMARY KEY,
    account VARCHAR2(100) NOT NULL,
    otp_type VARCHAR2(30) NOT NULL CHECK (otp_type IN ('register', 'password_reset', 'change_email')),
    verification_code_hash VARCHAR2(255) NOT NULL,
    send_channel VARCHAR2(20) DEFAULT 'email',
    verification_id VARCHAR2(128),
    expires_at TIMESTAMP NOT NULL,
    verified_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

### 8.3.4 会话表

```sql
CREATE TABLE n_auth_sessions (
    session_id VARCHAR2(128) PRIMARY KEY,
    user_id NUMBER(10) NOT NULL,
    access_jti VARCHAR2(128) NOT NULL,
    refresh_token_hash VARCHAR2(255) NOT NULL,
    device_info VARCHAR2(500),
    device_fingerprint VARCHAR2(255),
    ip_address VARCHAR2(45),
    user_agent CLOB,
    access_token_expires_at TIMESTAMP NOT NULL,
    refresh_token_expires_at TIMESTAMP NOT NULL,
    last_accessed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_refresh_at TIMESTAMP,
    revoked_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_auth_sessions_user FOREIGN KEY (user_id) REFERENCES n_users(user_id)
);
```

### 8.3.5 关注关系表

```sql
CREATE TABLE n_user_follows (
    follow_id NUMBER(15) PRIMARY KEY,
    follower_id NUMBER(10) NOT NULL,
    following_id NUMBER(10) NOT NULL,
    status VARCHAR2(20) DEFAULT 'active' CHECK (status IN ('active', 'cancelled')),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_user_follows_follower FOREIGN KEY (follower_id) REFERENCES n_users(user_id),
    CONSTRAINT fk_user_follows_following FOREIGN KEY (following_id) REFERENCES n_users(user_id),
    CONSTRAINT uk_user_follows UNIQUE (follower_id, following_id),
    CONSTRAINT ck_user_follows_not_self CHECK (follower_id != following_id)
);
```

### 8.3.6 屏蔽关系表

```sql
CREATE TABLE n_user_blocks (
    block_id NUMBER(15) PRIMARY KEY,
    user_id NUMBER(10) NOT NULL,
    target_user_id NUMBER(10) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_user_blocks_user FOREIGN KEY (user_id) REFERENCES n_users(user_id),
    CONSTRAINT fk_user_blocks_target FOREIGN KEY (target_user_id) REFERENCES n_users(user_id),
    CONSTRAINT uk_user_blocks UNIQUE (user_id, target_user_id),
    CONSTRAINT ck_user_blocks_not_self CHECK (user_id != target_user_id)
);
```

### 8.3.7 帖子主表

```sql
CREATE TABLE n_posts (
    post_id NUMBER(15) PRIMARY KEY,
    author_id NUMBER(10) NOT NULL,
    content CLOB,
    post_type VARCHAR2(20) DEFAULT 'post' CHECK (post_type IN ('post', 'reply', 'repost', 'quote')),
    reply_to_post_id NUMBER(15),
    repost_of_post_id NUMBER(15),
    quoted_post_id NUMBER(15),
    visibility VARCHAR2(20) DEFAULT 'public' CHECK (visibility IN ('public', 'followers', 'mentioned', 'private')),
    language VARCHAR2(10) DEFAULT 'zh',
    location VARCHAR2(100),
    deleted_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_posts_author FOREIGN KEY (author_id) REFERENCES n_users(user_id),
    CONSTRAINT fk_posts_reply FOREIGN KEY (reply_to_post_id) REFERENCES n_posts(post_id),
    CONSTRAINT fk_posts_repost FOREIGN KEY (repost_of_post_id) REFERENCES n_posts(post_id),
    CONSTRAINT fk_posts_quote FOREIGN KEY (quoted_post_id) REFERENCES n_posts(post_id)
);
```

### 8.3.8 帖子统计表

```sql
CREATE TABLE n_post_stats (
    post_id NUMBER(15) PRIMARY KEY,
    likes_count NUMBER(10) DEFAULT 0,
    comments_count NUMBER(10) DEFAULT 0,
    retweets_count NUMBER(10) DEFAULT 0,
    views_count NUMBER(15) DEFAULT 0,
    engagement_score NUMBER(10, 2) DEFAULT 0,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_post_stats_post FOREIGN KEY (post_id) REFERENCES n_posts(post_id)
);
```

### 8.3.9 媒体资源表

```sql
CREATE TABLE n_media_assets (
    media_id NUMBER(15) PRIMARY KEY,
    owner_user_id NUMBER(10) NOT NULL,
    media_type VARCHAR2(20) NOT NULL CHECK (media_type IN ('image', 'video', 'audio', 'gif')),
    file_name VARCHAR2(255) NOT NULL,
    storage_key VARCHAR2(500) NOT NULL,
    public_url VARCHAR2(500) NOT NULL,
    file_size NUMBER(15) NOT NULL,
    mime_type VARCHAR2(100) NOT NULL,
    width NUMBER(6),
    height NUMBER(6),
    duration NUMBER(10),
    thumbnail_url VARCHAR2(500),
    alt_text VARCHAR2(500),
    status VARCHAR2(20) DEFAULT 'ready' CHECK (status IN ('uploaded', 'processing', 'ready', 'failed')),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_media_assets_owner FOREIGN KEY (owner_user_id) REFERENCES n_users(user_id)
);
```

### 8.3.10 帖子媒体关联表

```sql
CREATE TABLE n_post_media (
    post_id NUMBER(15) NOT NULL,
    media_id NUMBER(15) NOT NULL,
    sort_order NUMBER(5) DEFAULT 1,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (post_id, media_id),
    CONSTRAINT fk_post_media_post FOREIGN KEY (post_id) REFERENCES n_posts(post_id),
    CONSTRAINT fk_post_media_media FOREIGN KEY (media_id) REFERENCES n_media_assets(media_id)
);
```

### 8.3.11 帖子点赞表

```sql
CREATE TABLE n_post_likes (
    post_like_id NUMBER(15) PRIMARY KEY,
    post_id NUMBER(15) NOT NULL,
    user_id NUMBER(10) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_post_likes_post FOREIGN KEY (post_id) REFERENCES n_posts(post_id),
    CONSTRAINT fk_post_likes_user FOREIGN KEY (user_id) REFERENCES n_users(user_id),
    CONSTRAINT uk_post_likes UNIQUE (post_id, user_id)
);
```

### 8.3.12 帖子收藏表

```sql
CREATE TABLE n_post_bookmarks (
    bookmark_id NUMBER(15) PRIMARY KEY,
    post_id NUMBER(15) NOT NULL,
    user_id NUMBER(10) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_post_bookmarks_post FOREIGN KEY (post_id) REFERENCES n_posts(post_id),
    CONSTRAINT fk_post_bookmarks_user FOREIGN KEY (user_id) REFERENCES n_users(user_id),
    CONSTRAINT uk_post_bookmarks UNIQUE (post_id, user_id)
);
```

### 8.3.13 评论主表

```sql
CREATE TABLE n_comments (
    comment_id NUMBER(15) PRIMARY KEY,
    post_id NUMBER(15) NOT NULL,
    user_id NUMBER(10) NOT NULL,
    parent_comment_id NUMBER(15),
    root_comment_id NUMBER(15),
    content CLOB NOT NULL,
    deleted_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_comments_post FOREIGN KEY (post_id) REFERENCES n_posts(post_id),
    CONSTRAINT fk_comments_user FOREIGN KEY (user_id) REFERENCES n_users(user_id),
    CONSTRAINT fk_comments_parent FOREIGN KEY (parent_comment_id) REFERENCES n_comments(comment_id)
);
```

### 8.3.14 评论统计表

```sql
CREATE TABLE n_comment_stats (
    comment_id NUMBER(15) PRIMARY KEY,
    likes_count NUMBER(10) DEFAULT 0,
    replies_count NUMBER(10) DEFAULT 0,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_comment_stats_comment FOREIGN KEY (comment_id) REFERENCES n_comments(comment_id)
);
```

### 8.3.15 评论点赞表

```sql
CREATE TABLE n_comment_likes (
    comment_like_id NUMBER(15) PRIMARY KEY,
    comment_id NUMBER(15) NOT NULL,
    user_id NUMBER(10) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_comment_likes_comment FOREIGN KEY (comment_id) REFERENCES n_comments(comment_id),
    CONSTRAINT fk_comment_likes_user FOREIGN KEY (user_id) REFERENCES n_users(user_id),
    CONSTRAINT uk_comment_likes UNIQUE (comment_id, user_id)
);
```

### 8.3.16 话题表

```sql
CREATE TABLE n_tags (
    tag_id NUMBER(10) PRIMARY KEY,
    name VARCHAR2(100) NOT NULL,
    name_lower VARCHAR2(100) NOT NULL,
    usage_count NUMBER(15) DEFAULT 0,
    trending_score NUMBER(10, 2) DEFAULT 0,
    is_trending NUMBER(1) DEFAULT 0 CHECK (is_trending IN (0, 1)),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_tags_name_lower UNIQUE (name_lower)
);
```

### 8.3.17 帖子标签关联表

```sql
CREATE TABLE n_post_tags (
    post_id NUMBER(15) NOT NULL,
    tag_id NUMBER(10) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (post_id, tag_id),
    CONSTRAINT fk_post_tags_post FOREIGN KEY (post_id) REFERENCES n_posts(post_id),
    CONSTRAINT fk_post_tags_tag FOREIGN KEY (tag_id) REFERENCES n_tags(tag_id)
);
```

### 8.3.18 帖子提及关联表

```sql
CREATE TABLE n_post_mentions (
    post_id NUMBER(15) NOT NULL,
    mentioned_user_id NUMBER(10) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (post_id, mentioned_user_id),
    CONSTRAINT fk_post_mentions_post FOREIGN KEY (post_id) REFERENCES n_posts(post_id),
    CONSTRAINT fk_post_mentions_user FOREIGN KEY (mentioned_user_id) REFERENCES n_users(user_id)
);
```

### 8.3.19 通知主表

```sql
CREATE TABLE n_notifications (
    notification_id NUMBER(15) PRIMARY KEY,
    user_id NUMBER(10) NOT NULL,
    actor_id NUMBER(10),
    action_type VARCHAR2(30) NOT NULL,
    resource_type VARCHAR2(30),
    resource_id NUMBER(15),
    title VARCHAR2(200),
    message VARCHAR2(1000),
    priority VARCHAR2(10) DEFAULT 'normal' CHECK (priority IN ('low', 'normal', 'high', 'urgent')),
    read_at TIMESTAMP,
    deleted_at TIMESTAMP,
    metadata_json CLOB,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_notifications_user FOREIGN KEY (user_id) REFERENCES n_users(user_id)
);
```

### 8.3.20 通知偏好表

```sql
CREATE TABLE n_notification_preferences (
    user_id NUMBER(10) NOT NULL,
    notification_type VARCHAR2(30) NOT NULL,
    is_enabled NUMBER(1) DEFAULT 1 CHECK (is_enabled IN (0, 1)),
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, notification_type),
    CONSTRAINT fk_notification_preferences_user FOREIGN KEY (user_id) REFERENCES n_users(user_id)
);
```

### 8.3.21 用户设置表

```sql
CREATE TABLE n_user_settings (
    user_id NUMBER(10) PRIMARY KEY,
    two_factor_enabled NUMBER(1) DEFAULT 0 CHECK (two_factor_enabled IN (0, 1)),
    login_alerts NUMBER(1) DEFAULT 1 CHECK (login_alerts IN (0, 1)),
    profile_visibility VARCHAR2(20) DEFAULT 'public' CHECK (profile_visibility IN ('public', 'private')),
    show_online_status NUMBER(1) DEFAULT 1 CHECK (show_online_status IN (0, 1)),
    allow_dm_from_strangers NUMBER(1) DEFAULT 0 CHECK (allow_dm_from_strangers IN (0, 1)),
    push_notification_enabled NUMBER(1) DEFAULT 1 CHECK (push_notification_enabled IN (0, 1)),
    email_notification_enabled NUMBER(1) DEFAULT 1 CHECK (email_notification_enabled IN (0, 1)),
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_user_settings_user FOREIGN KEY (user_id) REFERENCES n_users(user_id)
);
```

### 8.3.22 账户状态表

```sql
CREATE TABLE n_account_statements (
    statement_id NUMBER(15) PRIMARY KEY,
    user_id NUMBER(10) NOT NULL,
    statement_type VARCHAR2(20) NOT NULL CHECK (statement_type IN ('info', 'warning', 'strike', 'suspension')),
    title VARCHAR2(200) NOT NULL,
    message VARCHAR2(1000) NOT NULL,
    policy_code VARCHAR2(50),
    status VARCHAR2(20) DEFAULT 'unread' CHECK (status IN ('unread', 'read', 'resolved', 'dismissed', 'appealed')),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_account_statements_user FOREIGN KEY (user_id) REFERENCES n_users(user_id)
);
```

### 8.3.23 申诉表

```sql
CREATE TABLE n_statement_appeals (
    appeal_id NUMBER(15) PRIMARY KEY,
    statement_id NUMBER(15) NOT NULL,
    user_id NUMBER(10) NOT NULL,
    appeal_message VARCHAR2(2000) NOT NULL,
    appeal_status VARCHAR2(20) DEFAULT 'pending' CHECK (appeal_status IN ('pending', 'approved', 'rejected')),
    admin_response VARCHAR2(2000),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_statement_appeals_statement FOREIGN KEY (statement_id) REFERENCES n_account_statements(statement_id),
    CONSTRAINT fk_statement_appeals_user FOREIGN KEY (user_id) REFERENCES n_users(user_id)
);
```

## 8.4 推荐索引

重点索引建议：

- `n_users(email)`
- `n_users(username)`
- `n_auth_sessions(user_id, revoked_at, refresh_token_expires_at)`
- `n_user_follows(following_id, status, created_at desc)`
- `n_user_follows(follower_id, status, created_at desc)`
- `n_user_blocks(user_id, created_at desc)`
- `n_posts(author_id, created_at desc)`
- `n_posts(reply_to_post_id, created_at desc)`
- `n_posts(repost_of_post_id, created_at desc)`
- `n_post_likes(post_id, created_at desc)`
- `n_post_bookmarks(user_id, created_at desc)`
- `n_comments(post_id, created_at desc)`
- `n_comment_likes(comment_id, created_at desc)`
- `n_tags(name_lower)`
- `n_notifications(user_id, deleted_at, read_at, created_at desc)`

## 9. 查询、视图与物化视图设计

## 9.1 原则

- 事务性 CRUD 不依赖“大一统存储过程”。
- 能写普通 SQL 的地方尽量不要再写复用 action 过程。
- 只把复杂统计、定时汇总、批处理放到 PL/SQL 或物化视图。

## 9.2 建议保留的小函数

- `fn_get_user_relationship`
  - V2 可以保留，但只负责返回 viewer 与 target 的关系
- `fn_can_view_post`
  - 由 `fn_can_view_tweet` 重命名而来
- `fn_calculate_post_engagement`
  - 只负责热度计算

## 9.3 建议淘汰或重写的大过程

以下过程不再建议继续沿用目前的“万能 action”模式：

- `sp_manage_follow`
- `sp_manage_like`
- `sp_manage_mark`
- `sp_manage_commons`

改造原则：

- 跟单一资源强绑定的增删改，用明确 SQL 和 service 编排。
- 保留下面这类适合批处理/后台作业的过程：
  - 趋势计算
  - 批量通知
  - 清理任务

## 9.4 推荐读模型视图

### 推荐视图

- `v_user_profile_public`
  - 用户公开资料
- `v_post_detail`
  - 单贴详情
- `v_post_comment_list_item`
  - 评论列表扁平视图
- `v_notification_list_item`
  - 通知列表项

### 推荐物化视图

- `mv_post_engagement_daily`
- `mv_user_analytics_daily`
- `mv_tag_analytics_daily`
- `mv_tag_trends_hourly`

## 9.5 典型 SQL 示例

### 主页时间线

```sql
SELECT
    p.post_id,
    p.author_id,
    u.username,
    u.display_name,
    u.avatar_url,
    p.content,
    p.visibility,
    p.post_type,
    p.reply_to_post_id,
    p.repost_of_post_id,
    p.quoted_post_id,
    ps.likes_count,
    ps.comments_count,
    ps.retweets_count,
    ps.views_count,
    ps.engagement_score,
    p.created_at
FROM n_posts p
JOIN n_users u ON u.user_id = p.author_id
LEFT JOIN n_post_stats ps ON ps.post_id = p.post_id
WHERE p.deleted_at IS NULL
  AND (
      p.author_id = :viewer_id
      OR EXISTS (
          SELECT 1
          FROM n_user_follows f
          WHERE f.follower_id = :viewer_id
            AND f.following_id = p.author_id
            AND f.status = 'active'
      )
  )
  AND fn_can_view_post(:viewer_id, p.post_id) = 1
ORDER BY p.created_at DESC
OFFSET :offset ROWS FETCH NEXT :page_size ROWS ONLY;
```

### 用户粉丝列表

```sql
SELECT
    u.user_id,
    u.username,
    u.display_name,
    u.avatar_url,
    f.created_at
FROM n_user_follows f
JOIN n_users u ON u.user_id = f.follower_id
WHERE f.following_id = :target_user_id
  AND f.status = 'active'
ORDER BY f.created_at DESC
OFFSET :offset ROWS FETCH NEXT :page_size ROWS ONLY;
```

### 帖子详情

```sql
SELECT
    p.post_id,
    p.author_id,
    u.username,
    u.display_name,
    u.avatar_url,
    p.content,
    p.visibility,
    p.post_type,
    p.reply_to_post_id,
    p.repost_of_post_id,
    p.quoted_post_id,
    ps.likes_count,
    ps.comments_count,
    ps.retweets_count,
    ps.views_count,
    p.created_at
FROM n_posts p
JOIN n_users u ON u.user_id = p.author_id
LEFT JOIN n_post_stats ps ON ps.post_id = p.post_id
WHERE p.post_id = :post_id
  AND p.deleted_at IS NULL;
```

### 话题分析

```sql
SELECT *
FROM mv_tag_analytics_daily
WHERE tag_name_lower = LOWER(:tag_name)
ORDER BY stat_date DESC;
```

## 10. 对现有文件的具体改造指引

本节不是最终分文件施工清单，只是先把现有文件该怎么改说清楚。

### 10.1 中间件与插件

- `server/middleware/auth.ts`
  - 放行路径从 `/api/v1/auth/**` 扩展为按版本配置。
  - 不再依赖数据库里保存 access token 原文。
- `server/middleware/rate-limit.ts`
  - 可以保留，但建议将 key 细分为 `ip + route_group`。
- `server/plugins/02-oracle.ts`
  - 保留惰性连接池模式。
- `server/plugins/01-redisClient.ts`
  - 保留惰性 Redis。

### 10.2 Auth 目录

- 删除动作式命名文件。
- `login.post.ts` 改为 `tokens.post.ts`。
- `logout.get.ts` 改为 `tokens/current.delete.ts`。
- `refresh.get.ts` 改为 `tokens/current.patch.ts`。
- 登录/刷新/登出全部切换到 session model。

### 10.3 Users 目录

- `me.put.ts` 改为 `me.patch.ts`。
- `me/avatar.post.ts` 改为 `me/avatar.put.ts`。
- `search.get.ts` 合并为 `index.get.ts`，通过 `q` 判断是否搜索。
- `suggestions.get.ts` 改为 `recommendations.get.ts`。
- `isfollow.get.ts` 并入用户详情响应，不再保留单独路由。

### 10.4 Follow 目录

- 整个 `follow` 模块拆散，迁移到 `users/{id}/followers`、`users/{id}/following`、`users/me/blocks`。
- 原 `action.post.ts` 不保留。
- follower/following 方向的 SQL 重新梳理，避免 join 反向。

### 10.5 Tweets 目录

- `tweets` 整体迁移到 `posts`。
- `list.get.ts` 拆成多个更清晰的列表入口。
- `search.post.ts` 改成真正的 `GET` 搜索接口。
- `media/upload.post.ts` 改为独立 `media` 目录。

### 10.6 Interactions 目录

- 点赞和收藏不再走 action body。
- 评论点赞拆出 `comments/{id}/likes`。
- 删除评论保留 `/comments/{id}`。

### 10.7 Hashtags 目录

- `hashtags` 改名为 `tags`。
- `[tag]/tweets.get.ts` 彻底重写，修复：
  - 参数语义混乱
  - 硬编码用户 ID
  - tag/id 混用

### 10.8 Notifications 目录

- `list.get.ts` 改为 `index.get.ts`
- `[notificationId].put.ts` 改为 `[id]/read-status.put.ts`
- `read-all.put.ts` 改为 `read-status.put.ts`
- `send.post.ts` 和 `batch-send.post.ts` 建议转内部管理端接口

### 10.9 Account 目录

- `settings` 改到 `users/me/settings`
- `sessions` 改到 `auth/sessions`
- `statements` 改到 `users/me/account-statements`
- 本地 JSON store 全部迁到 Oracle

### 10.10 SQL 目录

当前没有专门的 SQL 目录，V2 必须新增：

```text
server/sql/oracle/
  auth/
  users/
  relationships/
  posts/
  comments/
  media/
  tags/
  notifications/
  analytics/
```

每个模块至少拆成：

- `queries.sql.ts` 或 `*.sql.ts`
- `mapper.ts`
- `repository.ts`

## 11. 推荐迁移顺序

### Phase 1

- 建立统一响应工具
- 建立 `server/api/v2` 基础目录
- 中间件支持 `v2`

### Phase 2

- 重做 auth：
  - OTP
  - session
  - token refresh

### Phase 3

- 重做关系模型：
  - follows
  - blocks
  - mute 可选

### Phase 4

- `tweets -> posts`
- `hashtags -> tags`
- `media -> media_assets + post_media`

### Phase 5

- `likes/bookmarks/comments` 拆表和改路由
- 删除旧 action 接口

### Phase 6

- 迁移 `account/settings`
- 迁移 `account/sessions`
- 迁移 `account/statements`

### Phase 7

- 统计视图重建
- 修复 analytics 接口
- 补充物化视图和定时任务

### Phase 8

- V1 标记废弃
- 逐步删掉 V1 路由

## 12. V1 到 V2 的兼容策略

建议短期采用双版本并行：

- V1 继续保留用于旧前端联调
- V2 新建平行目录，不直接覆盖旧路由
- 在响应头里给 V1 增加废弃提示
- 等前端全部切到 V2 后，再下线 V1

推荐兼容期策略：

- 第一阶段只做 V2 新增，不删除 V1
- 第二阶段让前端切到 V2
- 第三阶段删除 V1 和文件存储逻辑

## 13. 风险与注意事项

- `n_user_sessions` 改造为 `n_auth_sessions` 时需要迁移 Cookie 刷新逻辑。
- 评论点赞拆表后，所有现有关于 `n_likes` 的触发器都要重写。
- `v_comprehensive_timeline` 不应继续作为所有列表的统一入口。
- 媒体表拆分后，删除媒体的物理文件逻辑也要跟着调整。
- 统计表拆分后，原有触发器里直接写 `n_tweets.likes_count` 的逻辑要迁移到 `n_post_stats`。
- 群组 SQL 依赖 `n_users`，所以用户主表改造时要保持主键兼容。

## 14. 本文档结论

本次 V2 重构核心结论如下：

- 路径统一资源化，全部进入 `/api/v2`
- 响应统一为 `code/message/data/meta`
- `tweets` 全面升级为 `posts`
- `hashtags` 全面升级为 `tags`
- `follow/block/mute` 从混装表拆开
- `post likes` 和 `comment likes` 拆表
- `media` 独立资源化
- `settings/sessions/statements` 从本地 JSON 存储迁入 Oracle
- 控制层、服务层、仓储层、SQL 分层
- 统计类改为视图和物化视图，避免事务表承压

## 15. 下一步输出建议

下一条建议直接继续输出“按当前仓库结构拆好的 Router / Controller / SQL / 表迁移清单”，并按以下粒度展开：

- `server/api/v2/**` 每个路由文件该创建什么
- `server/controllers/**` 每个控制器负责什么
- `server/services/**` 每个服务负责什么
- `server/repositories/**` 每个仓储负责什么
- Oracle DDL 按文件拆成哪些脚本
- 旧文件对应迁移去向

这样你就可以按文件一批一批改，而不是一次性大爆改。
