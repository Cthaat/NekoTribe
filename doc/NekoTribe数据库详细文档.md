# Twitter克隆系统数据库设计文档

## 概述

本文档详细描述了基于Oracle 19c+的Twitter克隆系统数据库设计方案。该数据库系统支持完整的社交媒体功能，包括用户管理、推文发布、社交关系、媒体处理、话题标签等核心功能。

**设计特点：**
- 采用Oracle序列自动生成主键ID
- 使用专用表空间`twitter_data`提高性能
- 完善的外键约束和检查约束保证数据完整性
- 支持软删除机制，保留数据历史
- 内置审计字段，便于追踪数据变更

---

## 数据库序列

系统使用4个Oracle序列来自动生成主键ID，避免ID冲突并提高插入性能：

| 序列名 | 起始值 | 步长 | 缓存大小 | 用途 |
|--------|--------|------|----------|------|
| `seq_user_id` | 1000 | 1 | 20 | 用户ID生成 |
| `seq_tweet_id` | 10000 | 1 | 50 | 推文ID生成 |
| `seq_comment_id` | 100000 | 1 | 100 | 评论ID生成 |
| `seq_media_id` | 1000000 | 1 | 20 | 媒体文件ID生成 |

**使用方式：**
```sql
-- 获取下一个用户ID
SELECT seq_user_id.NEXTVAL FROM DUAL;

-- 插入时使用序列
INSERT INTO t_users (user_id, email, username, password_hash) 
VALUES (seq_user_id.NEXTVAL, 'user@example.com', 'username', 'hash');
```

---

## 数据表结构详解

### 1. 用户表 (t_users)

**表功能：** 存储所有注册用户的基本信息和统计数据

**必填字段：**
- `email` - 用户邮箱（唯一）
- `username` - 用户名（唯一）
- `password_hash` - 密码哈希值

**字段详解：**

| 字段名 | 数据类型 | 约束 | 默认值 | 说明 |
|--------|----------|------|--------|------|
| user_id | NUMBER(10) | PK | 序列生成 | 用户唯一标识符 |
| email | VARCHAR2(100) | NOT NULL, UNIQUE | - | 登录邮箱 |
| username | VARCHAR2(50) | NOT NULL, UNIQUE | - | 用户名（@提及用） |
| password_hash | VARCHAR2(255) | NOT NULL | - | bcrypt加密的密码 |
| avatar_url | VARCHAR2(500) | - | '/default-avatar.png' | 头像URL |
| display_name | VARCHAR2(100) | - | NULL | 显示名称 |
| bio | VARCHAR2(500) | - | NULL | 个人简介 |
| location | VARCHAR2(100) | - | NULL | 地理位置 |
| website | VARCHAR2(200) | - | NULL | 个人网站 |
| birth_date | DATE | - | NULL | 出生日期 |
| phone | VARCHAR2(20) | - | NULL | 手机号码 |
| is_verified | NUMBER(1) | CHECK(0,1) | 0 | 认证状态 |
| is_active | NUMBER(1) | CHECK(0,1) | 1 | 账户状态 |
| followers_count | NUMBER(10) | - | 0 | 粉丝数量 |
| following_count | NUMBER(10) | - | 0 | 关注数量 |
| tweets_count | NUMBER(10) | - | 0 | 推文数量 |
| likes_count | NUMBER(10) | - | 0 | 点赞数量 |

**插入示例：**
```sql
INSERT INTO t_users (
    user_id, email, username, password_hash, 
    display_name, bio
) VALUES (
    seq_user_id.NEXTVAL, 
    'john@example.com', 
    'john_doe', 
    '$2b$10$...',  -- bcrypt哈希
    '约翰·多伊',
    '热爱编程的全栈工程师'
);
```

---

### 2. 推文表 (t_tweets)

**表功能：** 存储所有推文内容，包括原创推文、回复、转发和引用推文

**必填字段：**
- `author_id` - 作者用户ID
- `content` - 推文内容

**字段详解：**

| 字段名 | 数据类型 | 约束 | 默认值 | 说明 |
|--------|----------|------|--------|------|
| tweet_id | NUMBER(15) | PK | 序列生成 | 推文唯一标识符 |
| author_id | NUMBER(10) | NOT NULL, FK | - | 作者用户ID |
| content | CLOB | - | NULL | 推文内容（支持富文本） |
| reply_to_tweet_id | NUMBER(15) | FK | NULL | 回复的原推文ID |
| retweet_of_tweet_id | NUMBER(15) | FK | NULL | 转发的原推文ID |
| quote_tweet_id | NUMBER(15) | FK | NULL | 引用的推文ID |
| is_retweet | NUMBER(1) | CHECK(0,1) | 0 | 是否为转发 |
| is_quote_tweet | NUMBER(1) | CHECK(0,1) | 0 | 是否为引用推文 |
| visibility | VARCHAR2(20) | CHECK约束 | 'public' | 可见性设置 |
| language | VARCHAR2(10) | - | 'zh' | 语言代码 |

**可见性选项：**
- `public` - 公开可见
- `followers` - 仅关注者可见
- `mentioned` - 仅被提及者可见
- `private` - 私有

**插入示例：**
```sql
-- 发布原创推文
INSERT INTO t_tweets (
    tweet_id, author_id, content, visibility
) VALUES (
    seq_tweet_id.NEXTVAL, 
    1001, 
    '今天天气真好！#天气 #心情', 
    'public'
);

-- 回复推文
INSERT INTO t_tweets (
    tweet_id, author_id, content, reply_to_tweet_id
) VALUES (
    seq_tweet_id.NEXTVAL, 
    1002, 
    '确实如此！', 
    10001
);

-- 转发推文
INSERT INTO t_tweets (
    tweet_id, author_id, content, retweet_of_tweet_id, is_retweet
) VALUES (
    seq_tweet_id.NEXTVAL, 
    1003, 
    '', 
    10001, 
    1
);
```

---

### 3. 关注关系表 (t_follows)

**表功能：** 管理用户之间的关注、屏蔽、静音关系

**必填字段：**
- `follower_id` - 关注者ID
- `following_id` - 被关注者ID

**关系类型：**
- `follow` - 关注关系
- `block` - 屏蔽关系
- `mute` - 静音关系

**约束限制：**
- 防止用户关注自己：`CHECK (follower_id != following_id)`
- 防止重复关注：`UNIQUE (follower_id, following_id)`

**插入示例：**
```sql
-- 用户1001关注用户1002
INSERT INTO t_follows (
    follow_id, follower_id, following_id, follow_type
) VALUES (
    seq_follow_id.NEXTVAL, 1001, 1002, 'follow'
);

-- 用户1001屏蔽用户1003
INSERT INTO t_follows (
    follow_id, follower_id, following_id, follow_type
) VALUES (
    seq_follow_id.NEXTVAL, 1001, 1003, 'block'
);
```

---

### 4. 点赞表 (t_likes)

**表功能：** 记录用户对推文的各种反应

**必填字段：**
- `user_id` - 点赞用户ID
- `tweet_id` - 被点赞推文ID

**反应类型：**
- `like` - 点赞
- `dislike` - 不喜欢
- `love` - 喜爱
- `laugh` - 好笑
- `angry` - 愤怒

**约束限制：**
- 一个用户对一个推文只能有一种反应：`UNIQUE (user_id, tweet_id)`

**插入示例：**
```sql
INSERT INTO t_likes (
    like_id, user_id, tweet_id, like_type
) VALUES (
    seq_like_id.NEXTVAL, 1001, 10001, 'like'
);
```

---

### 5. 评论表 (t_comments)

**表功能：** 支持多层级嵌套的推文评论系统

**必填字段：**
- `tweet_id` - 被评论推文ID
- `user_id` - 评论者ID
- `content` - 评论内容

**特殊功能：**
- 支持评论嵌套：通过`parent_comment_id`实现
- 软删除机制：通过`is_deleted`标记

**插入示例：**
```sql
-- 顶级评论
INSERT INTO t_comments (
    comment_id, tweet_id, user_id, content
) VALUES (
    seq_comment_id.NEXTVAL, 10001, 1002, '很棒的推文！'
);

-- 回复评论（二级评论）
INSERT INTO t_comments (
    comment_id, tweet_id, user_id, parent_comment_id, content
) VALUES (
    seq_comment_id.NEXTVAL, 10001, 1003, 100001, '同意楼上的观点'
);
```

---

### 6. 媒体文件表 (t_media)

**表功能：** 存储推文中的图片、视频、音频等媒体文件信息

**必填字段：**
- `user_id` - 上传用户ID
- `media_type` - 媒体类型
- `file_name` - 文件名
- `file_path` - 文件路径
- `file_size` - 文件大小
- `mime_type` - MIME类型

**媒体类型：**
- `image` - 图片
- `video` - 视频
- `audio` - 音频
- `gif` - 动图

**插入示例：**
```sql
INSERT INTO t_media (
    media_id, tweet_id, user_id, media_type, 
    file_name, file_path, file_size, mime_type, 
    width, height
) VALUES (
    seq_media_id.NEXTVAL, 10001, 1001, 'image',
    'sunset.jpg', '/uploads/2024/06/sunset.jpg', 
    1024000, 'image/jpeg', 1920, 1080
);
```

---

### 7. 话题标签表 (t_hashtags)

**表功能：** 管理系统中的所有话题标签

**必填字段：**
- `tag_name` - 标签名称（唯一）
- `tag_name_lower` - 小写版本（用于搜索）

**特殊功能：**
- 趋势计算：通过`trending_score`计算热门话题
- 使用统计：`usage_count`记录使用次数

**插入示例：**
```sql
INSERT INTO t_hashtags (
    hashtag_id, tag_name, tag_name_lower, usage_count
) VALUES (
    seq_hashtag_id.NEXTVAL, '天气', '天气', 1
);
```

---

### 8. 推文标签关联表 (t_tweet_hashtags)

**表功能：** 实现推文与标签的多对多关联

**必填字段：**
- `tweet_id` - 推文ID
- `hashtag_id` - 标签ID

**主键：** 复合主键 `(tweet_id, hashtag_id)`

**插入示例：**
```sql
INSERT INTO t_tweet_hashtags (
    tweet_id, hashtag_id
) VALUES (
    10001, 1
);
```

---

### 9. 用户会话表 (t_user_sessions)

**表功能：** 管理用户登录会话和JWT令牌

**必填字段：**
- `session_id` - 会话ID（主键）
- `user_id` - 用户ID
- `jwt_token` - JWT令牌
- `expires_at` - 过期时间

**插入示例：**
```sql
INSERT INTO t_user_sessions (
    session_id, user_id, jwt_token, 
    device_info, ip_address, expires_at
) VALUES (
    'session_123456789', 1001, 'eyJhbGciOiJIUzI1NiIs...',
    'iPhone 13 Pro Max', '192.168.1.100', 
    CURRENT_TIMESTAMP + INTERVAL '7' DAY
);
```

---

## 数据操作最佳实践

### 1. 插入数据的基本原则

**使用序列生成主键：**
```sql
-- 正确方式
INSERT INTO t_users (user_id, email, username, password_hash)
VALUES (seq_user_id.NEXTVAL, 'user@example.com', 'username', 'hash');

-- 错误方式（不要手动指定主键）
INSERT INTO t_users (user_id, email, username, password_hash)
VALUES (999, 'user@example.com', 'username', 'hash');
```

**检查必填字段：**
每个表的插入操作都必须提供所有NOT NULL字段的值。

### 2. 统计字段的维护

系统中的计数字段（如followers_count、likes_count等）需要通过触发器或应用程序逻辑来维护：

```sql
-- 点赞时更新推文的点赞数
UPDATE t_tweets 
SET likes_count = likes_count + 1 
WHERE tweet_id = ?;

-- 关注时更新用户的关注数和粉丝数
UPDATE t_users 
SET following_count = following_count + 1 
WHERE user_id = ?;

UPDATE t_users 
SET followers_count = followers_count + 1 
WHERE user_id = ?;
```

### 3. 软删除的处理

系统采用软删除机制，删除数据时不要使用DELETE语句，而是更新is_deleted字段：

```sql
-- 软删除推文
UPDATE t_tweets 
SET is_deleted = 1, deleted_at = CURRENT_TIMESTAMP 
WHERE tweet_id = ?;

-- 查询时排除已删除的数据
SELECT * FROM t_tweets 
WHERE is_deleted = 0;
```

### 4. 数据查询优化建议

**使用适当的索引：**
- 在外键字段上创建索引
- 在经常用于WHERE条件的字段上创建索引
- 在用于排序的字段上创建索引

**查询示例：**
```sql
-- 获取用户的推文列表（按时间倒序）
SELECT t.*, u.username, u.display_name, u.avatar_url
FROM t_tweets t
JOIN t_users u ON t.author_id = u.user_id
WHERE t.author_id = ? 
  AND t.is_deleted = 0
ORDER BY t.created_at DESC;

-- 获取推文的评论（支持分页）
SELECT c.*, u.username, u.display_name, u.avatar_url
FROM t_comments c
JOIN t_users u ON c.user_id = u.user_id
WHERE c.tweet_id = ? 
  AND c.is_deleted = 0
ORDER BY c.created_at ASC
OFFSET ? ROWS FETCH NEXT ? ROWS ONLY;
```

---

## 数据完整性约束

### 1. 外键约束
- 所有外键字段都有相应的FOREIGN KEY约束
- 确保数据引用的完整性
- 防止孤立数据的产生

### 2. 检查约束
- 布尔型字段使用CHECK约束限制值为0或1
- 枚举型字段使用CHECK约束限制可选值
- 防止无效数据的插入

### 3. 唯一约束
- email和username字段的唯一性
- 防止重复关注关系
- 确保一个用户对一个推文只能有一种反应

### 4. 非空约束
- 关键字段设置为NOT NULL
- 确保核心数据的完整性

---

## 性能优化建议

### 1. 表空间管理
- 使用专用表空间`twitter_data`
- 根据数据增长情况调整表空间大小
- 定期监控表空间使用率

### 2. 序列优化
- 根据业务特点设置合适的缓存大小
- 推文和评论使用较大的缓存值（50-100）
- 用户注册使用较小的缓存值（20）

### 3. 索引策略
建议创建以下索引：
```sql
-- 用户表索引
CREATE INDEX idx_users_email ON t_users(email);
CREATE INDEX idx_users_username ON t_users(username);

-- 推文表索引
CREATE INDEX idx_tweets_author ON t_tweets(author_id);
CREATE INDEX idx_tweets_created ON t_tweets(created_at);
CREATE INDEX idx_tweets_reply ON t_tweets(reply_to_tweet_id);

-- 关注关系索引
CREATE INDEX idx_follows_follower ON t_follows(follower_id);
CREATE INDEX idx_follows_following ON t_follows(following_id);

-- 点赞表索引
CREATE INDEX idx_likes_user ON t_likes(user_id);
CREATE INDEX idx_likes_tweet ON t_likes(tweet_id);

-- 评论表索引
CREATE INDEX idx_comments_tweet ON t_comments(tweet_id);
CREATE INDEX idx_comments_user ON t_comments(user_id);
CREATE INDEX idx_comments_parent ON t_comments(parent_comment_id);

-- 媒体表索引
CREATE INDEX idx_media_tweet ON t_media(tweet_id);
CREATE INDEX idx_media_user ON t_media(user_id);
```

### 4. 查询优化
- 避免SELECT *，只查询需要的字段
- 使用适当的分页机制
- 对大表查询使用合适的WHERE条件
- 使用EXPLAIN PLAN分析查询执行计划

---

## 安全考虑

### 1. 密码存储
- 使用bcrypt等强加密算法
- 密码哈希值存储在password_hash字段
- 永远不要存储明文密码

### 2. 会话管理
- JWT令牌设置合理的过期时间
- 定期清理过期的会话记录
- 记录用户的登录设备和IP地址

### 3. 数据访问控制
- 使用数据库角色和权限控制
- 敏感操作记录审计日志
- 定期备份重要数据

---

## 总结

本NekoTribe数据库设计方案提供了完整的社交媒体功能支持，具有以下特点：

1. **完整性**：涵盖用户管理、内容发布、社交关系等核心功能
2. **可扩展性**：支持未来功能扩展和性能优化
3. **数据完整性**：完善的约束机制保证数据质量
4. **性能优化**：合理的索引设计和查询优化策略
5. **安全性**：内置安全机制和审计功能

在实际使用中，请根据具体的业务需求和数据量级对设计方案进行适当调整和优化。
