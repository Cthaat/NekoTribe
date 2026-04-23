-- ==========================================
-- NekoTribe Oracle 数据库 V2 设计方案（含群组）
-- 基于文件:
--   1. doc/neko_tribe-oracle - with-group.sql
--   2. doc/NekoTribe-V2接口与Oracle重构总设计.md
--   3. doc/API v2平滑迁移实战指南(新手版).md
--
-- 设计目标:
--   1. 在尽量保留现有命名风格和群组对象的基础上，为 API V2 提供新的数据库基线。
--   2. 社交主线从“动作式 + 推文式模型”升级为“资源式 + posts 模型”。
--   3. 群组模块保留现有表、函数、过程和视图的整体思路，只修复明显问题并兼容新的用户主表。
--   4. 去掉 V1 中最影响 V2 开发的模型问题:
--      - n_follows 混装 follow / block / mute
--      - n_likes 同时承担帖子点赞与评论点赞
--      - n_media 既做资源库又直接绑定帖子
--      - n_user_sessions 直接保存原始 token CLOB
--      - tweets / hashtags 命名不适合 V2 的 posts / tags 资源设计
--
-- 重要说明:
--   1. 这是新的 V2 基线脚本，不会覆盖原 V1 SQL 文件。
--   2. 建议在新的 schema 或新的开发环境中执行。
--   3. 如果你的数据库里已经存在同名 tablespace / user，请先手动注释掉“环境初始化”部分。
--   4. 本脚本重点是“可直接开始 V2 接口开发”，因此不包含旧版测试数据灌入段。
-- ==========================================

ALTER SESSION SET CONTAINER = ORCLPDB1;

-- ==========================================
-- 1. 环境初始化（如果已存在同名对象，可按需手动注释）
-- ==========================================

-- 创建数据表空间
CREATE TABLESPACE neko_data
DATAFILE '/opt/oracle/oradata/neko_data_v2_01.dbf'
SIZE 500M
AUTOEXTEND ON NEXT 50M MAXSIZE 4G
SEGMENT SPACE MANAGEMENT AUTO;

-- 创建索引表空间
CREATE TABLESPACE neko_index
DATAFILE '/opt/oracle/oradata/neko_index_v2_01.dbf'
SIZE 200M
AUTOEXTEND ON NEXT 20M MAXSIZE 2G
SEGMENT SPACE MANAGEMENT AUTO;

-- 创建临时表空间
CREATE TEMPORARY TABLESPACE neko_temp
TEMPFILE '/opt/oracle/oradata/neko_temp_v2_01.dbf'
SIZE 100M
AUTOEXTEND ON NEXT 10M MAXSIZE 500M;

-- 创建应用用户
CREATE USER neko_app
IDENTIFIED BY "NekoApp2026#"
DEFAULT TABLESPACE neko_data
TEMPORARY TABLESPACE neko_temp
QUOTA UNLIMITED ON neko_data
QUOTA UNLIMITED ON neko_index;

-- 创建管理员用户
CREATE USER neko_admin
IDENTIFIED BY "NekoAdmin2026#"
DEFAULT TABLESPACE neko_data
TEMPORARY TABLESPACE neko_temp
QUOTA UNLIMITED ON neko_data
QUOTA UNLIMITED ON neko_index;

-- 创建只读用户
CREATE USER neko_readonly
IDENTIFIED BY "NekoRead2026#"
DEFAULT TABLESPACE neko_data
TEMPORARY TABLESPACE neko_temp;

-- 应用用户权限
GRANT CONNECT, RESOURCE TO neko_app;

GRANT
    CREATE VIEW,
    CREATE PROCEDURE,
    CREATE TRIGGER,
    CREATE SEQUENCE,
    CREATE MATERIALIZED VIEW
TO neko_app;

-- 管理员权限
GRANT DBA TO neko_admin;

-- 只读用户权限
GRANT CONNECT TO neko_readonly;

ALTER SESSION SET CURRENT_SCHEMA = NEKO_APP;

-- ==========================================
-- 2. V2 模型变化说明
-- ==========================================
--
-- 旧模型 -> 新模型
--   n_tweets           -> n_posts + n_post_stats
--   n_follows          -> n_user_follows + n_user_blocks + n_user_mutes
--   n_likes            -> n_post_likes + n_comment_likes
--   n_media            -> n_media_assets + n_post_media
--   n_hashtags         -> n_tags
--   n_tweet_hashtags   -> n_post_tags
--   n_tweet_mentions   -> n_post_mentions
--   n_user_sessions    -> n_auth_sessions
--   文件 settings      -> n_user_settings
--   文件 statements    -> n_account_statements + n_statement_appeals
--
-- 保留并兼容:
--   n_users
--   n_notifications
--   n_groups / n_group_* 全套群组对象
--
-- API V2 对应资源:
--   /auth/*
--   /users/*
--   /posts/*
--   /comments/*
--   /media/*
--   /tags/*
--   /notifications/*
-- ==========================================

-- ==========================================
-- 3. 序列
-- ==========================================

CREATE SEQUENCE seq_user_id START WITH 1000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 20;
CREATE SEQUENCE seq_otp_event_id START WITH 10000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 20;
CREATE SEQUENCE seq_follow_id START WITH 20000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 50;
CREATE SEQUENCE seq_block_id START WITH 30000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 50;
CREATE SEQUENCE seq_mute_id START WITH 40000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 50;
CREATE SEQUENCE seq_post_id START WITH 100000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 100;
CREATE SEQUENCE seq_post_like_id START WITH 200000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 100;
CREATE SEQUENCE seq_post_bookmark_id START WITH 300000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 100;
CREATE SEQUENCE seq_comment_id START WITH 400000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 100;
CREATE SEQUENCE seq_comment_like_id START WITH 500000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 100;
CREATE SEQUENCE seq_media_id START WITH 600000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 50;
CREATE SEQUENCE seq_tag_id START WITH 700000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 50;
CREATE SEQUENCE seq_notification_id START WITH 800000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 100;
CREATE SEQUENCE seq_statement_id START WITH 900000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 50;
CREATE SEQUENCE seq_statement_appeal_id START WITH 1000000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 50;

-- 群组模块延续原有独立序列
CREATE SEQUENCE seq_group_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE seq_group_member_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE seq_group_post_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE seq_group_comment_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE seq_group_invite_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE seq_group_audit_log_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE seq_group_post_like_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE seq_group_comment_like_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

-- ==========================================
-- 4. 核心业务表
-- ==========================================

-- 4.1 用户主表
-- 说明:
--   1. 保留 avatar_url / is_verified / is_active 等旧群组对象依赖字段。
--   2. 新增 status / email_verified_at / avatar_media_id，满足 V2 认证与资料需求。
CREATE TABLE n_users (
    user_id              NUMBER(10)      PRIMARY KEY,
    email                VARCHAR2(100)   NOT NULL,
    username             VARCHAR2(50)    NOT NULL,
    password_hash        VARCHAR2(255)   NOT NULL,
    avatar_url           VARCHAR2(500)   DEFAULT '/default-avatar.png',
    avatar_media_id      NUMBER(15),
    display_name         VARCHAR2(100),
    bio                  VARCHAR2(500),
    location             VARCHAR2(100),
    website              VARCHAR2(200),
    birth_date           DATE,
    phone                VARCHAR2(20),
    email_verified_at    TIMESTAMP,
    is_verified          NUMBER(1)       DEFAULT 0 CHECK (is_verified IN (0, 1)),
    is_active            NUMBER(1)       DEFAULT 1 CHECK (is_active IN (0, 1)),
    status               VARCHAR2(20)    DEFAULT 'active' CHECK (status IN ('active', 'disabled', 'suspended', 'pending')),
    created_at           TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at           TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    last_login_at        TIMESTAMP,
    created_by           VARCHAR2(50)    DEFAULT USER,
    updated_by           VARCHAR2(50)    DEFAULT USER,
    CONSTRAINT uk_users_email UNIQUE (email),
    CONSTRAINT uk_users_username UNIQUE (username)
) TABLESPACE neko_data;

COMMENT ON TABLE n_users IS '用户主表，兼容 V2 用户资料、鉴权、群组归属等所有基础能力';
COMMENT ON COLUMN n_users.user_id IS '用户主键';
COMMENT ON COLUMN n_users.email IS '登录邮箱，唯一';
COMMENT ON COLUMN n_users.username IS '用户名，唯一';
COMMENT ON COLUMN n_users.password_hash IS '密码哈希，不允许返回给客户端';
COMMENT ON COLUMN n_users.avatar_url IS '头像 URL，保留给群组和旧逻辑直接读取';
COMMENT ON COLUMN n_users.avatar_media_id IS '头像关联的媒体资源 ID，V2 推荐使用';
COMMENT ON COLUMN n_users.email_verified_at IS '邮箱验证通过时间';
COMMENT ON COLUMN n_users.is_verified IS '是否为认证账号';
COMMENT ON COLUMN n_users.is_active IS '是否可用，保留给兼容逻辑';
COMMENT ON COLUMN n_users.status IS 'V2 账户状态：active / disabled / suspended / pending';

-- 4.2 用户统计表
-- 说明:
--   V2 统计从主表拆出，减少热点写冲突。
CREATE TABLE n_user_stats (
    user_id              NUMBER(10)      PRIMARY KEY,
    followers_count      NUMBER(10)      DEFAULT 0 NOT NULL,
    following_count      NUMBER(10)      DEFAULT 0 NOT NULL,
    posts_count          NUMBER(10)      DEFAULT 0 NOT NULL,
    likes_count          NUMBER(10)      DEFAULT 0 NOT NULL,
    bookmarks_count      NUMBER(10)      DEFAULT 0 NOT NULL,
    comments_count       NUMBER(10)      DEFAULT 0 NOT NULL,
    updated_at           TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_user_stats_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE
) TABLESPACE neko_data;

COMMENT ON TABLE n_user_stats IS '用户统计表，集中维护粉丝、帖子、获赞、收藏、评论等聚合数据';

-- 4.3 OTP 事件表
CREATE TABLE n_auth_otp_events (
    otp_event_id            NUMBER(15)      PRIMARY KEY,
    account                 VARCHAR2(100)   NOT NULL,
    otp_type                VARCHAR2(30)    NOT NULL CHECK (otp_type IN ('register', 'password_reset', 'change_email')),
    verification_code_hash  VARCHAR2(255)   NOT NULL,
    verification_id         VARCHAR2(64)    DEFAULT RAWTOHEX(SYS_GUID()) NOT NULL,
    expires_at              TIMESTAMP       NOT NULL,
    verified_at             TIMESTAMP,
    created_at              TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT uk_auth_otp_verification_id UNIQUE (verification_id)
) TABLESPACE neko_data;

COMMENT ON TABLE n_auth_otp_events IS 'OTP 事件表，支持注册、改邮箱、找回密码等一次性验证码流程';

-- 4.4 会话表
-- 说明:
--   不再直接保存 access_token / refresh_token 原文。
--   session_id 与 access_jti 都允许由应用生成；数据库也提供默认兜底。
CREATE TABLE n_auth_sessions (
    session_id                VARCHAR2(64)   PRIMARY KEY,
    user_id                   NUMBER(10)     NOT NULL,
    access_jti                VARCHAR2(64)   NOT NULL,
    refresh_token_hash        VARCHAR2(255)  NOT NULL,
    device_info               VARCHAR2(500),
    device_fingerprint        VARCHAR2(255),
    ip_address                VARCHAR2(45),
    user_agent                CLOB,
    access_token_expires_at   TIMESTAMP      NOT NULL,
    refresh_token_expires_at  TIMESTAMP      NOT NULL,
    last_accessed_at          TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
    last_refresh_at           TIMESTAMP,
    revoked_at                TIMESTAMP,
    created_at                TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_auth_sessions_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE
) TABLESPACE neko_data;

COMMENT ON TABLE n_auth_sessions IS 'V2 会话表，仅保存会话标识、refresh token 哈希和设备信息';

-- 4.5 关注关系表
CREATE TABLE n_user_follows (
    follow_id             NUMBER(15)      PRIMARY KEY,
    follower_id           NUMBER(10)      NOT NULL,
    following_id          NUMBER(10)      NOT NULL,
    status                VARCHAR2(20)    DEFAULT 'active' NOT NULL CHECK (status IN ('active', 'cancelled')),
    created_at            TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at            TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_user_follows_follower FOREIGN KEY (follower_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_user_follows_following FOREIGN KEY (following_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT uk_user_follows UNIQUE (follower_id, following_id),
    CONSTRAINT ck_user_follows_not_self CHECK (follower_id != following_id)
) TABLESPACE neko_data;

COMMENT ON TABLE n_user_follows IS '关注关系表，只承担 follow 语义，不再混装 block / mute';

-- 4.6 屏蔽关系表
CREATE TABLE n_user_blocks (
    block_id               NUMBER(15)      PRIMARY KEY,
    user_id                NUMBER(10)      NOT NULL,
    target_user_id         NUMBER(10)      NOT NULL,
    created_at             TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_user_blocks_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_user_blocks_target FOREIGN KEY (target_user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT uk_user_blocks UNIQUE (user_id, target_user_id),
    CONSTRAINT ck_user_blocks_not_self CHECK (user_id != target_user_id)
) TABLESPACE neko_data;

COMMENT ON TABLE n_user_blocks IS '屏蔽关系表，对应 V2 的 /users/me/blocks 资源';

-- 4.7 静音关系表
CREATE TABLE n_user_mutes (
    mute_id                NUMBER(15)      PRIMARY KEY,
    user_id                NUMBER(10)      NOT NULL,
    target_user_id         NUMBER(10)      NOT NULL,
    expires_at             TIMESTAMP,
    created_at             TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_user_mutes_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_user_mutes_target FOREIGN KEY (target_user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT uk_user_mutes UNIQUE (user_id, target_user_id),
    CONSTRAINT ck_user_mutes_not_self CHECK (user_id != target_user_id)
) TABLESPACE neko_data;

COMMENT ON TABLE n_user_mutes IS '静音关系表，预留给后续扩展 /users/me/mutes 资源';

-- 4.8 帖子主表
-- 说明:
--   V2 用 posts 取代 tweets。
--   reply / repost / quote 都在同一资源内建模。
CREATE TABLE n_posts (
    post_id                NUMBER(15)      PRIMARY KEY,
    author_id              NUMBER(10)      NOT NULL,
    content                CLOB,
    post_type              VARCHAR2(20)    DEFAULT 'post' NOT NULL CHECK (post_type IN ('post', 'reply', 'repost', 'quote')),
    reply_to_post_id       NUMBER(15),
    repost_of_post_id      NUMBER(15),
    quoted_post_id         NUMBER(15),
    visibility             VARCHAR2(20)    DEFAULT 'public' NOT NULL CHECK (visibility IN ('public', 'followers', 'mentioned', 'private')),
    language               VARCHAR2(10)    DEFAULT 'zh',
    location               VARCHAR2(100),
    is_deleted             NUMBER(1)       DEFAULT 0 NOT NULL CHECK (is_deleted IN (0, 1)),
    deleted_at             TIMESTAMP,
    created_at             TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at             TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    created_by             VARCHAR2(50)    DEFAULT USER,
    updated_by             VARCHAR2(50)    DEFAULT USER,
    CONSTRAINT fk_posts_author FOREIGN KEY (author_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_posts_reply FOREIGN KEY (reply_to_post_id)
        REFERENCES n_posts(post_id),
    CONSTRAINT fk_posts_repost FOREIGN KEY (repost_of_post_id)
        REFERENCES n_posts(post_id),
    CONSTRAINT fk_posts_quote FOREIGN KEY (quoted_post_id)
        REFERENCES n_posts(post_id)
) TABLESPACE neko_data;

COMMENT ON TABLE n_posts IS '帖子主表，V2 统一承载发帖、回复、转发、引用贴';

-- 4.9 帖子统计表
CREATE TABLE n_post_stats (
    post_id                NUMBER(15)      PRIMARY KEY,
    likes_count            NUMBER(10)      DEFAULT 0 NOT NULL,
    comments_count         NUMBER(10)      DEFAULT 0 NOT NULL,
    replies_count          NUMBER(10)      DEFAULT 0 NOT NULL,
    retweets_count         NUMBER(10)      DEFAULT 0 NOT NULL,
    views_count            NUMBER(15)      DEFAULT 0 NOT NULL,
    engagement_score       NUMBER(10, 2)   DEFAULT 0 NOT NULL,
    updated_at             TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_post_stats_post FOREIGN KEY (post_id)
        REFERENCES n_posts(post_id) ON DELETE CASCADE
) TABLESPACE neko_data;

COMMENT ON TABLE n_post_stats IS '帖子统计表，集中维护点赞、评论、回复、转发、浏览和热度';

-- 4.10 媒体资源表
CREATE TABLE n_media_assets (
    media_id               NUMBER(15)      PRIMARY KEY,
    owner_user_id          NUMBER(10)      NOT NULL,
    media_type             VARCHAR2(20)    NOT NULL CHECK (media_type IN ('image', 'video', 'audio', 'gif')),
    file_name              VARCHAR2(255)   NOT NULL,
    storage_key            VARCHAR2(500)   NOT NULL,
    public_url             VARCHAR2(500)   NOT NULL,
    file_size              NUMBER(15)      NOT NULL,
    mime_type              VARCHAR2(100)   NOT NULL,
    width                  NUMBER(6),
    height                 NUMBER(6),
    duration               NUMBER(10),
    thumbnail_url          VARCHAR2(500),
    alt_text               VARCHAR2(500),
    status                 VARCHAR2(20)    DEFAULT 'ready' NOT NULL CHECK (status IN ('uploaded', 'processing', 'ready', 'failed')),
    created_at             TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_media_assets_owner FOREIGN KEY (owner_user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE
) TABLESPACE neko_data;

COMMENT ON TABLE n_media_assets IS '媒体资源表，V2 先上传媒体，再通过 n_post_media 关联到帖子';

-- 4.11 帖子媒体关联表
CREATE TABLE n_post_media (
    post_id                NUMBER(15)      NOT NULL,
    media_id               NUMBER(15)      NOT NULL,
    sort_order             NUMBER(5)       DEFAULT 1 NOT NULL,
    created_at             TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    PRIMARY KEY (post_id, media_id),
    CONSTRAINT fk_post_media_post FOREIGN KEY (post_id)
        REFERENCES n_posts(post_id) ON DELETE CASCADE,
    CONSTRAINT fk_post_media_media FOREIGN KEY (media_id)
        REFERENCES n_media_assets(media_id) ON DELETE CASCADE
) TABLESPACE neko_data;

COMMENT ON TABLE n_post_media IS '帖子与媒体的多对多关联表，支持一条帖子挂多个媒体资源';

-- 4.12 帖子点赞表
CREATE TABLE n_post_likes (
    post_like_id           NUMBER(15)      PRIMARY KEY,
    post_id                NUMBER(15)      NOT NULL,
    user_id                NUMBER(10)      NOT NULL,
    created_at             TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_post_likes_post FOREIGN KEY (post_id)
        REFERENCES n_posts(post_id) ON DELETE CASCADE,
    CONSTRAINT fk_post_likes_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT uk_post_likes UNIQUE (post_id, user_id)
) TABLESPACE neko_data;

COMMENT ON TABLE n_post_likes IS '帖子点赞表，V2 只承担 posts/{id}/likes 资源';

-- 4.13 帖子收藏表
CREATE TABLE n_post_bookmarks (
    bookmark_id            NUMBER(15)      PRIMARY KEY,
    post_id                NUMBER(15)      NOT NULL,
    user_id                NUMBER(10)      NOT NULL,
    created_at             TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_post_bookmarks_post FOREIGN KEY (post_id)
        REFERENCES n_posts(post_id) ON DELETE CASCADE,
    CONSTRAINT fk_post_bookmarks_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT uk_post_bookmarks UNIQUE (post_id, user_id)
) TABLESPACE neko_data;

COMMENT ON TABLE n_post_bookmarks IS '帖子收藏表，对应 /posts/{id}/bookmarks 和 /users/me/bookmarks';

-- 4.14 评论主表
CREATE TABLE n_comments (
    comment_id             NUMBER(15)      PRIMARY KEY,
    post_id                NUMBER(15)      NOT NULL,
    user_id                NUMBER(10)      NOT NULL,
    parent_comment_id      NUMBER(15),
    root_comment_id        NUMBER(15),
    content                CLOB            NOT NULL,
    is_deleted             NUMBER(1)       DEFAULT 0 NOT NULL CHECK (is_deleted IN (0, 1)),
    deleted_at             TIMESTAMP,
    created_at             TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at             TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_comments_post FOREIGN KEY (post_id)
        REFERENCES n_posts(post_id) ON DELETE CASCADE,
    CONSTRAINT fk_comments_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_comments_parent FOREIGN KEY (parent_comment_id)
        REFERENCES n_comments(comment_id)
) TABLESPACE neko_data;

COMMENT ON TABLE n_comments IS '评论主表，支持顶级评论和嵌套回复';

-- 4.15 评论统计表
CREATE TABLE n_comment_stats (
    comment_id             NUMBER(15)      PRIMARY KEY,
    likes_count            NUMBER(10)      DEFAULT 0 NOT NULL,
    replies_count          NUMBER(10)      DEFAULT 0 NOT NULL,
    updated_at             TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_comment_stats_comment FOREIGN KEY (comment_id)
        REFERENCES n_comments(comment_id) ON DELETE CASCADE
) TABLESPACE neko_data;

COMMENT ON TABLE n_comment_stats IS '评论统计表，维护点赞数和子回复数';

-- 4.16 评论点赞表
CREATE TABLE n_comment_likes (
    comment_like_id        NUMBER(15)      PRIMARY KEY,
    comment_id             NUMBER(15)      NOT NULL,
    user_id                NUMBER(10)      NOT NULL,
    created_at             TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_comment_likes_comment FOREIGN KEY (comment_id)
        REFERENCES n_comments(comment_id) ON DELETE CASCADE,
    CONSTRAINT fk_comment_likes_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT uk_comment_likes UNIQUE (comment_id, user_id)
) TABLESPACE neko_data;

COMMENT ON TABLE n_comment_likes IS '评论点赞表，解决 V1 中评论点赞复用 n_likes 的设计问题';

-- 4.17 话题标签表
CREATE TABLE n_tags (
    tag_id                  NUMBER(10)      PRIMARY KEY,
    name                    VARCHAR2(100)   NOT NULL,
    name_lower              VARCHAR2(100)   NOT NULL,
    usage_count             NUMBER(15)      DEFAULT 0 NOT NULL,
    trending_score          NUMBER(10, 2)   DEFAULT 0 NOT NULL,
    is_trending             NUMBER(1)       DEFAULT 0 NOT NULL CHECK (is_trending IN (0, 1)),
    created_at              TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at              TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT uk_tags_name_lower UNIQUE (name_lower)
) TABLESPACE neko_data;

COMMENT ON TABLE n_tags IS '话题标签主表，对应 V2 的 /tags 资源';

-- 4.18 帖子标签关联表
CREATE TABLE n_post_tags (
    post_id                 NUMBER(15)      NOT NULL,
    tag_id                  NUMBER(10)      NOT NULL,
    created_at              TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    PRIMARY KEY (post_id, tag_id),
    CONSTRAINT fk_post_tags_post FOREIGN KEY (post_id)
        REFERENCES n_posts(post_id) ON DELETE CASCADE,
    CONSTRAINT fk_post_tags_tag FOREIGN KEY (tag_id)
        REFERENCES n_tags(tag_id) ON DELETE CASCADE
) TABLESPACE neko_data;

COMMENT ON TABLE n_post_tags IS '帖子与标签的多对多关联表';

-- 4.19 帖子提及关联表
CREATE TABLE n_post_mentions (
    post_id                 NUMBER(15)      NOT NULL,
    mentioned_user_id       NUMBER(10)      NOT NULL,
    created_at              TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    PRIMARY KEY (post_id, mentioned_user_id),
    CONSTRAINT fk_post_mentions_post FOREIGN KEY (post_id)
        REFERENCES n_posts(post_id) ON DELETE CASCADE,
    CONSTRAINT fk_post_mentions_user FOREIGN KEY (mentioned_user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE
) TABLESPACE neko_data;

COMMENT ON TABLE n_post_mentions IS '帖子提及关联表，用于 @ 提及与 mentioned 可见性判断';

-- 4.20 通知主表
CREATE TABLE n_notifications (
    notification_id         NUMBER(15)      PRIMARY KEY,
    user_id                 NUMBER(10)      NOT NULL,
    actor_id                NUMBER(10),
    type                    VARCHAR2(30)    NOT NULL,
    title                   VARCHAR2(200),
    message                 VARCHAR2(1000),
    resource_type           VARCHAR2(30),
    resource_id             NUMBER(15),
    priority                VARCHAR2(10)    DEFAULT 'normal' NOT NULL CHECK (priority IN ('low', 'normal', 'high', 'urgent')),
    is_read                 NUMBER(1)       DEFAULT 0 NOT NULL CHECK (is_read IN (0, 1)),
    read_at                 TIMESTAMP,
    deleted_at              TIMESTAMP,
    metadata_json           CLOB,
    created_at              TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_notifications_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_notifications_actor FOREIGN KEY (actor_id)
        REFERENCES n_users(user_id) ON DELETE SET NULL
) TABLESPACE neko_data;

COMMENT ON TABLE n_notifications IS '通知主表，兼容列表、已读、软删除和资源跳转';

-- 4.21 通知偏好表
CREATE TABLE n_notification_preferences (
    user_id                 NUMBER(10)      NOT NULL,
    notification_type       VARCHAR2(30)    NOT NULL,
    is_enabled              NUMBER(1)       DEFAULT 1 NOT NULL CHECK (is_enabled IN (0, 1)),
    updated_at              TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    PRIMARY KEY (user_id, notification_type),
    CONSTRAINT fk_notification_preferences_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE
) TABLESPACE neko_data;

COMMENT ON TABLE n_notification_preferences IS '通知偏好表，支持按通知类型开关推送';

-- 4.22 用户设置表
CREATE TABLE n_user_settings (
    user_id                      NUMBER(10)      PRIMARY KEY,
    two_factor_enabled           NUMBER(1)       DEFAULT 0 NOT NULL CHECK (two_factor_enabled IN (0, 1)),
    login_alerts                 NUMBER(1)       DEFAULT 1 NOT NULL CHECK (login_alerts IN (0, 1)),
    profile_visibility           VARCHAR2(20)    DEFAULT 'public' NOT NULL CHECK (profile_visibility IN ('public', 'private')),
    show_online_status           NUMBER(1)       DEFAULT 1 NOT NULL CHECK (show_online_status IN (0, 1)),
    allow_dm_from_strangers      NUMBER(1)       DEFAULT 0 NOT NULL CHECK (allow_dm_from_strangers IN (0, 1)),
    push_notification_enabled    NUMBER(1)       DEFAULT 1 NOT NULL CHECK (push_notification_enabled IN (0, 1)),
    email_notification_enabled   NUMBER(1)       DEFAULT 1 NOT NULL CHECK (email_notification_enabled IN (0, 1)),
    updated_at                   TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_user_settings_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE
) TABLESPACE neko_data;

COMMENT ON TABLE n_user_settings IS '用户设置表，替代 V1 中本地 JSON 文件存储的设置项';

-- 4.23 账户状态表
CREATE TABLE n_account_statements (
    statement_id             NUMBER(15)      PRIMARY KEY,
    user_id                  NUMBER(10)      NOT NULL,
    statement_type           VARCHAR2(20)    NOT NULL CHECK (statement_type IN ('info', 'warning', 'strike', 'suspension')),
    title                    VARCHAR2(200)   NOT NULL,
    message                  VARCHAR2(1000)  NOT NULL,
    policy_code              VARCHAR2(50),
    status                   VARCHAR2(20)    DEFAULT 'unread' NOT NULL CHECK (status IN ('unread', 'read', 'resolved', 'dismissed', 'appealed')),
    created_at               TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at               TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_account_statements_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE
) TABLESPACE neko_data;

COMMENT ON TABLE n_account_statements IS '账户状态表，替代 V1 中本地 JSON 存储的 account statements';

-- 4.24 申诉表
CREATE TABLE n_statement_appeals (
    appeal_id                NUMBER(15)      PRIMARY KEY,
    statement_id             NUMBER(15)      NOT NULL,
    user_id                  NUMBER(10)      NOT NULL,
    appeal_message           VARCHAR2(2000)  NOT NULL,
    appeal_status            VARCHAR2(20)    DEFAULT 'pending' NOT NULL CHECK (appeal_status IN ('pending', 'approved', 'rejected')),
    admin_response           VARCHAR2(2000),
    created_at               TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at               TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_statement_appeals_statement FOREIGN KEY (statement_id)
        REFERENCES n_account_statements(statement_id) ON DELETE CASCADE,
    CONSTRAINT fk_statement_appeals_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE
) TABLESPACE neko_data;

COMMENT ON TABLE n_statement_appeals IS '账户申诉表，对应 V2 的 appeals 子资源';

-- ==========================================
-- 5. 群组模块表（沿用 with-group 设计，兼容 V2 用户主表）
-- ==========================================

CREATE TABLE n_groups (
    group_id                 NUMBER(19)      PRIMARY KEY,
    name                     VARCHAR2(100)   NOT NULL,
    slug                     VARCHAR2(100)   UNIQUE NOT NULL,
    description              VARCHAR2(500),
    avatar_url               VARCHAR2(500),
    cover_url                VARCHAR2(500),
    owner_id                 NUMBER(10)      NOT NULL,
    privacy                  VARCHAR2(20)    DEFAULT 'public' NOT NULL,
    join_approval            NUMBER(1)       DEFAULT 0 NOT NULL,
    post_permission          VARCHAR2(20)    DEFAULT 'all' NOT NULL,
    member_count             NUMBER(10)      DEFAULT 0 NOT NULL,
    post_count               NUMBER(10)      DEFAULT 0 NOT NULL,
    is_active                NUMBER(1)       DEFAULT 1 NOT NULL,
    is_deleted               NUMBER(1)       DEFAULT 0 NOT NULL,
    created_at               TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at               TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT fk_groups_owner FOREIGN KEY (owner_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT chk_groups_privacy CHECK (privacy IN ('public', 'private', 'secret')),
    CONSTRAINT chk_groups_post_perm CHECK (post_permission IN ('all', 'admin_only', 'moderator_up'))
) TABLESPACE neko_data;

COMMENT ON TABLE n_groups IS '群组主表';

CREATE TABLE n_group_members (
    member_id                NUMBER(19)      PRIMARY KEY,
    group_id                 NUMBER(19)      NOT NULL,
    user_id                  NUMBER(10)      NOT NULL,
    role                     VARCHAR2(20)    DEFAULT 'member' NOT NULL,
    status                   VARCHAR2(20)    DEFAULT 'active' NOT NULL,
    nickname                 VARCHAR2(50),
    mute_until               TIMESTAMP,
    ban_reason               VARCHAR2(200),
    invited_by               NUMBER(10),
    joined_at                TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at               TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT fk_group_members_group FOREIGN KEY (group_id)
        REFERENCES n_groups(group_id) ON DELETE CASCADE,
    CONSTRAINT fk_group_members_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_group_members_inviter FOREIGN KEY (invited_by)
        REFERENCES n_users(user_id) ON DELETE SET NULL,
    CONSTRAINT uk_group_members UNIQUE (group_id, user_id),
    CONSTRAINT chk_member_role CHECK (role IN ('owner', 'admin', 'moderator', 'member')),
    CONSTRAINT chk_member_status CHECK (status IN ('pending', 'active', 'muted', 'banned'))
) TABLESPACE neko_data;

COMMENT ON TABLE n_group_members IS '群组成员表';

CREATE TABLE n_group_posts (
    post_id                  NUMBER(19)      PRIMARY KEY,
    group_id                 NUMBER(19)      NOT NULL,
    author_id                NUMBER(10)      NOT NULL,
    content                  VARCHAR2(4000)  NOT NULL,
    media_urls               VARCHAR2(2000),
    is_pinned                NUMBER(1)       DEFAULT 0 NOT NULL,
    is_announcement          NUMBER(1)       DEFAULT 0 NOT NULL,
    likes_count              NUMBER(10)      DEFAULT 0 NOT NULL,
    comments_count           NUMBER(10)      DEFAULT 0 NOT NULL,
    views_count              NUMBER(10)      DEFAULT 0 NOT NULL,
    is_deleted               NUMBER(1)       DEFAULT 0 NOT NULL,
    deleted_by               NUMBER(10),
    delete_reason            VARCHAR2(200),
    created_at               TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at               TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT fk_group_posts_group FOREIGN KEY (group_id)
        REFERENCES n_groups(group_id) ON DELETE CASCADE,
    CONSTRAINT fk_group_posts_author FOREIGN KEY (author_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_group_posts_deleter FOREIGN KEY (deleted_by)
        REFERENCES n_users(user_id) ON DELETE SET NULL
) TABLESPACE neko_data;

COMMENT ON TABLE n_group_posts IS '群组帖子表';

CREATE TABLE n_group_comments (
    comment_id               NUMBER(19)      PRIMARY KEY,
    post_id                  NUMBER(19)      NOT NULL,
    author_id                NUMBER(10)      NOT NULL,
    parent_comment_id        NUMBER(19),
    reply_to_user_id         NUMBER(10),
    content                  VARCHAR2(1000)  NOT NULL,
    likes_count              NUMBER(10)      DEFAULT 0 NOT NULL,
    is_deleted               NUMBER(1)       DEFAULT 0 NOT NULL,
    deleted_by               NUMBER(10),
    delete_reason            VARCHAR2(200),
    created_at               TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at               TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT fk_group_comments_post FOREIGN KEY (post_id)
        REFERENCES n_group_posts(post_id) ON DELETE CASCADE,
    CONSTRAINT fk_group_comments_author FOREIGN KEY (author_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_group_comments_parent FOREIGN KEY (parent_comment_id)
        REFERENCES n_group_comments(comment_id) ON DELETE CASCADE,
    CONSTRAINT fk_group_comments_reply_to FOREIGN KEY (reply_to_user_id)
        REFERENCES n_users(user_id) ON DELETE SET NULL,
    CONSTRAINT fk_group_comments_deleter FOREIGN KEY (deleted_by)
        REFERENCES n_users(user_id) ON DELETE SET NULL
) TABLESPACE neko_data;

COMMENT ON TABLE n_group_comments IS '群组评论表';

CREATE TABLE n_group_invites (
    invite_id                 NUMBER(19)      PRIMARY KEY,
    group_id                  NUMBER(19)      NOT NULL,
    inviter_id                NUMBER(10)      NOT NULL,
    invitee_id                NUMBER(10),
    invite_code               VARCHAR2(32),
    status                    VARCHAR2(20)    DEFAULT 'pending' NOT NULL,
    message                   VARCHAR2(200),
    max_uses                  NUMBER(5)       DEFAULT 1,
    used_count                NUMBER(5)       DEFAULT 0,
    expires_at                TIMESTAMP,
    created_at                TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    responded_at              TIMESTAMP,
    CONSTRAINT fk_group_invites_group FOREIGN KEY (group_id)
        REFERENCES n_groups(group_id) ON DELETE CASCADE,
    CONSTRAINT fk_group_invites_inviter FOREIGN KEY (inviter_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_group_invites_invitee FOREIGN KEY (invitee_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT chk_invite_status CHECK (status IN ('pending', 'accepted', 'rejected', 'expired')),
    CONSTRAINT chk_invite_type CHECK (invitee_id IS NOT NULL OR invite_code IS NOT NULL)
) TABLESPACE neko_data;

COMMENT ON TABLE n_group_invites IS '群组邀请表';

CREATE TABLE n_group_audit_logs (
    log_id                    NUMBER(19)      PRIMARY KEY,
    group_id                  NUMBER(19)      NOT NULL,
    actor_id                  NUMBER(10)      NOT NULL,
    target_user_id            NUMBER(10),
    target_post_id            NUMBER(19),
    target_comment_id         NUMBER(19),
    action                    VARCHAR2(50)    NOT NULL,
    details                   VARCHAR2(2000),
    ip_address                VARCHAR2(45),
    user_agent                VARCHAR2(500),
    created_at                TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT fk_audit_logs_group FOREIGN KEY (group_id)
        REFERENCES n_groups(group_id) ON DELETE CASCADE,
    CONSTRAINT fk_audit_logs_actor FOREIGN KEY (actor_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_audit_logs_target_user FOREIGN KEY (target_user_id)
        REFERENCES n_users(user_id) ON DELETE SET NULL,
    CONSTRAINT fk_audit_logs_target_post FOREIGN KEY (target_post_id)
        REFERENCES n_group_posts(post_id) ON DELETE SET NULL,
    CONSTRAINT fk_audit_logs_target_comment FOREIGN KEY (target_comment_id)
        REFERENCES n_group_comments(comment_id) ON DELETE SET NULL
) TABLESPACE neko_data;

COMMENT ON TABLE n_group_audit_logs IS '群组审计日志表';

CREATE TABLE n_group_post_likes (
    like_id                   NUMBER(19)      PRIMARY KEY,
    post_id                   NUMBER(19)      NOT NULL,
    user_id                   NUMBER(10)      NOT NULL,
    created_at                TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT fk_group_post_likes_post FOREIGN KEY (post_id)
        REFERENCES n_group_posts(post_id) ON DELETE CASCADE,
    CONSTRAINT fk_group_post_likes_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT uk_group_post_likes UNIQUE (post_id, user_id)
) TABLESPACE neko_data;

COMMENT ON TABLE n_group_post_likes IS '群组帖子点赞表';

CREATE TABLE n_group_comment_likes (
    like_id                   NUMBER(19)      PRIMARY KEY,
    comment_id                NUMBER(19)      NOT NULL,
    user_id                   NUMBER(10)      NOT NULL,
    created_at                TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT fk_group_comment_likes_comment FOREIGN KEY (comment_id)
        REFERENCES n_group_comments(comment_id) ON DELETE CASCADE,
    CONSTRAINT fk_group_comment_likes_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT uk_group_comment_likes UNIQUE (comment_id, user_id)
) TABLESPACE neko_data;

COMMENT ON TABLE n_group_comment_likes IS '群组评论点赞表';

-- 用户头像媒体外键，放在媒体表创建后定义，避免循环依赖
ALTER TABLE n_users
ADD CONSTRAINT fk_users_avatar_media
FOREIGN KEY (avatar_media_id)
REFERENCES n_media_assets(media_id)
ON DELETE SET NULL;

-- ==========================================
-- 6. 索引
-- ==========================================

-- 用户与认证
CREATE INDEX idx_users_last_login ON n_users(last_login_at) TABLESPACE neko_index;
CREATE INDEX idx_users_status ON n_users(status, is_active) TABLESPACE neko_index;
CREATE INDEX idx_auth_sessions_user ON n_auth_sessions(user_id, revoked_at) TABLESPACE neko_index;
CREATE INDEX idx_auth_sessions_refresh_expires ON n_auth_sessions(refresh_token_expires_at) TABLESPACE neko_index;
CREATE INDEX idx_auth_sessions_fingerprint ON n_auth_sessions(device_fingerprint) TABLESPACE neko_index;
CREATE INDEX idx_auth_otp_account_type ON n_auth_otp_events(account, otp_type, expires_at) TABLESPACE neko_index;

-- 关系
CREATE INDEX idx_user_follows_follower ON n_user_follows(follower_id, status, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_user_follows_following ON n_user_follows(following_id, status, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_user_blocks_user ON n_user_blocks(user_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_user_mutes_user ON n_user_mutes(user_id, expires_at) TABLESPACE neko_index;

-- 帖子与互动
CREATE INDEX idx_posts_author_created ON n_posts(author_id, is_deleted, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_posts_visibility_created ON n_posts(visibility, is_deleted, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_posts_reply_to ON n_posts(reply_to_post_id) TABLESPACE neko_index;
CREATE INDEX idx_posts_repost_of ON n_posts(repost_of_post_id) TABLESPACE neko_index;
CREATE INDEX idx_posts_quote_of ON n_posts(quoted_post_id) TABLESPACE neko_index;
CREATE INDEX idx_post_likes_post ON n_post_likes(post_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_post_likes_user ON n_post_likes(user_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_post_bookmarks_user ON n_post_bookmarks(user_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_comments_post ON n_comments(post_id, is_deleted, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_comments_parent ON n_comments(parent_comment_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_comment_likes_comment ON n_comment_likes(comment_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_media_assets_owner ON n_media_assets(owner_user_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_media_assets_status ON n_media_assets(status, media_type) TABLESPACE neko_index;
CREATE INDEX idx_post_media_post ON n_post_media(post_id, sort_order) TABLESPACE neko_index;

-- 标签
CREATE INDEX idx_tags_trending ON n_tags(is_trending, trending_score DESC) TABLESPACE neko_index;
CREATE INDEX idx_tags_usage ON n_tags(usage_count DESC, updated_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_post_tags_tag ON n_post_tags(tag_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_post_mentions_user ON n_post_mentions(mentioned_user_id, created_at DESC) TABLESPACE neko_index;

-- 通知、设置、账户
CREATE INDEX idx_notifications_user_created ON n_notifications(user_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_notifications_user_read_created ON n_notifications(user_id, is_read, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_notifications_actor ON n_notifications(actor_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_account_statements_user_status ON n_account_statements(user_id, status, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_statement_appeals_statement ON n_statement_appeals(statement_id, created_at DESC) TABLESPACE neko_index;

-- 群组索引（保留高频访问路径）
CREATE INDEX idx_groups_owner_id ON n_groups(owner_id) TABLESPACE neko_index;
CREATE INDEX idx_groups_privacy ON n_groups(privacy, is_active, is_deleted) TABLESPACE neko_index;
CREATE INDEX idx_groups_created_at ON n_groups(created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_groups_member_count ON n_groups(member_count DESC) TABLESPACE neko_index;
CREATE INDEX idx_groups_name_upper ON n_groups(UPPER(name)) TABLESPACE neko_index;

CREATE INDEX idx_group_members_user_id ON n_group_members(user_id) TABLESPACE neko_index;
CREATE INDEX idx_group_members_group_id ON n_group_members(group_id) TABLESPACE neko_index;
CREATE INDEX idx_group_members_group_status ON n_group_members(group_id, status) TABLESPACE neko_index;
CREATE INDEX idx_group_members_user_role ON n_group_members(user_id, role) TABLESPACE neko_index;

CREATE INDEX idx_group_posts_group_time ON n_group_posts(group_id, is_deleted, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_group_posts_group_pinned ON n_group_posts(group_id, is_pinned DESC, is_announcement DESC, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_group_posts_author_id ON n_group_posts(author_id) TABLESPACE neko_index;

CREATE INDEX idx_group_comments_post_id ON n_group_comments(post_id, is_deleted, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_group_comments_parent_id ON n_group_comments(parent_comment_id) TABLESPACE neko_index;
CREATE INDEX idx_group_comments_reply_to ON n_group_comments(reply_to_user_id) TABLESPACE neko_index;

CREATE INDEX idx_group_invites_group_id ON n_group_invites(group_id, status) TABLESPACE neko_index;
CREATE INDEX idx_group_invites_invitee_id ON n_group_invites(invitee_id, status) TABLESPACE neko_index;
CREATE INDEX idx_group_invites_code ON n_group_invites(invite_code) TABLESPACE neko_index;

CREATE INDEX idx_group_audit_logs_group_time ON n_group_audit_logs(group_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_group_audit_logs_actor_id ON n_group_audit_logs(actor_id, created_at DESC) TABLESPACE neko_index;

CREATE INDEX idx_group_post_likes_post_id ON n_group_post_likes(post_id) TABLESPACE neko_index;
CREATE INDEX idx_group_comment_likes_comment_id ON n_group_comment_likes(comment_id) TABLESPACE neko_index;

-- ==========================================
-- 7. 函数
-- ==========================================

-- 7.1 计算两个用户之间的关系
-- 返回值说明:
--   blocking      当前用户主动屏蔽了目标用户
--   blocked_by    当前用户被目标用户屏蔽
--   mutual_follow 双向关注
--   following     当前用户关注目标用户
--   followed_by   目标用户关注当前用户
--   none          无直接关系
CREATE OR REPLACE FUNCTION fn_get_user_relationship(
    p_viewer_id IN NUMBER,
    p_target_id IN NUMBER
) RETURN VARCHAR2
AS
    v_blocking_count   NUMBER := 0;
    v_blocked_by_count NUMBER := 0;
    v_following_count  NUMBER := 0;
    v_followed_by_count NUMBER := 0;
BEGIN
    IF p_viewer_id IS NULL OR p_target_id IS NULL THEN
        RETURN 'none';
    END IF;

    IF p_viewer_id = p_target_id THEN
        RETURN 'self';
    END IF;

    SELECT COUNT(*) INTO v_blocking_count
    FROM n_user_blocks
    WHERE user_id = p_viewer_id
      AND target_user_id = p_target_id;

    IF v_blocking_count > 0 THEN
        RETURN 'blocking';
    END IF;

    SELECT COUNT(*) INTO v_blocked_by_count
    FROM n_user_blocks
    WHERE user_id = p_target_id
      AND target_user_id = p_viewer_id;

    IF v_blocked_by_count > 0 THEN
        RETURN 'blocked_by';
    END IF;

    SELECT COUNT(*) INTO v_following_count
    FROM n_user_follows
    WHERE follower_id = p_viewer_id
      AND following_id = p_target_id
      AND status = 'active';

    SELECT COUNT(*) INTO v_followed_by_count
    FROM n_user_follows
    WHERE follower_id = p_target_id
      AND following_id = p_viewer_id
      AND status = 'active';

    IF v_following_count > 0 AND v_followed_by_count > 0 THEN
        RETURN 'mutual_follow';
    ELSIF v_following_count > 0 THEN
        RETURN 'following';
    ELSIF v_followed_by_count > 0 THEN
        RETURN 'followed_by';
    END IF;

    RETURN 'none';
EXCEPTION
    WHEN OTHERS THEN
        RETURN 'none';
END fn_get_user_relationship;
/

-- 7.2 安全版帖子热度计算函数
CREATE OR REPLACE FUNCTION fn_calculate_post_engagement_safe(
    p_likes_count       IN NUMBER DEFAULT 0,
    p_comments_count    IN NUMBER DEFAULT 0,
    p_replies_count     IN NUMBER DEFAULT 0,
    p_retweets_count    IN NUMBER DEFAULT 0,
    p_views_count       IN NUMBER DEFAULT 0,
    p_created_at        IN DATE
) RETURN NUMBER
AS
    v_likes        NUMBER := NVL(p_likes_count, 0);
    v_comments     NUMBER := NVL(p_comments_count, 0);
    v_replies      NUMBER := NVL(p_replies_count, 0);
    v_retweets     NUMBER := NVL(p_retweets_count, 0);
    v_views        NUMBER := NVL(p_views_count, 0);
    v_age_hours    NUMBER := 0;
    v_log_views    NUMBER := 0;
    v_score        NUMBER := 0;
BEGIN
    IF p_created_at IS NULL THEN
        RETURN 0;
    END IF;

    v_age_hours := GREATEST(ROUND((SYSDATE - p_created_at) * 24, 2), 0);

    IF v_views > 0 THEN
        v_log_views := ROUND(LN(v_views + 1) / LN(10), 4);
    END IF;

    v_score :=
        (
            v_likes * 1 +
            v_comments * 2 +
            v_replies * 2 +
            v_retweets * 3 +
            v_log_views * 0.2
        ) / POWER(v_age_hours + 1, 0.5);

    RETURN ROUND(v_score, 2);
EXCEPTION
    WHEN OTHERS THEN
        RETURN 0;
END fn_calculate_post_engagement_safe;
/

-- 7.3 检查当前用户是否有权限查看某条帖子
CREATE OR REPLACE FUNCTION fn_can_view_post(
    p_viewer_id IN NUMBER,
    p_post_id   IN NUMBER
) RETURN NUMBER
AS
    v_author_id    NUMBER;
    v_visibility   VARCHAR2(20);
    v_is_deleted   NUMBER;
    v_relation     VARCHAR2(50);
    v_mentioned    NUMBER := 0;
BEGIN
    SELECT author_id, visibility, is_deleted
    INTO v_author_id, v_visibility, v_is_deleted
    FROM n_posts
    WHERE post_id = p_post_id;

    IF v_is_deleted = 1 THEN
        RETURN 0;
    END IF;

    IF p_viewer_id = v_author_id THEN
        RETURN 1;
    END IF;

    v_relation := fn_get_user_relationship(p_viewer_id, v_author_id);

    IF v_relation IN ('blocking', 'blocked_by') THEN
        RETURN 0;
    END IF;

    IF v_visibility = 'public' THEN
        RETURN 1;
    ELSIF v_visibility = 'private' THEN
        RETURN 0;
    ELSIF v_visibility = 'followers' THEN
        RETURN CASE WHEN v_relation IN ('following', 'mutual_follow') THEN 1 ELSE 0 END;
    ELSIF v_visibility = 'mentioned' THEN
        SELECT COUNT(*) INTO v_mentioned
        FROM n_post_mentions
        WHERE post_id = p_post_id
          AND mentioned_user_id = p_viewer_id;
        RETURN CASE WHEN v_mentioned > 0 THEN 1 ELSE 0 END;
    END IF;

    RETURN 0;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN 0;
    WHEN OTHERS THEN
        RETURN 0;
END fn_can_view_post;
/

-- 7.4 获取未读通知数
CREATE OR REPLACE FUNCTION fn_get_unread_notification_count(
    p_user_id IN NUMBER
) RETURN NUMBER
AS
    v_count NUMBER := 0;
BEGIN
    SELECT COUNT(*)
    INTO v_count
    FROM n_notifications
    WHERE user_id = p_user_id
      AND is_read = 0
      AND deleted_at IS NULL;

    RETURN v_count;
EXCEPTION
    WHEN OTHERS THEN
        RETURN 0;
END fn_get_unread_notification_count;
/

-- 7.5 批量标记通知已读
CREATE OR REPLACE FUNCTION fn_mark_notifications_read(
    p_user_id IN NUMBER,
    p_notification_ids IN VARCHAR2 DEFAULT NULL
) RETURN NUMBER
AS
    v_count NUMBER := 0;
    v_sql   VARCHAR2(4000);
BEGIN
    IF p_notification_ids IS NULL THEN
        UPDATE n_notifications
        SET is_read = 1,
            read_at = CURRENT_TIMESTAMP
        WHERE user_id = p_user_id
          AND is_read = 0
          AND deleted_at IS NULL;

        v_count := SQL%ROWCOUNT;
    ELSE
        v_sql := 'UPDATE n_notifications
                  SET is_read = 1, read_at = CURRENT_TIMESTAMP
                  WHERE user_id = :1
                    AND is_read = 0
                    AND deleted_at IS NULL
                    AND notification_id IN (' || p_notification_ids || ')';

        EXECUTE IMMEDIATE v_sql USING p_user_id;
        v_count := SQL%ROWCOUNT;
    END IF;

    COMMIT;
    RETURN v_count;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RETURN 0;
END fn_mark_notifications_read;
/

-- 7.6 群组辅助函数：判断是否为活跃成员
CREATE OR REPLACE FUNCTION fn_is_group_member(
    p_user_id   IN NUMBER,
    p_group_id  IN NUMBER
) RETURN NUMBER
AS
    v_count NUMBER := 0;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM n_group_members
    WHERE user_id = p_user_id
      AND group_id = p_group_id
      AND status = 'active';

    RETURN CASE WHEN v_count > 0 THEN 1 ELSE 0 END;
END fn_is_group_member;
/

-- 7.7 群组辅助函数：获取成员角色
CREATE OR REPLACE FUNCTION fn_get_member_role(
    p_user_id   IN NUMBER,
    p_group_id  IN NUMBER
) RETURN VARCHAR2
AS
    v_role VARCHAR2(20);
BEGIN
    SELECT role INTO v_role
    FROM n_group_members
    WHERE user_id = p_user_id
      AND group_id = p_group_id
      AND status IN ('active', 'muted');

    RETURN v_role;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN NULL;
END fn_get_member_role;
/

-- 7.8 群组辅助函数：检查权限
CREATE OR REPLACE FUNCTION fn_has_group_permission(
    p_user_id         IN NUMBER,
    p_group_id        IN NUMBER,
    p_required_role   IN VARCHAR2
) RETURN NUMBER
AS
    v_user_role       VARCHAR2(20);
    v_user_level      NUMBER;
    v_required_level  NUMBER;
BEGIN
    v_user_role := fn_get_member_role(p_user_id, p_group_id);

    IF v_user_role IS NULL THEN
        RETURN 0;
    END IF;

    v_user_level := CASE v_user_role
        WHEN 'owner' THEN 4
        WHEN 'admin' THEN 3
        WHEN 'moderator' THEN 2
        WHEN 'member' THEN 1
        ELSE 0
    END;

    v_required_level := CASE p_required_role
        WHEN 'owner' THEN 4
        WHEN 'admin' THEN 3
        WHEN 'moderator' THEN 2
        WHEN 'member' THEN 1
        ELSE 0
    END;

    RETURN CASE WHEN v_user_level >= v_required_level THEN 1 ELSE 0 END;
END fn_has_group_permission;
/

-- 7.9 群组辅助函数：检查是否可查看群组
CREATE OR REPLACE FUNCTION fn_can_view_group(
    p_user_id   IN NUMBER,
    p_group_id  IN NUMBER
) RETURN NUMBER
AS
    v_privacy      VARCHAR2(20);
    v_is_active    NUMBER;
    v_is_deleted   NUMBER;
BEGIN
    SELECT privacy, is_active, is_deleted
    INTO v_privacy, v_is_active, v_is_deleted
    FROM n_groups
    WHERE group_id = p_group_id;

    IF v_is_deleted = 1 OR v_is_active = 0 THEN
        RETURN 0;
    END IF;

    IF v_privacy = 'public' THEN
        RETURN 1;
    END IF;

    RETURN fn_is_group_member(p_user_id, p_group_id);
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN 0;
END fn_can_view_group;
/

-- 7.10 群组辅助函数：检查是否可发帖
-- 修复点:
--   原版逻辑把 status != active 直接挡掉，导致 muted 状态下永远不会再走 mute_until 判断。
CREATE OR REPLACE FUNCTION fn_can_post_in_group(
    p_user_id   IN NUMBER,
    p_group_id  IN NUMBER
) RETURN NUMBER
AS
    v_post_permission  VARCHAR2(20);
    v_member_status    VARCHAR2(20);
    v_member_role      VARCHAR2(20);
    v_mute_until       TIMESTAMP;
BEGIN
    SELECT post_permission
    INTO v_post_permission
    FROM n_groups
    WHERE group_id = p_group_id
      AND is_active = 1
      AND is_deleted = 0;

    SELECT status, role, mute_until
    INTO v_member_status, v_member_role, v_mute_until
    FROM n_group_members
    WHERE user_id = p_user_id
      AND group_id = p_group_id;

    IF v_member_status = 'pending' OR v_member_status = 'banned' THEN
        RETURN 0;
    END IF;

    IF v_member_status = 'muted'
       AND v_mute_until IS NOT NULL
       AND v_mute_until > SYSTIMESTAMP THEN
        RETURN 0;
    END IF;

    IF v_post_permission = 'all' THEN
        RETURN 1;
    ELSIF v_post_permission = 'moderator_up' THEN
        RETURN fn_has_group_permission(p_user_id, p_group_id, 'moderator');
    ELSIF v_post_permission = 'admin_only' THEN
        RETURN fn_has_group_permission(p_user_id, p_group_id, 'admin');
    END IF;

    RETURN 0;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN 0;
END fn_can_post_in_group;
/

-- 7.11 群组辅助函数：检查是否可查看群组帖子
CREATE OR REPLACE FUNCTION fn_can_view_group_post(
    p_user_id   IN NUMBER,
    p_post_id   IN NUMBER
) RETURN NUMBER
AS
    v_group_id    NUMBER;
    v_is_deleted  NUMBER;
BEGIN
    SELECT group_id, is_deleted
    INTO v_group_id, v_is_deleted
    FROM n_group_posts
    WHERE post_id = p_post_id;

    IF v_is_deleted = 1 THEN
        RETURN 0;
    END IF;

    RETURN fn_can_view_group(p_user_id, v_group_id);
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN 0;
END fn_can_view_group_post;
/

-- 7.12 群组辅助函数：检查是否可管理成员
CREATE OR REPLACE FUNCTION fn_can_manage_member(
    p_actor_id    IN NUMBER,
    p_target_id   IN NUMBER,
    p_group_id    IN NUMBER
) RETURN NUMBER
AS
    v_actor_role    VARCHAR2(20);
    v_target_role   VARCHAR2(20);
    v_actor_level   NUMBER;
    v_target_level  NUMBER;
BEGIN
    v_actor_role := fn_get_member_role(p_actor_id, p_group_id);
    v_target_role := fn_get_member_role(p_target_id, p_group_id);

    IF v_actor_role IS NULL OR v_target_role IS NULL THEN
        RETURN 0;
    END IF;

    v_actor_level := CASE v_actor_role
        WHEN 'owner' THEN 4
        WHEN 'admin' THEN 3
        WHEN 'moderator' THEN 2
        WHEN 'member' THEN 1
        ELSE 0
    END;

    v_target_level := CASE v_target_role
        WHEN 'owner' THEN 4
        WHEN 'admin' THEN 3
        WHEN 'moderator' THEN 2
        WHEN 'member' THEN 1
        ELSE 0
    END;

    RETURN CASE WHEN v_actor_level >= 2 AND v_actor_level > v_target_level THEN 1 ELSE 0 END;
END fn_can_manage_member;
/

CREATE OR REPLACE FUNCTION fn_is_invite_valid(
    p_invite_code IN VARCHAR2
) RETURN NUMBER
AS
    v_status      VARCHAR2(20);
    v_max_uses    NUMBER;
    v_used_count  NUMBER;
    v_expires_at  TIMESTAMP;
BEGIN
    SELECT status, max_uses, used_count, expires_at
    INTO v_status, v_max_uses, v_used_count, v_expires_at
    FROM n_group_invites
    WHERE invite_code = p_invite_code;

    IF v_status != 'pending' THEN
        RETURN 0;
    END IF;

    IF v_max_uses IS NOT NULL AND v_used_count >= v_max_uses THEN
        RETURN 0;
    END IF;

    IF v_expires_at IS NOT NULL AND v_expires_at < SYSTIMESTAMP THEN
        RETURN 0;
    END IF;

    RETURN 1;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN 0;
END fn_is_invite_valid;
/

CREATE OR REPLACE FUNCTION fn_get_role_desc(
    p_role IN VARCHAR2
) RETURN VARCHAR2
AS
BEGIN
    RETURN CASE p_role
        WHEN 'owner' THEN '群主'
        WHEN 'admin' THEN '管理员'
        WHEN 'moderator' THEN '版主'
        WHEN 'member' THEN '成员'
        ELSE '未知'
    END;
END fn_get_role_desc;
/

CREATE OR REPLACE FUNCTION fn_get_member_status_desc(
    p_status IN VARCHAR2
) RETURN VARCHAR2
AS
BEGIN
    RETURN CASE p_status
        WHEN 'pending' THEN '待审核'
        WHEN 'active' THEN '正常'
        WHEN 'muted' THEN '禁言中'
        WHEN 'banned' THEN '已封禁'
        ELSE '未知'
    END;
END fn_get_member_status_desc;
/

CREATE OR REPLACE FUNCTION fn_get_privacy_desc(
    p_privacy IN VARCHAR2
) RETURN VARCHAR2
AS
BEGIN
    RETURN CASE p_privacy
        WHEN 'public' THEN '公开'
        WHEN 'private' THEN '私密'
        WHEN 'secret' THEN '隐秘'
        ELSE '未知'
    END;
END fn_get_privacy_desc;
/

CREATE OR REPLACE FUNCTION fn_generate_invite_code
RETURN VARCHAR2
AS
    v_code VARCHAR2(32);
BEGIN
    SELECT DBMS_RANDOM.STRING('X', 32) INTO v_code FROM DUAL;
    RETURN v_code;
END fn_generate_invite_code;
/

CREATE OR REPLACE FUNCTION fn_generate_group_slug(
    p_name IN VARCHAR2
) RETURN VARCHAR2
AS
    v_slug    VARCHAR2(100);
    v_count   NUMBER := 0;
    v_suffix  NUMBER := 0;
BEGIN
    v_slug := LOWER(REGEXP_REPLACE(p_name, '[^a-zA-Z0-9\u4e00-\u9fa5]', '-'));
    v_slug := REGEXP_REPLACE(v_slug, '-+', '-');
    v_slug := TRIM(BOTH '-' FROM v_slug);

    IF v_slug IS NULL OR LENGTH(v_slug) = 0 THEN
        v_slug := 'group-' || TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF3');
    END IF;

    LOOP
        IF v_suffix = 0 THEN
            SELECT COUNT(*) INTO v_count FROM n_groups WHERE slug = v_slug;
        ELSE
            SELECT COUNT(*) INTO v_count FROM n_groups WHERE slug = v_slug || '-' || v_suffix;
        END IF;

        EXIT WHEN v_count = 0;
        v_suffix := v_suffix + 1;
    END LOOP;

    IF v_suffix > 0 THEN
        v_slug := v_slug || '-' || v_suffix;
    END IF;

    RETURN SUBSTR(v_slug, 1, 100);
END fn_generate_group_slug;
/

-- ==========================================
-- 8. 触发器
-- ==========================================

-- 8.1 主键 / 默认值触发器
CREATE OR REPLACE TRIGGER trg_users_pk
BEFORE INSERT ON n_users
FOR EACH ROW
WHEN (NEW.user_id IS NULL)
BEGIN
    SELECT seq_user_id.NEXTVAL INTO :NEW.user_id FROM dual;
END;
/

CREATE OR REPLACE TRIGGER trg_otp_events_pk
BEFORE INSERT ON n_auth_otp_events
FOR EACH ROW
WHEN (NEW.otp_event_id IS NULL)
BEGIN
    SELECT seq_otp_event_id.NEXTVAL INTO :NEW.otp_event_id FROM dual;
END;
/

CREATE OR REPLACE TRIGGER trg_follows_pk
BEFORE INSERT ON n_user_follows
FOR EACH ROW
WHEN (NEW.follow_id IS NULL)
BEGIN
    SELECT seq_follow_id.NEXTVAL INTO :NEW.follow_id FROM dual;
END;
/

CREATE OR REPLACE TRIGGER trg_blocks_pk
BEFORE INSERT ON n_user_blocks
FOR EACH ROW
WHEN (NEW.block_id IS NULL)
BEGIN
    SELECT seq_block_id.NEXTVAL INTO :NEW.block_id FROM dual;
END;
/

CREATE OR REPLACE TRIGGER trg_mutes_pk
BEFORE INSERT ON n_user_mutes
FOR EACH ROW
WHEN (NEW.mute_id IS NULL)
BEGIN
    SELECT seq_mute_id.NEXTVAL INTO :NEW.mute_id FROM dual;
END;
/

CREATE OR REPLACE TRIGGER trg_posts_pk
BEFORE INSERT ON n_posts
FOR EACH ROW
WHEN (NEW.post_id IS NULL)
BEGIN
    SELECT seq_post_id.NEXTVAL INTO :NEW.post_id FROM dual;
END;
/

CREATE OR REPLACE TRIGGER trg_post_likes_pk
BEFORE INSERT ON n_post_likes
FOR EACH ROW
WHEN (NEW.post_like_id IS NULL)
BEGIN
    SELECT seq_post_like_id.NEXTVAL INTO :NEW.post_like_id FROM dual;
END;
/

CREATE OR REPLACE TRIGGER trg_post_bookmarks_pk
BEFORE INSERT ON n_post_bookmarks
FOR EACH ROW
WHEN (NEW.bookmark_id IS NULL)
BEGIN
    SELECT seq_post_bookmark_id.NEXTVAL INTO :NEW.bookmark_id FROM dual;
END;
/

CREATE OR REPLACE TRIGGER trg_comments_pk
BEFORE INSERT ON n_comments
FOR EACH ROW
WHEN (NEW.comment_id IS NULL)
BEGIN
    SELECT seq_comment_id.NEXTVAL INTO :NEW.comment_id FROM dual;
END;
/

CREATE OR REPLACE TRIGGER trg_comment_likes_pk
BEFORE INSERT ON n_comment_likes
FOR EACH ROW
WHEN (NEW.comment_like_id IS NULL)
BEGIN
    SELECT seq_comment_like_id.NEXTVAL INTO :NEW.comment_like_id FROM dual;
END;
/

CREATE OR REPLACE TRIGGER trg_media_assets_pk
BEFORE INSERT ON n_media_assets
FOR EACH ROW
WHEN (NEW.media_id IS NULL)
BEGIN
    SELECT seq_media_id.NEXTVAL INTO :NEW.media_id FROM dual;
END;
/

CREATE OR REPLACE TRIGGER trg_tags_pk
BEFORE INSERT ON n_tags
FOR EACH ROW
WHEN (NEW.tag_id IS NULL)
BEGIN
    SELECT seq_tag_id.NEXTVAL INTO :NEW.tag_id FROM dual;
END;
/

CREATE OR REPLACE TRIGGER trg_notifications_pk
BEFORE INSERT ON n_notifications
FOR EACH ROW
WHEN (NEW.notification_id IS NULL)
BEGIN
    SELECT seq_notification_id.NEXTVAL INTO :NEW.notification_id FROM dual;
END;
/

CREATE OR REPLACE TRIGGER trg_account_statements_pk
BEFORE INSERT ON n_account_statements
FOR EACH ROW
WHEN (NEW.statement_id IS NULL)
BEGIN
    SELECT seq_statement_id.NEXTVAL INTO :NEW.statement_id FROM dual;
END;
/

CREATE OR REPLACE TRIGGER trg_statement_appeals_pk
BEFORE INSERT ON n_statement_appeals
FOR EACH ROW
WHEN (NEW.appeal_id IS NULL)
BEGIN
    SELECT seq_statement_appeal_id.NEXTVAL INTO :NEW.appeal_id FROM dual;
END;
/

-- 8.2 用户与会话触发器
CREATE OR REPLACE TRIGGER trg_users_audit
BEFORE INSERT OR UPDATE ON n_users
FOR EACH ROW
BEGIN
    IF INSERTING AND :NEW.created_at IS NULL THEN
        :NEW.created_at := CURRENT_TIMESTAMP;
    END IF;

    :NEW.updated_at := CURRENT_TIMESTAMP;
    :NEW.updated_by := USER;

    IF :NEW.status = 'active' THEN
        :NEW.is_active := 1;
    ELSE
        :NEW.is_active := 0;
    END IF;

    IF :NEW.avatar_url IS NULL THEN
        :NEW.avatar_url := '/default-avatar.png';
    END IF;
END;
/

-- 新用户初始化:
--   1. 生成统计行
--   2. 生成默认设置
--   3. 生成默认通知偏好
CREATE OR REPLACE TRIGGER trg_users_init
AFTER INSERT ON n_users
FOR EACH ROW
BEGIN
    INSERT INTO n_user_stats (user_id) VALUES (:NEW.user_id);
    INSERT INTO n_user_settings (user_id) VALUES (:NEW.user_id);

    INSERT INTO n_notification_preferences (user_id, notification_type, is_enabled) VALUES (:NEW.user_id, 'like', 1);
    INSERT INTO n_notification_preferences (user_id, notification_type, is_enabled) VALUES (:NEW.user_id, 'comment', 1);
    INSERT INTO n_notification_preferences (user_id, notification_type, is_enabled) VALUES (:NEW.user_id, 'reply', 1);
    INSERT INTO n_notification_preferences (user_id, notification_type, is_enabled) VALUES (:NEW.user_id, 'follow', 1);
    INSERT INTO n_notification_preferences (user_id, notification_type, is_enabled) VALUES (:NEW.user_id, 'mention', 1);
    INSERT INTO n_notification_preferences (user_id, notification_type, is_enabled) VALUES (:NEW.user_id, 'system', 1);
    INSERT INTO n_notification_preferences (user_id, notification_type, is_enabled) VALUES (:NEW.user_id, 'group_invite', 1);
    INSERT INTO n_notification_preferences (user_id, notification_type, is_enabled) VALUES (:NEW.user_id, 'group_post', 1);
END;
/

CREATE OR REPLACE TRIGGER trg_auth_sessions_defaults
BEFORE INSERT ON n_auth_sessions
FOR EACH ROW
BEGIN
    IF :NEW.session_id IS NULL THEN
        :NEW.session_id := RAWTOHEX(SYS_GUID());
    END IF;

    IF :NEW.access_jti IS NULL THEN
        :NEW.access_jti := RAWTOHEX(SYS_GUID());
    END IF;

    IF :NEW.last_accessed_at IS NULL THEN
        :NEW.last_accessed_at := CURRENT_TIMESTAMP;
    END IF;
END;
/

-- 8.3 关注计数触发器
CREATE OR REPLACE TRIGGER trg_user_follows_stats
AFTER INSERT OR UPDATE OF status ON n_user_follows
FOR EACH ROW
BEGIN
    IF INSERTING AND :NEW.status = 'active' THEN
        UPDATE n_user_stats
        SET following_count = following_count + 1,
            updated_at = CURRENT_TIMESTAMP
        WHERE user_id = :NEW.follower_id;

        UPDATE n_user_stats
        SET followers_count = followers_count + 1,
            updated_at = CURRENT_TIMESTAMP
        WHERE user_id = :NEW.following_id;
    ELSIF UPDATING THEN
        IF :OLD.status != 'active' AND :NEW.status = 'active' THEN
            UPDATE n_user_stats
            SET following_count = following_count + 1,
                updated_at = CURRENT_TIMESTAMP
            WHERE user_id = :NEW.follower_id;

            UPDATE n_user_stats
            SET followers_count = followers_count + 1,
                updated_at = CURRENT_TIMESTAMP
            WHERE user_id = :NEW.following_id;
        ELSIF :OLD.status = 'active' AND :NEW.status != 'active' THEN
            UPDATE n_user_stats
            SET following_count = GREATEST(following_count - 1, 0),
                updated_at = CURRENT_TIMESTAMP
            WHERE user_id = :NEW.follower_id;

            UPDATE n_user_stats
            SET followers_count = GREATEST(followers_count - 1, 0),
                updated_at = CURRENT_TIMESTAMP
            WHERE user_id = :NEW.following_id;
        END IF;
    END IF;
END;
/

-- 8.4 帖子与统计触发器
CREATE OR REPLACE TRIGGER trg_posts_audit
BEFORE INSERT OR UPDATE ON n_posts
FOR EACH ROW
BEGIN
    IF INSERTING AND :NEW.created_at IS NULL THEN
        :NEW.created_at := CURRENT_TIMESTAMP;
    END IF;

    :NEW.updated_at := CURRENT_TIMESTAMP;
    :NEW.updated_by := USER;

    IF :NEW.is_deleted = 1 AND :NEW.deleted_at IS NULL THEN
        :NEW.deleted_at := CURRENT_TIMESTAMP;
    ELSIF :NEW.is_deleted = 0 THEN
        :NEW.deleted_at := NULL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_posts_init
AFTER INSERT ON n_posts
FOR EACH ROW
BEGIN
    INSERT INTO n_post_stats (post_id) VALUES (:NEW.post_id);

    IF :NEW.is_deleted = 0 THEN
        UPDATE n_user_stats
        SET posts_count = posts_count + 1,
            updated_at = CURRENT_TIMESTAMP
        WHERE user_id = :NEW.author_id;

        IF :NEW.reply_to_post_id IS NOT NULL THEN
            UPDATE n_post_stats
            SET replies_count = replies_count + 1,
                updated_at = CURRENT_TIMESTAMP
            WHERE post_id = :NEW.reply_to_post_id;
        END IF;

        IF :NEW.repost_of_post_id IS NOT NULL THEN
            UPDATE n_post_stats
            SET retweets_count = retweets_count + 1,
                updated_at = CURRENT_TIMESTAMP
            WHERE post_id = :NEW.repost_of_post_id;
        END IF;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_posts_delete_stats
AFTER UPDATE OF is_deleted ON n_posts
FOR EACH ROW
BEGIN
    IF :OLD.is_deleted = 0 AND :NEW.is_deleted = 1 THEN
        UPDATE n_user_stats
        SET posts_count = GREATEST(posts_count - 1, 0),
            updated_at = CURRENT_TIMESTAMP
        WHERE user_id = :NEW.author_id;

        IF :NEW.reply_to_post_id IS NOT NULL THEN
            UPDATE n_post_stats
            SET replies_count = GREATEST(replies_count - 1, 0),
                updated_at = CURRENT_TIMESTAMP
            WHERE post_id = :NEW.reply_to_post_id;
        END IF;

        IF :NEW.repost_of_post_id IS NOT NULL THEN
            UPDATE n_post_stats
            SET retweets_count = GREATEST(retweets_count - 1, 0),
                updated_at = CURRENT_TIMESTAMP
            WHERE post_id = :NEW.repost_of_post_id;
        END IF;
    ELSIF :OLD.is_deleted = 1 AND :NEW.is_deleted = 0 THEN
        UPDATE n_user_stats
        SET posts_count = posts_count + 1,
            updated_at = CURRENT_TIMESTAMP
        WHERE user_id = :NEW.author_id;

        IF :NEW.reply_to_post_id IS NOT NULL THEN
            UPDATE n_post_stats
            SET replies_count = replies_count + 1,
                updated_at = CURRENT_TIMESTAMP
            WHERE post_id = :NEW.reply_to_post_id;
        END IF;

        IF :NEW.repost_of_post_id IS NOT NULL THEN
            UPDATE n_post_stats
            SET retweets_count = retweets_count + 1,
                updated_at = CURRENT_TIMESTAMP
            WHERE post_id = :NEW.repost_of_post_id;
        END IF;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_post_likes_stats
AFTER INSERT OR DELETE ON n_post_likes
FOR EACH ROW
DECLARE
    v_author_id NUMBER;
BEGIN
    IF INSERTING THEN
        UPDATE n_post_stats
        SET likes_count = likes_count + 1,
            engagement_score = fn_calculate_post_engagement_safe(
                likes_count + 1,
                comments_count,
                replies_count,
                retweets_count,
                views_count,
                (SELECT created_at FROM n_posts WHERE post_id = :NEW.post_id)
            ),
            updated_at = CURRENT_TIMESTAMP
        WHERE post_id = :NEW.post_id;

        SELECT author_id INTO v_author_id FROM n_posts WHERE post_id = :NEW.post_id;
        UPDATE n_user_stats
        SET likes_count = likes_count + 1,
            updated_at = CURRENT_TIMESTAMP
        WHERE user_id = v_author_id;
    ELSIF DELETING THEN
        UPDATE n_post_stats
        SET likes_count = GREATEST(likes_count - 1, 0),
            engagement_score = fn_calculate_post_engagement_safe(
                GREATEST(likes_count - 1, 0),
                comments_count,
                replies_count,
                retweets_count,
                views_count,
                (SELECT created_at FROM n_posts WHERE post_id = :OLD.post_id)
            ),
            updated_at = CURRENT_TIMESTAMP
        WHERE post_id = :OLD.post_id;

        SELECT author_id INTO v_author_id FROM n_posts WHERE post_id = :OLD.post_id;
        UPDATE n_user_stats
        SET likes_count = GREATEST(likes_count - 1, 0),
            updated_at = CURRENT_TIMESTAMP
        WHERE user_id = v_author_id;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_post_bookmarks_stats
AFTER INSERT OR DELETE ON n_post_bookmarks
FOR EACH ROW
BEGIN
    IF INSERTING THEN
        UPDATE n_user_stats
        SET bookmarks_count = bookmarks_count + 1,
            updated_at = CURRENT_TIMESTAMP
        WHERE user_id = :NEW.user_id;
    ELSIF DELETING THEN
        UPDATE n_user_stats
        SET bookmarks_count = GREATEST(bookmarks_count - 1, 0),
            updated_at = CURRENT_TIMESTAMP
        WHERE user_id = :OLD.user_id;
    END IF;
END;
/

-- 8.5 评论触发器
CREATE OR REPLACE TRIGGER trg_comments_audit
BEFORE INSERT OR UPDATE ON n_comments
FOR EACH ROW
BEGIN
    IF INSERTING THEN
        -- 这里不在行级触发器中查询 n_comments 本表，避免 Oracle mutating table 风险。
        -- 如果调用层已经明确传 root_comment_id，则以调用层为准；
        -- 如果没有传，就先把根节点设置为父评论，满足大多数评论树查询起步需求。
        IF :NEW.parent_comment_id IS NOT NULL AND :NEW.root_comment_id IS NULL THEN
            :NEW.root_comment_id := :NEW.parent_comment_id;
        ELSIF :NEW.parent_comment_id IS NULL AND :NEW.root_comment_id IS NULL THEN
            :NEW.root_comment_id := NULL;
        END IF;
    END IF;

    :NEW.updated_at := CURRENT_TIMESTAMP;

    IF :NEW.is_deleted = 1 AND :NEW.deleted_at IS NULL THEN
        :NEW.deleted_at := CURRENT_TIMESTAMP;
    ELSIF :NEW.is_deleted = 0 THEN
        :NEW.deleted_at := NULL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_comments_init
AFTER INSERT ON n_comments
FOR EACH ROW
BEGIN
    INSERT INTO n_comment_stats (comment_id) VALUES (:NEW.comment_id);

    IF :NEW.is_deleted = 0 THEN
        UPDATE n_post_stats
        SET comments_count = comments_count + 1,
            engagement_score = fn_calculate_post_engagement_safe(
                likes_count,
                comments_count + 1,
                replies_count,
                retweets_count,
                views_count,
                (SELECT created_at FROM n_posts WHERE post_id = :NEW.post_id)
            ),
            updated_at = CURRENT_TIMESTAMP
        WHERE post_id = :NEW.post_id;

        UPDATE n_user_stats
        SET comments_count = comments_count + 1,
            updated_at = CURRENT_TIMESTAMP
        WHERE user_id = :NEW.user_id;

        IF :NEW.parent_comment_id IS NOT NULL THEN
            UPDATE n_comment_stats
            SET replies_count = replies_count + 1,
                updated_at = CURRENT_TIMESTAMP
            WHERE comment_id = :NEW.parent_comment_id;
        END IF;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_comments_delete_stats
AFTER UPDATE OF is_deleted ON n_comments
FOR EACH ROW
BEGIN
    IF :OLD.is_deleted = 0 AND :NEW.is_deleted = 1 THEN
        UPDATE n_post_stats
        SET comments_count = GREATEST(comments_count - 1, 0),
            engagement_score = fn_calculate_post_engagement_safe(
                likes_count,
                GREATEST(comments_count - 1, 0),
                replies_count,
                retweets_count,
                views_count,
                (SELECT created_at FROM n_posts WHERE post_id = :NEW.post_id)
            ),
            updated_at = CURRENT_TIMESTAMP
        WHERE post_id = :NEW.post_id;

        UPDATE n_user_stats
        SET comments_count = GREATEST(comments_count - 1, 0),
            updated_at = CURRENT_TIMESTAMP
        WHERE user_id = :NEW.user_id;

        IF :NEW.parent_comment_id IS NOT NULL THEN
            UPDATE n_comment_stats
            SET replies_count = GREATEST(replies_count - 1, 0),
                updated_at = CURRENT_TIMESTAMP
            WHERE comment_id = :NEW.parent_comment_id;
        END IF;
    ELSIF :OLD.is_deleted = 1 AND :NEW.is_deleted = 0 THEN
        UPDATE n_post_stats
        SET comments_count = comments_count + 1,
            engagement_score = fn_calculate_post_engagement_safe(
                likes_count,
                comments_count + 1,
                replies_count,
                retweets_count,
                views_count,
                (SELECT created_at FROM n_posts WHERE post_id = :NEW.post_id)
            ),
            updated_at = CURRENT_TIMESTAMP
        WHERE post_id = :NEW.post_id;

        UPDATE n_user_stats
        SET comments_count = comments_count + 1,
            updated_at = CURRENT_TIMESTAMP
        WHERE user_id = :NEW.user_id;

        IF :NEW.parent_comment_id IS NOT NULL THEN
            UPDATE n_comment_stats
            SET replies_count = replies_count + 1,
                updated_at = CURRENT_TIMESTAMP
            WHERE comment_id = :NEW.parent_comment_id;
        END IF;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_comment_likes_stats
AFTER INSERT OR DELETE ON n_comment_likes
FOR EACH ROW
BEGIN
    IF INSERTING THEN
        UPDATE n_comment_stats
        SET likes_count = likes_count + 1,
            updated_at = CURRENT_TIMESTAMP
        WHERE comment_id = :NEW.comment_id;
    ELSIF DELETING THEN
        UPDATE n_comment_stats
        SET likes_count = GREATEST(likes_count - 1, 0),
            updated_at = CURRENT_TIMESTAMP
        WHERE comment_id = :OLD.comment_id;
    END IF;
END;
/

-- 8.6 标签使用统计触发器
CREATE OR REPLACE TRIGGER trg_post_tags_usage
AFTER INSERT OR DELETE ON n_post_tags
FOR EACH ROW
BEGIN
    IF INSERTING THEN
        UPDATE n_tags
        SET usage_count = usage_count + 1,
            updated_at = CURRENT_TIMESTAMP
        WHERE tag_id = :NEW.tag_id;
    ELSIF DELETING THEN
        UPDATE n_tags
        SET usage_count = GREATEST(usage_count - 1, 0),
            updated_at = CURRENT_TIMESTAMP
        WHERE tag_id = :OLD.tag_id;
    END IF;
END;
/

-- 8.7 通知触发器
CREATE OR REPLACE TRIGGER trg_notifications_read
BEFORE INSERT OR UPDATE ON n_notifications
FOR EACH ROW
BEGIN
    IF INSERTING AND :NEW.is_read = 1 AND :NEW.read_at IS NULL THEN
        :NEW.read_at := CURRENT_TIMESTAMP;
    ELSIF UPDATING THEN
        IF :OLD.is_read = 0 AND :NEW.is_read = 1 AND :NEW.read_at IS NULL THEN
            :NEW.read_at := CURRENT_TIMESTAMP;
        ELSIF :OLD.is_read = 1 AND :NEW.is_read = 0 THEN
            :NEW.read_at := NULL;
        END IF;
    END IF;
END;
/

-- 8.7.1 通用 updated_at 触发器
CREATE OR REPLACE TRIGGER trg_tags_updated_at
BEFORE UPDATE ON n_tags
FOR EACH ROW
BEGIN
    :NEW.updated_at := CURRENT_TIMESTAMP;
END;
/

CREATE OR REPLACE TRIGGER trg_user_settings_updated_at
BEFORE UPDATE ON n_user_settings
FOR EACH ROW
BEGIN
    :NEW.updated_at := CURRENT_TIMESTAMP;
END;
/

CREATE OR REPLACE TRIGGER trg_user_follows_updated_at
BEFORE UPDATE ON n_user_follows
FOR EACH ROW
BEGIN
    :NEW.updated_at := CURRENT_TIMESTAMP;
END;
/

CREATE OR REPLACE TRIGGER trg_account_statements_updated_at
BEFORE UPDATE ON n_account_statements
FOR EACH ROW
BEGIN
    :NEW.updated_at := CURRENT_TIMESTAMP;
END;
/

CREATE OR REPLACE TRIGGER trg_statement_appeals_updated_at
BEFORE UPDATE ON n_statement_appeals
FOR EACH ROW
BEGIN
    :NEW.updated_at := CURRENT_TIMESTAMP;
END;
/

-- 8.8 群组主键触发器
CREATE OR REPLACE TRIGGER trg_groups_id
BEFORE INSERT ON n_groups
FOR EACH ROW
BEGIN
    IF :NEW.group_id IS NULL THEN
        :NEW.group_id := seq_group_id.NEXTVAL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_group_members_id
BEFORE INSERT ON n_group_members
FOR EACH ROW
BEGIN
    IF :NEW.member_id IS NULL THEN
        :NEW.member_id := seq_group_member_id.NEXTVAL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_group_posts_id
BEFORE INSERT ON n_group_posts
FOR EACH ROW
BEGIN
    IF :NEW.post_id IS NULL THEN
        :NEW.post_id := seq_group_post_id.NEXTVAL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_group_comments_id
BEFORE INSERT ON n_group_comments
FOR EACH ROW
BEGIN
    IF :NEW.comment_id IS NULL THEN
        :NEW.comment_id := seq_group_comment_id.NEXTVAL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_group_invites_id
BEFORE INSERT ON n_group_invites
FOR EACH ROW
BEGIN
    IF :NEW.invite_id IS NULL THEN
        :NEW.invite_id := seq_group_invite_id.NEXTVAL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_group_audit_logs_id
BEFORE INSERT ON n_group_audit_logs
FOR EACH ROW
BEGIN
    IF :NEW.log_id IS NULL THEN
        :NEW.log_id := seq_group_audit_log_id.NEXTVAL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_group_post_likes_id
BEFORE INSERT ON n_group_post_likes
FOR EACH ROW
BEGIN
    IF :NEW.like_id IS NULL THEN
        :NEW.like_id := seq_group_post_like_id.NEXTVAL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_group_comment_likes_id
BEFORE INSERT ON n_group_comment_likes
FOR EACH ROW
BEGIN
    IF :NEW.like_id IS NULL THEN
        :NEW.like_id := seq_group_comment_like_id.NEXTVAL;
    END IF;
END;
/

-- 8.9 群组更新时间触发器
CREATE OR REPLACE TRIGGER trg_groups_updated_at
BEFORE UPDATE ON n_groups
FOR EACH ROW
BEGIN
    :NEW.updated_at := SYSTIMESTAMP;
END;
/

CREATE OR REPLACE TRIGGER trg_group_members_updated_at
BEFORE UPDATE ON n_group_members
FOR EACH ROW
BEGIN
    :NEW.updated_at := SYSTIMESTAMP;
END;
/

CREATE OR REPLACE TRIGGER trg_group_posts_updated_at
BEFORE UPDATE ON n_group_posts
FOR EACH ROW
BEGIN
    :NEW.updated_at := SYSTIMESTAMP;
END;
/

CREATE OR REPLACE TRIGGER trg_group_comments_updated_at
BEFORE UPDATE ON n_group_comments
FOR EACH ROW
BEGIN
    :NEW.updated_at := SYSTIMESTAMP;
END;
/

-- 8.10 群组计数触发器
CREATE OR REPLACE TRIGGER trg_group_member_count_inc
AFTER INSERT ON n_group_members
FOR EACH ROW
WHEN (NEW.status = 'active')
BEGIN
    UPDATE n_groups
    SET member_count = member_count + 1
    WHERE group_id = :NEW.group_id;
END;
/

CREATE OR REPLACE TRIGGER trg_group_member_count_update
AFTER UPDATE OF status ON n_group_members
FOR EACH ROW
BEGIN
    IF :OLD.status != 'active' AND :NEW.status = 'active' THEN
        UPDATE n_groups
        SET member_count = member_count + 1
        WHERE group_id = :NEW.group_id;
    ELSIF :OLD.status = 'active' AND :NEW.status != 'active' THEN
        UPDATE n_groups
        SET member_count = GREATEST(member_count - 1, 0)
        WHERE group_id = :NEW.group_id;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_group_member_count_dec
AFTER DELETE ON n_group_members
FOR EACH ROW
WHEN (OLD.status = 'active')
BEGIN
    UPDATE n_groups
    SET member_count = GREATEST(member_count - 1, 0)
    WHERE group_id = :OLD.group_id;
END;
/

CREATE OR REPLACE TRIGGER trg_group_post_count_inc
AFTER INSERT ON n_group_posts
FOR EACH ROW
WHEN (NEW.is_deleted = 0)
BEGIN
    UPDATE n_groups
    SET post_count = post_count + 1
    WHERE group_id = :NEW.group_id;
END;
/

CREATE OR REPLACE TRIGGER trg_group_post_count_update
AFTER UPDATE OF is_deleted ON n_group_posts
FOR EACH ROW
BEGIN
    IF :OLD.is_deleted = 0 AND :NEW.is_deleted = 1 THEN
        UPDATE n_groups
        SET post_count = GREATEST(post_count - 1, 0)
        WHERE group_id = :NEW.group_id;
    ELSIF :OLD.is_deleted = 1 AND :NEW.is_deleted = 0 THEN
        UPDATE n_groups
        SET post_count = post_count + 1
        WHERE group_id = :NEW.group_id;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_group_post_count_dec
AFTER DELETE ON n_group_posts
FOR EACH ROW
WHEN (OLD.is_deleted = 0)
BEGIN
    UPDATE n_groups
    SET post_count = GREATEST(post_count - 1, 0)
    WHERE group_id = :OLD.group_id;
END;
/

CREATE OR REPLACE TRIGGER trg_group_post_likes_count_inc
AFTER INSERT ON n_group_post_likes
FOR EACH ROW
BEGIN
    UPDATE n_group_posts
    SET likes_count = likes_count + 1
    WHERE post_id = :NEW.post_id;
END;
/

CREATE OR REPLACE TRIGGER trg_group_post_likes_count_dec
AFTER DELETE ON n_group_post_likes
FOR EACH ROW
BEGIN
    UPDATE n_group_posts
    SET likes_count = GREATEST(likes_count - 1, 0)
    WHERE post_id = :OLD.post_id;
END;
/

CREATE OR REPLACE TRIGGER trg_group_post_comments_count_inc
AFTER INSERT ON n_group_comments
FOR EACH ROW
WHEN (NEW.is_deleted = 0)
BEGIN
    UPDATE n_group_posts
    SET comments_count = comments_count + 1
    WHERE post_id = :NEW.post_id;
END;
/

CREATE OR REPLACE TRIGGER trg_group_post_comments_count_update
AFTER UPDATE OF is_deleted ON n_group_comments
FOR EACH ROW
BEGIN
    IF :OLD.is_deleted = 0 AND :NEW.is_deleted = 1 THEN
        UPDATE n_group_posts
        SET comments_count = GREATEST(comments_count - 1, 0)
        WHERE post_id = :NEW.post_id;
    ELSIF :OLD.is_deleted = 1 AND :NEW.is_deleted = 0 THEN
        UPDATE n_group_posts
        SET comments_count = comments_count + 1
        WHERE post_id = :NEW.post_id;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_group_post_comments_count_dec
AFTER DELETE ON n_group_comments
FOR EACH ROW
WHEN (OLD.is_deleted = 0)
BEGIN
    UPDATE n_group_posts
    SET comments_count = GREATEST(comments_count - 1, 0)
    WHERE post_id = :OLD.post_id;
END;
/

CREATE OR REPLACE TRIGGER trg_group_comment_likes_count_inc
AFTER INSERT ON n_group_comment_likes
FOR EACH ROW
BEGIN
    UPDATE n_group_comments
    SET likes_count = likes_count + 1
    WHERE comment_id = :NEW.comment_id;
END;
/

CREATE OR REPLACE TRIGGER trg_group_comment_likes_count_dec
AFTER DELETE ON n_group_comment_likes
FOR EACH ROW
BEGIN
    UPDATE n_group_comments
    SET likes_count = GREATEST(likes_count - 1, 0)
    WHERE comment_id = :OLD.comment_id;
END;
/

-- ==========================================
-- 9. 过程
-- ==========================================

-- 9.1 创建通知
CREATE OR REPLACE PROCEDURE sp_create_notification(
    p_user_id        IN NUMBER,
    p_type           IN VARCHAR2,
    p_title          IN VARCHAR2,
    p_message        IN VARCHAR2,
    p_resource_type  IN VARCHAR2 DEFAULT NULL,
    p_resource_id    IN NUMBER DEFAULT NULL,
    p_actor_id       IN NUMBER DEFAULT NULL,
    p_priority       IN VARCHAR2 DEFAULT 'normal',
    p_result         OUT VARCHAR2
)
AS
    v_allowed NUMBER := 1;
    v_notification_id NUMBER;
BEGIN
    -- system 通知默认允许，其余通知走用户偏好；没配置时视为允许
    BEGIN
        SELECT is_enabled INTO v_allowed
        FROM n_notification_preferences
        WHERE user_id = p_user_id
          AND notification_type = p_type;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            v_allowed := 1;
    END;

    IF v_allowed = 0 THEN
        p_result := 'SKIPPED: 用户已关闭此类通知';
        RETURN;
    END IF;

    IF p_actor_id = p_user_id AND p_type != 'system' THEN
        p_result := 'SKIPPED: 不能给自己发送通知';
        RETURN;
    END IF;

    INSERT INTO n_notifications (
        user_id,
        actor_id,
        type,
        title,
        message,
        resource_type,
        resource_id,
        priority
    ) VALUES (
        p_user_id,
        p_actor_id,
        p_type,
        p_title,
        p_message,
        p_resource_type,
        p_resource_id,
        p_priority
    ) RETURNING notification_id INTO v_notification_id;

    COMMIT;
    p_result := 'SUCCESS: 通知创建成功，ID=' || v_notification_id;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_create_notification;
/

-- 9.2 批量创建通知
CREATE OR REPLACE PROCEDURE sp_batch_create_notifications(
    p_user_ids       IN VARCHAR2,
    p_type           IN VARCHAR2,
    p_title          IN VARCHAR2,
    p_message        IN VARCHAR2,
    p_resource_type  IN VARCHAR2 DEFAULT NULL,
    p_resource_id    IN NUMBER DEFAULT NULL,
    p_actor_id       IN NUMBER DEFAULT NULL,
    p_priority       IN VARCHAR2 DEFAULT 'normal',
    p_result         OUT VARCHAR2
)
AS
    v_user_id          NUMBER;
    v_success_count    NUMBER := 0;
    v_failed_count     NUMBER := 0;
    v_pos              NUMBER := 1;
    v_next_pos         NUMBER;
    v_user_id_str      VARCHAR2(50);
    v_single_result    VARCHAR2(500);
BEGIN
    WHILE v_pos <= LENGTH(p_user_ids) LOOP
        v_next_pos := INSTR(p_user_ids, ',', v_pos);

        IF v_next_pos = 0 THEN
            v_user_id_str := SUBSTR(p_user_ids, v_pos);
        ELSE
            v_user_id_str := SUBSTR(p_user_ids, v_pos, v_next_pos - v_pos);
        END IF;

        BEGIN
            v_user_id := TO_NUMBER(TRIM(v_user_id_str));

            sp_create_notification(
                p_user_id       => v_user_id,
                p_type          => p_type,
                p_title         => p_title,
                p_message       => p_message,
                p_resource_type => p_resource_type,
                p_resource_id   => p_resource_id,
                p_actor_id      => p_actor_id,
                p_priority      => p_priority,
                p_result        => v_single_result
            );

            IF SUBSTR(v_single_result, 1, 7) = 'SUCCESS' THEN
                v_success_count := v_success_count + 1;
            ELSE
                v_failed_count := v_failed_count + 1;
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                v_failed_count := v_failed_count + 1;
        END;

        EXIT WHEN v_next_pos = 0;
        v_pos := v_next_pos + 1;
    END LOOP;

    p_result := 'SUCCESS: 成功创建' || v_success_count || '个通知，失败' || v_failed_count || '个';
END sp_batch_create_notifications;
/

-- 9.3 刷新标签趋势分数
-- 说明:
--   为 V2 /tags/trending 和 /tags/{name}/analytics 提供基础趋势数据。
--   算法尽量简单，重点是先有可开发可测试的数据结构。
CREATE OR REPLACE PROCEDURE sp_refresh_tag_trends(
    p_result OUT VARCHAR2
)
AS
BEGIN
    MERGE INTO n_tags t
    USING (
        SELECT
            pt.tag_id,
            COUNT(*) AS total_usage,
            ROUND(
                SUM(
                    CASE
                        WHEN p.created_at >= SYSTIMESTAMP - INTERVAL '1' DAY THEN 3
                        WHEN p.created_at >= SYSTIMESTAMP - INTERVAL '7' DAY THEN 1
                        ELSE 0.2
                    END
                ),
                2
            ) AS new_trending_score
        FROM n_post_tags pt
        JOIN n_posts p ON p.post_id = pt.post_id
        WHERE p.is_deleted = 0
        GROUP BY pt.tag_id
    ) src
    ON (t.tag_id = src.tag_id)
    WHEN MATCHED THEN
        UPDATE SET
            t.usage_count = src.total_usage,
            t.trending_score = src.new_trending_score,
            t.is_trending = CASE WHEN src.new_trending_score >= 10 THEN 1 ELSE 0 END,
            t.updated_at = CURRENT_TIMESTAMP;

    COMMIT;
    p_result := 'SUCCESS: 标签趋势已刷新';
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_refresh_tag_trends;
/

-- 9.4 创建群组
-- 修复点:
--   原版过程把 member_count 直接写成 1，再插入 owner 成员，容易和触发器叠加。
--   V2 中统一由成员计数触发器维护 member_count。
CREATE OR REPLACE PROCEDURE sp_create_group(
    p_owner_id          IN NUMBER,
    p_name              IN VARCHAR2,
    p_description       IN VARCHAR2 DEFAULT NULL,
    p_avatar_url        IN VARCHAR2 DEFAULT NULL,
    p_cover_url         IN VARCHAR2 DEFAULT NULL,
    p_privacy           IN VARCHAR2 DEFAULT 'public',
    p_join_approval     IN NUMBER DEFAULT 0,
    p_post_permission   IN VARCHAR2 DEFAULT 'all',
    p_group_id          OUT NUMBER,
    p_result            OUT VARCHAR2
)
AS
    v_slug VARCHAR2(100);
BEGIN
    v_slug := fn_generate_group_slug(p_name);

    INSERT INTO n_groups (
        name, slug, description, avatar_url, cover_url,
        owner_id, privacy, join_approval, post_permission
    ) VALUES (
        p_name, v_slug, p_description, p_avatar_url, p_cover_url,
        p_owner_id, p_privacy, p_join_approval, p_post_permission
    ) RETURNING group_id INTO p_group_id;

    INSERT INTO n_group_members (
        group_id, user_id, role, status
    ) VALUES (
        p_group_id, p_owner_id, 'owner', 'active'
    );

    INSERT INTO n_group_audit_logs (
        group_id, actor_id, action, details
    ) VALUES (
        p_group_id, p_owner_id, 'create_group',
        '{"name": "' || REPLACE(p_name, '"', '\"') || '", "privacy": "' || p_privacy || '"}'
    );

    p_result := '群组创建成功';
    COMMIT;
EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
        p_result := '群组名称或标识已存在';
        ROLLBACK;
    WHEN OTHERS THEN
        p_result := '创建群组失败: ' || SQLERRM;
        ROLLBACK;
END sp_create_group;
/

-- 9.5 加入群组
CREATE OR REPLACE PROCEDURE sp_join_group(
    p_user_id       IN NUMBER,
    p_group_id      IN NUMBER,
    p_invite_code   IN VARCHAR2 DEFAULT NULL,
    p_member_id     OUT NUMBER,
    p_result        OUT VARCHAR2
)
AS
    v_privacy         VARCHAR2(20);
    v_join_approval   NUMBER;
    v_is_active       NUMBER;
    v_is_deleted      NUMBER;
    v_existing_count  NUMBER := 0;
    v_status          VARCHAR2(20);
    v_invite_id       NUMBER;
    v_inviter_id      NUMBER := NULL;
BEGIN
    SELECT privacy, join_approval, is_active, is_deleted
    INTO v_privacy, v_join_approval, v_is_active, v_is_deleted
    FROM n_groups
    WHERE group_id = p_group_id;

    IF v_is_deleted = 1 THEN
        p_result := '群组已被删除';
        RETURN;
    END IF;

    IF v_is_active = 0 THEN
        p_result := '群组已被封禁';
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_existing_count
    FROM n_group_members
    WHERE group_id = p_group_id
      AND user_id = p_user_id;

    IF v_existing_count > 0 THEN
        p_result := '您已经是群组成员';
        RETURN;
    END IF;

    IF v_privacy = 'secret' THEN
        IF p_invite_code IS NULL THEN
            p_result := '该群组仅限邀请加入';
            RETURN;
        END IF;

        IF fn_is_invite_valid(p_invite_code) = 0 THEN
            p_result := '邀请码无效或已过期';
            RETURN;
        END IF;

        SELECT invite_id, inviter_id
        INTO v_invite_id, v_inviter_id
        FROM n_group_invites
        WHERE invite_code = p_invite_code
          AND group_id = p_group_id;

        UPDATE n_group_invites
        SET used_count = used_count + 1
        WHERE invite_id = v_invite_id;

        v_status := 'active';
    ELSIF v_privacy = 'private' OR v_join_approval = 1 THEN
        IF p_invite_code IS NOT NULL AND fn_is_invite_valid(p_invite_code) = 1 THEN
            SELECT invite_id, inviter_id
            INTO v_invite_id, v_inviter_id
            FROM n_group_invites
            WHERE invite_code = p_invite_code
              AND group_id = p_group_id;

            UPDATE n_group_invites
            SET used_count = used_count + 1
            WHERE invite_id = v_invite_id;

            v_status := 'active';
        ELSE
            v_status := 'pending';
        END IF;
    ELSE
        v_status := 'active';
    END IF;

    INSERT INTO n_group_members (
        group_id, user_id, role, status, invited_by
    ) VALUES (
        p_group_id, p_user_id, 'member', v_status, v_inviter_id
    ) RETURNING member_id INTO p_member_id;

    INSERT INTO n_group_audit_logs (
        group_id, actor_id, target_user_id, action, details
    ) VALUES (
        p_group_id, p_user_id, p_user_id,
        CASE WHEN v_status = 'pending' THEN 'request_join' ELSE 'join_group' END,
        '{"status": "' || v_status || '"}'
    );

    IF v_status = 'active' THEN
        p_result := '成功加入群组';
    ELSE
        p_result := '申请已提交，等待管理员审批';
    END IF;

    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_result := '群组不存在';
    WHEN OTHERS THEN
        p_result := '加入群组失败: ' || SQLERRM;
        ROLLBACK;
END sp_join_group;
/

-- 9.6 审批成员
CREATE OR REPLACE PROCEDURE sp_approve_member(
    p_actor_id      IN NUMBER,
    p_member_id     IN NUMBER,
    p_approve       IN NUMBER,
    p_result        OUT VARCHAR2
)
AS
    v_group_id         NUMBER;
    v_target_user_id   NUMBER;
    v_current_status   VARCHAR2(20);
BEGIN
    SELECT group_id, user_id, status
    INTO v_group_id, v_target_user_id, v_current_status
    FROM n_group_members
    WHERE member_id = p_member_id;

    IF fn_has_group_permission(p_actor_id, v_group_id, 'moderator') = 0 THEN
        p_result := '您没有审批权限';
        RETURN;
    END IF;

    IF v_current_status != 'pending' THEN
        p_result := '该成员不在待审批状态';
        RETURN;
    END IF;

    IF p_approve = 1 THEN
        UPDATE n_group_members
        SET status = 'active'
        WHERE member_id = p_member_id;

        INSERT INTO n_group_audit_logs (
            group_id, actor_id, target_user_id, action
        ) VALUES (
            v_group_id, p_actor_id, v_target_user_id, 'approve_member'
        );

        p_result := '已批准加入';
    ELSE
        DELETE FROM n_group_members
        WHERE member_id = p_member_id;

        INSERT INTO n_group_audit_logs (
            group_id, actor_id, target_user_id, action
        ) VALUES (
            v_group_id, p_actor_id, v_target_user_id, 'reject_member'
        );

        p_result := '已拒绝申请';
    END IF;

    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_result := '成员记录不存在';
    WHEN OTHERS THEN
        p_result := '操作失败: ' || SQLERRM;
        ROLLBACK;
END sp_approve_member;
/

-- 9.7 退出群组
CREATE OR REPLACE PROCEDURE sp_leave_group(
    p_user_id       IN NUMBER,
    p_group_id      IN NUMBER,
    p_result        OUT VARCHAR2
)
AS
    v_role VARCHAR2(20);
BEGIN
    v_role := fn_get_member_role(p_user_id, p_group_id);

    IF v_role IS NULL THEN
        p_result := '您不是群组成员';
        RETURN;
    END IF;

    IF v_role = 'owner' THEN
        p_result := '群主不能退出群组，请先转让群主身份';
        RETURN;
    END IF;

    DELETE FROM n_group_members
    WHERE group_id = p_group_id
      AND user_id = p_user_id;

    INSERT INTO n_group_audit_logs (
        group_id, actor_id, target_user_id, action
    ) VALUES (
        p_group_id, p_user_id, p_user_id, 'leave_group'
    );

    p_result := '已退出群组';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        p_result := '退出失败: ' || SQLERRM;
        ROLLBACK;
END sp_leave_group;
/

-- 9.8 移除成员
CREATE OR REPLACE PROCEDURE sp_remove_member(
    p_actor_id      IN NUMBER,
    p_target_id     IN NUMBER,
    p_group_id      IN NUMBER,
    p_reason        IN VARCHAR2 DEFAULT NULL,
    p_result        OUT VARCHAR2
)
AS
BEGIN
    IF fn_can_manage_member(p_actor_id, p_target_id, p_group_id) = 0 THEN
        p_result := '您没有权限移除该成员';
        RETURN;
    END IF;

    DELETE FROM n_group_members
    WHERE group_id = p_group_id
      AND user_id = p_target_id;

    IF SQL%ROWCOUNT = 0 THEN
        p_result := '成员不存在';
        RETURN;
    END IF;

    INSERT INTO n_group_audit_logs (
        group_id, actor_id, target_user_id, action, details
    ) VALUES (
        p_group_id, p_actor_id, p_target_id, 'remove_member',
        CASE WHEN p_reason IS NOT NULL THEN '{"reason": "' || REPLACE(p_reason, '"', '\"') || '"}' ELSE NULL END
    );

    p_result := '已移除成员';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        p_result := '操作失败: ' || SQLERRM;
        ROLLBACK;
END sp_remove_member;
/

-- 9.9 变更成员角色
CREATE OR REPLACE PROCEDURE sp_change_member_role(
    p_actor_id      IN NUMBER,
    p_target_id     IN NUMBER,
    p_group_id      IN NUMBER,
    p_new_role      IN VARCHAR2,
    p_result        OUT VARCHAR2
)
AS
    v_actor_role VARCHAR2(20);
    v_old_role   VARCHAR2(20);
BEGIN
    v_actor_role := fn_get_member_role(p_actor_id, p_group_id);
    v_old_role := fn_get_member_role(p_target_id, p_group_id);

    IF v_actor_role IS NULL THEN
        p_result := '您不是群组成员';
        RETURN;
    END IF;

    IF v_old_role IS NULL THEN
        p_result := '目标用户不是群组成员';
        RETURN;
    END IF;

    IF p_new_role = 'owner' THEN
        p_result := '请使用转让群主接口';
        RETURN;
    END IF;

    IF p_new_role = 'admin' AND v_actor_role != 'owner' THEN
        p_result := '只有群主可以设置管理员';
        RETURN;
    END IF;

    IF p_new_role = 'moderator' AND v_actor_role NOT IN ('owner', 'admin') THEN
        p_result := '您没有权限设置版主';
        RETURN;
    END IF;

    IF v_old_role = 'owner' THEN
        p_result := '不能直接修改群主角色';
        RETURN;
    END IF;

    UPDATE n_group_members
    SET role = p_new_role
    WHERE group_id = p_group_id
      AND user_id = p_target_id;

    INSERT INTO n_group_audit_logs (
        group_id, actor_id, target_user_id, action, details
    ) VALUES (
        p_group_id, p_actor_id, p_target_id, 'change_role',
        '{"old_role": "' || v_old_role || '", "new_role": "' || p_new_role || '"}'
    );

    p_result := '角色变更成功';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        p_result := '操作失败: ' || SQLERRM;
        ROLLBACK;
END sp_change_member_role;
/

-- 9.10 转让群主
CREATE OR REPLACE PROCEDURE sp_transfer_ownership(
    p_owner_id      IN NUMBER,
    p_new_owner_id  IN NUMBER,
    p_group_id      IN NUMBER,
    p_result        OUT VARCHAR2
)
AS
    v_current_role   VARCHAR2(20);
    v_target_status  VARCHAR2(20);
BEGIN
    v_current_role := fn_get_member_role(p_owner_id, p_group_id);

    IF v_current_role != 'owner' THEN
        p_result := '只有群主可以转让群组';
        RETURN;
    END IF;

    SELECT status INTO v_target_status
    FROM n_group_members
    WHERE group_id = p_group_id
      AND user_id = p_new_owner_id;

    IF v_target_status NOT IN ('active', 'muted') THEN
        p_result := '目标用户不是可接管的成员';
        RETURN;
    END IF;

    UPDATE n_group_members
    SET role = 'admin'
    WHERE group_id = p_group_id
      AND user_id = p_owner_id;

    UPDATE n_group_members
    SET role = 'owner'
    WHERE group_id = p_group_id
      AND user_id = p_new_owner_id;

    UPDATE n_groups
    SET owner_id = p_new_owner_id
    WHERE group_id = p_group_id;

    INSERT INTO n_group_audit_logs (
        group_id, actor_id, target_user_id, action, details
    ) VALUES (
        p_group_id, p_owner_id, p_new_owner_id, 'transfer_ownership',
        '{"from": ' || p_owner_id || ', "to": ' || p_new_owner_id || '}'
    );

    p_result := '群主转让成功';
    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_result := '目标用户不是群组成员';
    WHEN OTHERS THEN
        p_result := '操作失败: ' || SQLERRM;
        ROLLBACK;
END sp_transfer_ownership;
/

-- 9.11 禁言成员
CREATE OR REPLACE PROCEDURE sp_mute_member(
    p_actor_id        IN NUMBER,
    p_target_id       IN NUMBER,
    p_group_id        IN NUMBER,
    p_duration_hours  IN NUMBER,
    p_reason          IN VARCHAR2 DEFAULT NULL,
    p_result          OUT VARCHAR2
)
AS
BEGIN
    IF fn_can_manage_member(p_actor_id, p_target_id, p_group_id) = 0 THEN
        p_result := '您没有权限禁言该成员';
        RETURN;
    END IF;

    UPDATE n_group_members
    SET status = 'muted',
        mute_until = SYSTIMESTAMP + NUMTODSINTERVAL(p_duration_hours, 'HOUR'),
        ban_reason = p_reason
    WHERE group_id = p_group_id
      AND user_id = p_target_id;

    IF SQL%ROWCOUNT = 0 THEN
        p_result := '成员不存在';
        RETURN;
    END IF;

    INSERT INTO n_group_audit_logs (
        group_id, actor_id, target_user_id, action, details
    ) VALUES (
        p_group_id, p_actor_id, p_target_id, 'mute_member',
        '{"duration_hours": ' || p_duration_hours ||
        CASE WHEN p_reason IS NOT NULL THEN ', "reason": "' || REPLACE(p_reason, '"', '\"') || '"' ELSE '' END || '}'
    );

    p_result := '已禁言成员 ' || p_duration_hours || ' 小时';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        p_result := '操作失败: ' || SQLERRM;
        ROLLBACK;
END sp_mute_member;
/

-- 9.12 解除禁言
CREATE OR REPLACE PROCEDURE sp_unmute_member(
    p_actor_id      IN NUMBER,
    p_target_id     IN NUMBER,
    p_group_id      IN NUMBER,
    p_result        OUT VARCHAR2
)
AS
BEGIN
    IF fn_can_manage_member(p_actor_id, p_target_id, p_group_id) = 0 THEN
        p_result := '您没有权限执行此操作';
        RETURN;
    END IF;

    UPDATE n_group_members
    SET status = 'active',
        mute_until = NULL,
        ban_reason = NULL
    WHERE group_id = p_group_id
      AND user_id = p_target_id
      AND status = 'muted';

    IF SQL%ROWCOUNT = 0 THEN
        p_result := '成员不存在或未被禁言';
        RETURN;
    END IF;

    INSERT INTO n_group_audit_logs (
        group_id, actor_id, target_user_id, action
    ) VALUES (
        p_group_id, p_actor_id, p_target_id, 'unmute_member'
    );

    p_result := '已解除禁言';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        p_result := '操作失败: ' || SQLERRM;
        ROLLBACK;
END sp_unmute_member;
/

-- 9.13 发布群组帖子
CREATE OR REPLACE PROCEDURE sp_create_group_post(
    p_author_id     IN NUMBER,
    p_group_id      IN NUMBER,
    p_content       IN VARCHAR2,
    p_media_urls    IN VARCHAR2 DEFAULT NULL,
    p_post_id       OUT NUMBER,
    p_result        OUT VARCHAR2
)
AS
BEGIN
    IF fn_can_post_in_group(p_author_id, p_group_id) = 0 THEN
        p_result := '您没有在此群组发帖的权限';
        RETURN;
    END IF;

    INSERT INTO n_group_posts (
        group_id, author_id, content, media_urls
    ) VALUES (
        p_group_id, p_author_id, p_content, p_media_urls
    ) RETURNING post_id INTO p_post_id;

    INSERT INTO n_group_audit_logs (
        group_id, actor_id, target_post_id, action
    ) VALUES (
        p_group_id, p_author_id, p_post_id, 'create_post'
    );

    p_result := '帖子发布成功';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        p_result := '发帖失败: ' || SQLERRM;
        ROLLBACK;
END sp_create_group_post;
/

-- 9.14 删除群组帖子
CREATE OR REPLACE PROCEDURE sp_delete_group_post(
    p_actor_id      IN NUMBER,
    p_post_id       IN NUMBER,
    p_reason        IN VARCHAR2 DEFAULT NULL,
    p_result        OUT VARCHAR2
)
AS
    v_group_id NUMBER;
    v_author_id NUMBER;
BEGIN
    SELECT group_id, author_id
    INTO v_group_id, v_author_id
    FROM n_group_posts
    WHERE post_id = p_post_id
      AND is_deleted = 0;

    IF p_actor_id != v_author_id
       AND fn_has_group_permission(p_actor_id, v_group_id, 'moderator') = 0 THEN
        p_result := '您没有权限删除此帖子';
        RETURN;
    END IF;

    UPDATE n_group_posts
    SET is_deleted = 1,
        deleted_by = p_actor_id,
        delete_reason = p_reason
    WHERE post_id = p_post_id;

    INSERT INTO n_group_audit_logs (
        group_id, actor_id, target_post_id, action, details
    ) VALUES (
        v_group_id, p_actor_id, p_post_id, 'delete_post',
        CASE WHEN p_reason IS NOT NULL THEN '{"reason": "' || REPLACE(p_reason, '"', '\"') || '"}' ELSE NULL END
    );

    p_result := '帖子已删除';
    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_result := '帖子不存在或已被删除';
    WHEN OTHERS THEN
        p_result := '操作失败: ' || SQLERRM;
        ROLLBACK;
END sp_delete_group_post;
/

-- 9.15 置顶 / 取消置顶群组帖子
CREATE OR REPLACE PROCEDURE sp_toggle_post_pin(
    p_actor_id      IN NUMBER,
    p_post_id       IN NUMBER,
    p_pin           IN NUMBER,
    p_result        OUT VARCHAR2
)
AS
    v_group_id NUMBER;
BEGIN
    SELECT group_id
    INTO v_group_id
    FROM n_group_posts
    WHERE post_id = p_post_id
      AND is_deleted = 0;

    IF fn_has_group_permission(p_actor_id, v_group_id, 'moderator') = 0 THEN
        p_result := '您没有权限执行此操作';
        RETURN;
    END IF;

    UPDATE n_group_posts
    SET is_pinned = p_pin
    WHERE post_id = p_post_id;

    INSERT INTO n_group_audit_logs (
        group_id, actor_id, target_post_id, action
    ) VALUES (
        v_group_id, p_actor_id, p_post_id,
        CASE WHEN p_pin = 1 THEN 'pin_post' ELSE 'unpin_post' END
    );

    p_result := CASE WHEN p_pin = 1 THEN '帖子已置顶' ELSE '已取消置顶' END;
    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_result := '帖子不存在';
    WHEN OTHERS THEN
        p_result := '操作失败: ' || SQLERRM;
        ROLLBACK;
END sp_toggle_post_pin;
/

-- 9.16 创建群组邀请
CREATE OR REPLACE PROCEDURE sp_create_group_invite(
    p_inviter_id    IN NUMBER,
    p_group_id      IN NUMBER,
    p_invitee_id    IN NUMBER DEFAULT NULL,
    p_max_uses      IN NUMBER DEFAULT 1,
    p_expire_hours  IN NUMBER DEFAULT 168,
    p_message       IN VARCHAR2 DEFAULT NULL,
    p_invite_id     OUT NUMBER,
    p_invite_code   OUT VARCHAR2,
    p_result        OUT VARCHAR2
)
AS
BEGIN
    IF fn_is_group_member(p_inviter_id, p_group_id) = 0 THEN
        p_result := '您不是群组成员';
        RETURN;
    END IF;

    IF p_invitee_id IS NULL THEN
        p_invite_code := fn_generate_invite_code();
    ELSE
        p_invite_code := NULL;
    END IF;

    INSERT INTO n_group_invites (
        group_id, inviter_id, invitee_id, invite_code,
        max_uses, message, expires_at
    ) VALUES (
        p_group_id, p_inviter_id, p_invitee_id, p_invite_code,
        p_max_uses, p_message,
        CASE WHEN p_expire_hours > 0 THEN SYSTIMESTAMP + NUMTODSINTERVAL(p_expire_hours, 'HOUR') ELSE NULL END
    ) RETURNING invite_id INTO p_invite_id;

    INSERT INTO n_group_audit_logs (
        group_id, actor_id, target_user_id, action, details
    ) VALUES (
        p_group_id, p_inviter_id, p_invitee_id, 'create_invite',
        '{"max_uses": ' || p_max_uses || ', "expire_hours": ' || p_expire_hours || '}'
    );

    p_result := '邀请创建成功';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        p_result := '创建邀请失败: ' || SQLERRM;
        ROLLBACK;
END sp_create_group_invite;
/

-- 9.17 点赞 / 取消点赞群组帖子
CREATE OR REPLACE PROCEDURE sp_like_group_post(
    p_user_id       IN NUMBER,
    p_post_id       IN NUMBER,
    p_action        IN VARCHAR2,
    p_result        OUT VARCHAR2
)
AS
    v_group_id         NUMBER;
    v_existing_count   NUMBER := 0;
BEGIN
    SELECT group_id
    INTO v_group_id
    FROM n_group_posts
    WHERE post_id = p_post_id
      AND is_deleted = 0;

    IF fn_is_group_member(p_user_id, v_group_id) = 0 THEN
        p_result := '您不是群组成员';
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_existing_count
    FROM n_group_post_likes
    WHERE post_id = p_post_id
      AND user_id = p_user_id;

    IF p_action = 'like' THEN
        IF v_existing_count > 0 THEN
            p_result := '您已经点赞过了';
            RETURN;
        END IF;

        INSERT INTO n_group_post_likes (post_id, user_id)
        VALUES (p_post_id, p_user_id);

        p_result := '点赞成功';
    ELSIF p_action = 'unlike' THEN
        IF v_existing_count = 0 THEN
            p_result := '您还没有点赞';
            RETURN;
        END IF;

        DELETE FROM n_group_post_likes
        WHERE post_id = p_post_id
          AND user_id = p_user_id;

        p_result := '已取消点赞';
    ELSE
        p_result := '无效操作';
        RETURN;
    END IF;

    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_result := '帖子不存在';
    WHEN OTHERS THEN
        p_result := '操作失败: ' || SQLERRM;
        ROLLBACK;
END sp_like_group_post;
/

-- 9.18 群组帖子评论
CREATE OR REPLACE PROCEDURE sp_create_group_comment(
    p_author_id         IN NUMBER,
    p_post_id           IN NUMBER,
    p_content           IN VARCHAR2,
    p_parent_comment_id IN NUMBER DEFAULT NULL,
    p_reply_to_user_id  IN NUMBER DEFAULT NULL,
    p_comment_id        OUT NUMBER,
    p_result            OUT VARCHAR2
)
AS
    v_group_id NUMBER;
BEGIN
    SELECT group_id
    INTO v_group_id
    FROM n_group_posts
    WHERE post_id = p_post_id
      AND is_deleted = 0;

    IF fn_can_post_in_group(p_author_id, v_group_id) = 0 THEN
        p_result := '您没有在此群组发言的权限';
        RETURN;
    END IF;

    INSERT INTO n_group_comments (
        post_id, author_id, content, parent_comment_id, reply_to_user_id
    ) VALUES (
        p_post_id, p_author_id, p_content, p_parent_comment_id, p_reply_to_user_id
    ) RETURNING comment_id INTO p_comment_id;

    INSERT INTO n_group_audit_logs (
        group_id, actor_id, target_post_id, target_comment_id, action
    ) VALUES (
        v_group_id, p_author_id, p_post_id, p_comment_id, 'create_comment'
    );

    p_result := '评论发布成功';
    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_result := '帖子不存在';
    WHEN OTHERS THEN
        p_result := '评论失败: ' || SQLERRM;
        ROLLBACK;
END sp_create_group_comment;
/

-- 9.19 更新群组信息
CREATE OR REPLACE PROCEDURE sp_update_group(
    p_actor_id          IN NUMBER,
    p_group_id          IN NUMBER,
    p_name              IN VARCHAR2 DEFAULT NULL,
    p_description       IN VARCHAR2 DEFAULT NULL,
    p_avatar_url        IN VARCHAR2 DEFAULT NULL,
    p_cover_url         IN VARCHAR2 DEFAULT NULL,
    p_privacy           IN VARCHAR2 DEFAULT NULL,
    p_join_approval     IN NUMBER DEFAULT NULL,
    p_post_permission   IN VARCHAR2 DEFAULT NULL,
    p_result            OUT VARCHAR2
)
AS
    v_changes VARCHAR2(2000) := '{';
    v_first   NUMBER := 1;
BEGIN
    IF fn_has_group_permission(p_actor_id, p_group_id, 'admin') = 0 THEN
        p_result := '您没有权限修改群组信息';
        RETURN;
    END IF;

    UPDATE n_groups
    SET name = COALESCE(p_name, name),
        description = COALESCE(p_description, description),
        avatar_url = COALESCE(p_avatar_url, avatar_url),
        cover_url = COALESCE(p_cover_url, cover_url),
        privacy = COALESCE(p_privacy, privacy),
        join_approval = COALESCE(p_join_approval, join_approval),
        post_permission = COALESCE(p_post_permission, post_permission)
    WHERE group_id = p_group_id;

    IF p_name IS NOT NULL THEN
        v_changes := v_changes || '"name": "' || REPLACE(p_name, '"', '\"') || '"';
        v_first := 0;
    END IF;
    IF p_privacy IS NOT NULL THEN
        IF v_first = 0 THEN
            v_changes := v_changes || ', ';
        END IF;
        v_changes := v_changes || '"privacy": "' || p_privacy || '"';
        v_first := 0;
    END IF;
    IF p_post_permission IS NOT NULL THEN
        IF v_first = 0 THEN
            v_changes := v_changes || ', ';
        END IF;
        v_changes := v_changes || '"post_permission": "' || p_post_permission || '"';
    END IF;
    v_changes := v_changes || '}';

    INSERT INTO n_group_audit_logs (
        group_id, actor_id, action, details
    ) VALUES (
        p_group_id, p_actor_id, 'update_group', v_changes
    );

    p_result := '群组信息已更新';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        p_result := '更新失败: ' || SQLERRM;
        ROLLBACK;
END sp_update_group;
/

-- 9.20 解散群组
CREATE OR REPLACE PROCEDURE sp_delete_group(
    p_owner_id      IN NUMBER,
    p_group_id      IN NUMBER,
    p_result        OUT VARCHAR2
)
AS
    v_role VARCHAR2(20);
BEGIN
    v_role := fn_get_member_role(p_owner_id, p_group_id);

    IF v_role != 'owner' THEN
        p_result := '只有群主可以解散群组';
        RETURN;
    END IF;

    UPDATE n_groups
    SET is_deleted = 1
    WHERE group_id = p_group_id;

    INSERT INTO n_group_audit_logs (
        group_id, actor_id, action
    ) VALUES (
        p_group_id, p_owner_id, 'delete_group'
    );

    p_result := '群组已解散';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        p_result := '操作失败: ' || SQLERRM;
        ROLLBACK;
END sp_delete_group;
/

-- ==========================================
-- 10. 视图
-- ==========================================

-- 10.1 用户公开资料视图
CREATE OR REPLACE VIEW v_user_profile_public AS
SELECT
    u.user_id,
    u.username,
    u.avatar_url,
    u.avatar_media_id,
    u.display_name,
    u.bio,
    u.location,
    u.website,
    u.is_verified,
    u.is_active,
    u.status,
    s.followers_count,
    s.following_count,
    s.posts_count,
    s.likes_count,
    s.bookmarks_count,
    s.comments_count,
    u.created_at,
    u.updated_at,
    u.last_login_at,
    CASE
        WHEN u.last_login_at > SYSDATE - 7 THEN 'active'
        WHEN u.last_login_at > SYSDATE - 30 THEN 'normal'
        ELSE 'inactive'
    END AS activity_status
FROM n_users u
JOIN n_user_stats s ON s.user_id = u.user_id;

COMMENT ON TABLE v_user_profile_public IS 'V2 用户公开资料视图';

-- 10.1.1 当前用户资料视图
-- 说明:
--   /users/me 这类接口建议走这个视图或直接查表；
--   它保留 email / phone / birth_date 等敏感字段，不适合作为公开资料接口直接对外暴露。
CREATE OR REPLACE VIEW v_user_profile_self AS
SELECT
    u.user_id,
    u.email,
    u.username,
    u.avatar_url,
    u.avatar_media_id,
    u.display_name,
    u.bio,
    u.location,
    u.website,
    u.phone,
    u.birth_date,
    u.email_verified_at,
    u.is_verified,
    u.is_active,
    u.status,
    s.followers_count,
    s.following_count,
    s.posts_count,
    s.likes_count,
    s.bookmarks_count,
    s.comments_count,
    u.created_at,
    u.updated_at,
    u.last_login_at
FROM n_users u
JOIN n_user_stats s ON s.user_id = u.user_id;

COMMENT ON TABLE v_user_profile_self IS 'V2 当前用户资料视图，包含敏感字段，仅适合 /users/me 使用';

-- 兼容迁移期的 profile 视图名称
CREATE OR REPLACE VIEW v_user_profile AS
SELECT
    user_id,
    username,
    display_name,
    email,
    avatar_url,
    bio,
    location,
    website,
    is_verified,
    followers_count,
    following_count,
    posts_count AS tweets_count,
    likes_count,
    created_at,
    last_login_at,
    CASE
        WHEN last_login_at > SYSDATE - 7 THEN 'active'
        WHEN last_login_at > SYSDATE - 30 THEN 'normal'
        ELSE 'inactive'
    END AS activity_status
FROM v_user_profile_self;

COMMENT ON TABLE v_user_profile IS '兼容迁移期的用户资料视图，保留旧名称但内部基于 V2 结构';

-- 10.2 帖子详情视图
CREATE OR REPLACE VIEW v_post_detail AS
SELECT
    p.post_id,
    p.author_id,
    p.content,
    p.post_type,
    p.reply_to_post_id,
    p.repost_of_post_id,
    p.quoted_post_id,
    p.visibility,
    p.language,
    p.location,
    p.is_deleted,
    p.deleted_at,
    p.created_at,
    p.updated_at,
    u.username,
    u.display_name,
    u.avatar_url,
    u.is_verified,
    ps.likes_count,
    ps.comments_count,
    ps.replies_count,
    ps.retweets_count,
    ps.views_count,
    ps.engagement_score,
    (
        SELECT COUNT(*)
        FROM n_post_media pm
        WHERE pm.post_id = p.post_id
    ) AS media_count
FROM n_posts p
JOIN n_users u ON u.user_id = p.author_id
JOIN n_post_stats ps ON ps.post_id = p.post_id
WHERE p.is_deleted = 0;

COMMENT ON TABLE v_post_detail IS 'V2 帖子详情视图，适合详情和列表查询复用';

-- 10.3 评论列表项视图
CREATE OR REPLACE VIEW v_post_comment_list_item AS
SELECT
    c.comment_id,
    c.post_id,
    c.user_id,
    c.parent_comment_id,
    c.root_comment_id,
    c.content,
    c.is_deleted,
    c.created_at,
    c.updated_at,
    u.username,
    u.display_name,
    u.avatar_url,
    u.is_verified,
    cs.likes_count,
    cs.replies_count
FROM n_comments c
JOIN n_users u ON u.user_id = c.user_id
JOIN n_comment_stats cs ON cs.comment_id = c.comment_id
WHERE c.is_deleted = 0;

COMMENT ON TABLE v_post_comment_list_item IS 'V2 评论列表项视图';

-- 10.4 通知列表视图
CREATE OR REPLACE VIEW v_notification_list_item AS
SELECT
    n.notification_id,
    n.user_id,
    n.actor_id,
    n.type,
    n.title,
    n.message,
    n.resource_type,
    n.resource_id,
    n.priority,
    n.is_read,
    n.read_at,
    n.deleted_at,
    n.metadata_json,
    n.created_at,
    ru.username AS recipient_username,
    ru.display_name AS recipient_display_name,
    ru.avatar_url AS recipient_avatar_url,
    au.username AS actor_username,
    au.display_name AS actor_display_name,
    au.avatar_url AS actor_avatar_url,
    au.is_verified AS actor_is_verified,
    CASE
        WHEN n.is_read = 1 THEN '已读'
        ELSE '未读'
    END AS read_status_desc,
    CASE
        WHEN n.priority = 'urgent' THEN '紧急'
        WHEN n.priority = 'high' THEN '高'
        WHEN n.priority = 'normal' THEN '普通'
        ELSE '低'
    END AS priority_desc
FROM n_notifications n
JOIN n_users ru ON ru.user_id = n.user_id
LEFT JOIN n_users au ON au.user_id = n.actor_id;

COMMENT ON TABLE v_notification_list_item IS 'V2 通知列表视图';

-- 兼容迁移期保留旧名称
CREATE OR REPLACE VIEW v_notifications_detail AS
SELECT
    notification_id,
    user_id,
    type,
    title,
    message,
    resource_type AS related_type,
    resource_id AS related_id,
    actor_id,
    is_read,
    priority,
    created_at,
    read_at,
    recipient_username,
    recipient_display_name,
    recipient_avatar_url,
    actor_username,
    actor_display_name,
    actor_avatar_url,
    actor_is_verified,
    read_status_desc,
    priority_desc
FROM v_notification_list_item;

COMMENT ON TABLE v_notifications_detail IS '兼容迁移期保留的通知详情视图';

-- 10.5 用户分析视图
CREATE OR REPLACE VIEW v_user_analytics AS
SELECT
    u.user_id,
    u.username,
    u.display_name,
    s.followers_count,
    s.following_count,
    s.posts_count,
    s.likes_count AS total_likes_received,
    s.bookmarks_count,
    s.comments_count,
    NVL(ROUND(AVG(ps.likes_count), 2), 0) AS avg_likes_per_post,
    NVL(ROUND(AVG(ps.views_count), 2), 0) AS avg_views_per_post,
    NVL(ROUND(AVG(ps.engagement_score), 2), 0) AS avg_engagement_score
FROM n_users u
JOIN n_user_stats s ON s.user_id = u.user_id
LEFT JOIN n_posts p ON p.author_id = u.user_id AND p.is_deleted = 0
LEFT JOIN n_post_stats ps ON ps.post_id = p.post_id
GROUP BY
    u.user_id,
    u.username,
    u.display_name,
    s.followers_count,
    s.following_count,
    s.posts_count,
    s.likes_count,
    s.bookmarks_count,
    s.comments_count;

COMMENT ON TABLE v_user_analytics IS 'V2 用户分析视图';

-- 10.6 帖子分析视图
CREATE OR REPLACE VIEW v_post_analytics AS
SELECT
    p.post_id,
    p.author_id,
    u.username AS author_username,
    u.display_name AS author_display_name,
    p.post_type,
    p.visibility,
    p.created_at,
    ps.likes_count,
    ps.comments_count,
    ps.replies_count,
    ps.retweets_count,
    ps.views_count,
    ps.engagement_score
FROM n_posts p
JOIN n_users u ON u.user_id = p.author_id
JOIN n_post_stats ps ON ps.post_id = p.post_id
WHERE p.is_deleted = 0;

COMMENT ON TABLE v_post_analytics IS 'V2 帖子分析视图';

-- 10.7 标签分析视图
CREATE OR REPLACE VIEW v_tag_analytics AS
SELECT
    t.tag_id,
    t.name,
    t.name_lower,
    t.usage_count,
    t.trending_score,
    t.is_trending,
    t.created_at,
    t.updated_at,
    NVL(COUNT(DISTINCT pt.post_id), 0) AS total_posts,
    NVL(COUNT(DISTINCT p.author_id), 0) AS total_authors,
    NVL(SUM(ps.likes_count), 0) AS total_likes,
    NVL(SUM(ps.comments_count), 0) AS total_comments,
    NVL(SUM(ps.replies_count), 0) AS total_replies,
    NVL(SUM(ps.retweets_count), 0) AS total_retweets,
    NVL(SUM(ps.views_count), 0) AS total_views,
    NVL(ROUND(AVG(ps.engagement_score), 2), 0) AS avg_engagement_score
FROM n_tags t
LEFT JOIN n_post_tags pt ON pt.tag_id = t.tag_id
LEFT JOIN n_posts p ON p.post_id = pt.post_id AND p.is_deleted = 0
LEFT JOIN n_post_stats ps ON ps.post_id = p.post_id
GROUP BY
    t.tag_id,
    t.name,
    t.name_lower,
    t.usage_count,
    t.trending_score,
    t.is_trending,
    t.created_at,
    t.updated_at;

COMMENT ON TABLE v_tag_analytics IS 'V2 标签分析视图';

-- 10.8 群组详情视图
CREATE OR REPLACE VIEW v_group_details AS
SELECT
    g.group_id,
    g.name AS group_name,
    g.slug,
    g.description,
    g.avatar_url AS group_avatar_url,
    g.cover_url,
    g.owner_id,
    g.privacy,
    fn_get_privacy_desc(g.privacy) AS privacy_desc,
    g.join_approval,
    g.post_permission,
    g.member_count,
    g.post_count,
    g.is_active,
    g.is_deleted,
    g.created_at,
    g.updated_at,
    u.username AS owner_username,
    u.display_name AS owner_display_name,
    u.avatar_url AS owner_avatar_url,
    u.is_verified AS owner_is_verified
FROM n_groups g
JOIN n_users u ON g.owner_id = u.user_id;

COMMENT ON TABLE v_group_details IS '群组详情视图';

-- 10.9 群组成员详情视图
CREATE OR REPLACE VIEW v_group_member_details AS
SELECT
    gm.member_id,
    gm.group_id,
    gm.user_id,
    gm.role,
    fn_get_role_desc(gm.role) AS role_desc,
    gm.status,
    fn_get_member_status_desc(gm.status) AS status_desc,
    gm.nickname,
    gm.mute_until,
    gm.ban_reason,
    gm.invited_by,
    gm.joined_at,
    gm.updated_at,
    u.username,
    u.display_name,
    u.avatar_url,
    u.bio,
    u.is_verified,
    u.is_active AS user_is_active,
    g.name AS group_name,
    g.slug AS group_slug,
    inv.username AS inviter_username,
    inv.display_name AS inviter_display_name,
    CASE
        WHEN gm.mute_until IS NOT NULL AND gm.mute_until > SYSTIMESTAMP THEN 1
        ELSE 0
    END AS is_currently_muted
FROM n_group_members gm
JOIN n_users u ON gm.user_id = u.user_id
JOIN n_groups g ON gm.group_id = g.group_id
LEFT JOIN n_users inv ON gm.invited_by = inv.user_id;

COMMENT ON TABLE v_group_member_details IS '群组成员详情视图';

-- 10.10 群组帖子详情视图
CREATE OR REPLACE VIEW v_group_post_details AS
SELECT
    gp.post_id,
    gp.group_id,
    gp.author_id,
    gp.content,
    gp.media_urls,
    gp.is_pinned,
    gp.is_announcement,
    gp.likes_count,
    gp.comments_count,
    gp.views_count,
    gp.is_deleted,
    gp.deleted_by,
    gp.delete_reason,
    gp.created_at,
    gp.updated_at,
    u.username AS author_username,
    u.display_name AS author_display_name,
    u.avatar_url AS author_avatar_url,
    u.is_verified AS author_is_verified,
    gm.role AS author_role,
    fn_get_role_desc(gm.role) AS author_role_desc,
    gm.nickname AS author_nickname,
    g.name AS group_name,
    g.slug AS group_slug,
    g.privacy AS group_privacy,
    del.username AS deleter_username,
    del.display_name AS deleter_display_name
FROM n_group_posts gp
JOIN n_users u ON gp.author_id = u.user_id
JOIN n_groups g ON gp.group_id = g.group_id
LEFT JOIN n_group_members gm ON gp.author_id = gm.user_id AND gp.group_id = gm.group_id
LEFT JOIN n_users del ON gp.deleted_by = del.user_id;

COMMENT ON TABLE v_group_post_details IS '群组帖子详情视图';

-- 10.11 群组评论详情视图
CREATE OR REPLACE VIEW v_group_comment_details AS
SELECT
    gc.comment_id,
    gc.post_id,
    gc.author_id,
    gc.parent_comment_id,
    gc.reply_to_user_id,
    gc.content,
    gc.likes_count,
    gc.is_deleted,
    gc.deleted_by,
    gc.delete_reason,
    gc.created_at,
    gc.updated_at,
    u.username AS author_username,
    u.display_name AS author_display_name,
    u.avatar_url AS author_avatar_url,
    u.is_verified AS author_is_verified,
    ru.username AS reply_to_username,
    ru.display_name AS reply_to_display_name,
    gp.group_id,
    gp.content AS post_content,
    g.name AS group_name,
    g.slug AS group_slug,
    gm.role AS author_role,
    fn_get_role_desc(gm.role) AS author_role_desc,
    gm.nickname AS author_nickname
FROM n_group_comments gc
JOIN n_users u ON gc.author_id = u.user_id
JOIN n_group_posts gp ON gc.post_id = gp.post_id
JOIN n_groups g ON gp.group_id = g.group_id
LEFT JOIN n_users ru ON gc.reply_to_user_id = ru.user_id
LEFT JOIN n_group_members gm ON gc.author_id = gm.user_id AND gp.group_id = gm.group_id;

COMMENT ON TABLE v_group_comment_details IS '群组评论详情视图';

-- 10.12 群组邀请详情视图
CREATE OR REPLACE VIEW v_group_invite_details AS
SELECT
    gi.invite_id,
    gi.group_id,
    gi.inviter_id,
    gi.invitee_id,
    gi.invite_code,
    gi.status,
    gi.message,
    gi.max_uses,
    gi.used_count,
    gi.expires_at,
    gi.created_at,
    gi.responded_at,
    g.name AS group_name,
    g.slug AS group_slug,
    g.avatar_url AS group_avatar_url,
    g.privacy AS group_privacy,
    g.member_count AS group_member_count,
    inv.username AS inviter_username,
    inv.display_name AS inviter_display_name,
    inv.avatar_url AS inviter_avatar_url,
    invt.username AS invitee_username,
    invt.display_name AS invitee_display_name,
    invt.avatar_url AS invitee_avatar_url,
    CASE
        WHEN gi.status != 'pending' THEN 0
        WHEN gi.max_uses IS NOT NULL AND gi.used_count >= gi.max_uses THEN 0
        WHEN gi.expires_at IS NOT NULL AND gi.expires_at < SYSTIMESTAMP THEN 0
        ELSE 1
    END AS is_valid
FROM n_group_invites gi
JOIN n_groups g ON gi.group_id = g.group_id
JOIN n_users inv ON gi.inviter_id = inv.user_id
LEFT JOIN n_users invt ON gi.invitee_id = invt.user_id;

COMMENT ON TABLE v_group_invite_details IS '群组邀请详情视图';

-- 10.13 群组审计日志详情视图
CREATE OR REPLACE VIEW v_group_audit_log_details AS
SELECT
    gal.log_id,
    gal.group_id,
    gal.actor_id,
    gal.target_user_id,
    gal.target_post_id,
    gal.target_comment_id,
    gal.action,
    gal.details,
    gal.ip_address,
    gal.user_agent,
    gal.created_at,
    g.name AS group_name,
    g.slug AS group_slug,
    act.username AS actor_username,
    act.display_name AS actor_display_name,
    act.avatar_url AS actor_avatar_url,
    tu.username AS target_username,
    tu.display_name AS target_display_name
FROM n_group_audit_logs gal
JOIN n_groups g ON gal.group_id = g.group_id
JOIN n_users act ON gal.actor_id = act.user_id
LEFT JOIN n_users tu ON gal.target_user_id = tu.user_id;

COMMENT ON TABLE v_group_audit_log_details IS '群组审计日志详情视图';

-- 10.14 用户群组列表视图
CREATE OR REPLACE VIEW v_user_groups AS
SELECT
    gm.user_id,
    gm.group_id,
    gm.role,
    fn_get_role_desc(gm.role) AS role_desc,
    gm.status,
    gm.nickname,
    gm.joined_at,
    g.name AS group_name,
    g.slug,
    g.description,
    g.avatar_url AS group_avatar_url,
    g.cover_url,
    g.privacy,
    fn_get_privacy_desc(g.privacy) AS privacy_desc,
    g.member_count,
    g.post_count,
    g.owner_id,
    g.is_active,
    u.username AS owner_username,
    u.display_name AS owner_display_name,
    CASE WHEN g.owner_id = gm.user_id THEN 1 ELSE 0 END AS is_owner
FROM n_group_members gm
JOIN n_groups g ON gm.group_id = g.group_id
JOIN n_users u ON g.owner_id = u.user_id
WHERE gm.status = 'active'
  AND g.is_deleted = 0
  AND g.is_active = 1;

COMMENT ON TABLE v_user_groups IS '用户群组列表视图';

-- 10.15 热门群组视图
CREATE OR REPLACE VIEW v_popular_groups AS
SELECT
    g.group_id,
    g.name AS group_name,
    g.slug,
    g.description,
    g.avatar_url AS group_avatar_url,
    g.cover_url,
    g.owner_id,
    g.privacy,
    g.member_count,
    g.post_count,
    g.created_at,
    u.username AS owner_username,
    u.display_name AS owner_display_name,
    u.avatar_url AS owner_avatar_url,
    ROUND(g.member_count * 0.3 + g.post_count * 0.7, 2) AS activity_score
FROM n_groups g
JOIN n_users u ON g.owner_id = u.user_id
WHERE g.privacy = 'public'
  AND g.is_deleted = 0
  AND g.is_active = 1;

COMMENT ON TABLE v_popular_groups IS '热门群组视图';

-- 10.16 群组时间线视图
CREATE OR REPLACE VIEW v_group_timeline AS
SELECT
    gp.post_id,
    gp.group_id,
    gp.author_id,
    gp.content,
    gp.media_urls,
    gp.is_pinned,
    gp.is_announcement,
    gp.likes_count,
    gp.comments_count,
    gp.views_count,
    gp.created_at,
    gp.updated_at,
    u.username AS author_username,
    u.display_name AS author_display_name,
    u.avatar_url AS author_avatar_url,
    u.is_verified AS author_is_verified,
    gm.role AS author_role,
    fn_get_role_desc(gm.role) AS author_role_desc,
    COALESCE(gm.nickname, u.display_name) AS author_display,
    g.name AS group_name,
    g.slug AS group_slug,
    g.avatar_url AS group_avatar_url,
    CASE
        WHEN gp.is_pinned = 1 THEN 2
        WHEN gp.is_announcement = 1 THEN 1
        ELSE 0
    END AS sort_weight
FROM n_group_posts gp
JOIN n_users u ON gp.author_id = u.user_id
JOIN n_groups g ON gp.group_id = g.group_id
LEFT JOIN n_group_members gm ON gp.author_id = gm.user_id AND gp.group_id = gm.group_id
WHERE gp.is_deleted = 0
  AND g.is_deleted = 0
  AND g.is_active = 1;

COMMENT ON TABLE v_group_timeline IS '群组时间线视图';

-- ==========================================
-- 11. 只读授权
-- ==========================================

GRANT SELECT ON n_users TO neko_readonly;
GRANT SELECT ON n_user_stats TO neko_readonly;
GRANT SELECT ON n_auth_sessions TO neko_readonly;
GRANT SELECT ON n_posts TO neko_readonly;
GRANT SELECT ON n_post_stats TO neko_readonly;
GRANT SELECT ON n_comments TO neko_readonly;
GRANT SELECT ON n_comment_stats TO neko_readonly;
GRANT SELECT ON n_media_assets TO neko_readonly;
GRANT SELECT ON n_tags TO neko_readonly;
GRANT SELECT ON n_notifications TO neko_readonly;
GRANT SELECT ON n_groups TO neko_readonly;
GRANT SELECT ON n_group_members TO neko_readonly;
GRANT SELECT ON n_group_posts TO neko_readonly;
GRANT SELECT ON n_group_comments TO neko_readonly;

GRANT SELECT ON v_user_profile_public TO neko_readonly;
GRANT SELECT ON v_user_profile_self TO neko_readonly;
GRANT SELECT ON v_user_profile TO neko_readonly;
GRANT SELECT ON v_post_detail TO neko_readonly;
GRANT SELECT ON v_post_comment_list_item TO neko_readonly;
GRANT SELECT ON v_notification_list_item TO neko_readonly;
GRANT SELECT ON v_notifications_detail TO neko_readonly;
GRANT SELECT ON v_user_analytics TO neko_readonly;
GRANT SELECT ON v_post_analytics TO neko_readonly;
GRANT SELECT ON v_tag_analytics TO neko_readonly;
GRANT SELECT ON v_group_details TO neko_readonly;
GRANT SELECT ON v_group_member_details TO neko_readonly;
GRANT SELECT ON v_group_post_details TO neko_readonly;
GRANT SELECT ON v_group_comment_details TO neko_readonly;
GRANT SELECT ON v_group_invite_details TO neko_readonly;
GRANT SELECT ON v_group_audit_log_details TO neko_readonly;
GRANT SELECT ON v_user_groups TO neko_readonly;
GRANT SELECT ON v_popular_groups TO neko_readonly;
GRANT SELECT ON v_group_timeline TO neko_readonly;

-- ==========================================
-- 12. 开发期建议
-- ==========================================
--
-- 1. 如果你现在就要开始做 V2 API，优先用下面这些对象：
--    - 用户资料: v_user_profile_public
--    - 帖子详情: v_post_detail
--    - 评论列表: v_post_comment_list_item
--    - 通知列表: v_notification_list_item
--    - 用户分析: v_user_analytics
--    - 帖子分析: v_post_analytics
--    - 标签分析: v_tag_analytics
--
-- 2. 如果你还要兼容一段时间的旧逻辑，可以先使用兼容对象：
--    - v_user_profile
--    - v_notifications_detail
--
-- 3. 标签趋势数据建议定时刷新:
--    BEGIN
--      sp_refresh_tag_trends(:result);
--    END;
--    /
--
-- 4. 群组模块原则上可以直接沿用当前 API 的过程式写法；
--    社交主线 V2 建议优先使用 Repository + SQL，不再新增“万能 action 存储过程”。
