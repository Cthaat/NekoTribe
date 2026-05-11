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
--   3. 群组模块保留现有表、函数、过程和视图的整体思路，并纳入 V2 正式模型。
--   4. 去掉 V1 中最影响 V2 开发的模型问题:
--      - n_follows 混装 follow / block / mute
--      - n_likes 同时承担帖子点赞与评论点赞
--      - n_media 既做资源库又直接绑定帖子
--      - n_user_sessions 直接保存原始 token CLOBs
--      - tweets / hashtags 命名不适合 V2 的 posts / tags 资源设计
--
-- 重要说明:
--   1. 这是新的 V2 基线脚本，不会覆盖原 V1 SQL 文件。
--   2. 建议在新的 schema 或新的开发环境中执行。
--   3. 如果你的数据库里已经存在同名 tablespace / user，请先手动注释掉“环境初始化”部分。
--   4. 本脚本目标是“可直接开始 V2 接口开发与联调”，因此包含开发期可选测试数据与物化视图。
--
-- 执行约定:
--   1. 推荐使用 SQL*Plus / SQLcl 执行；执行前可设置 SET DEFINE OFF、SET SERVEROUTPUT ON。
--   2. ALTER SESSION SET CONTAINER 和“环境初始化”部分依赖具体 Oracle 部署，可按目标环境注释。
--   3. 生产环境必须替换示例密码、datafile 路径和 tablespace 规划，不要直接复用文档默认值。
--   4. 应用层只使用哈希后的 token / 验证码；数据库脚本不保存任何 token 或验证码原文。
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
--   内容审核           -> n_moderation_reports + n_moderation_cases + n_moderation_actions
--                         + n_moderation_user_restrictions + n_moderation_settings
--
-- V2 正式保留:
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
--   /reports/*
--   /moderation/*
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
CREATE SEQUENCE seq_moderation_report_id START WITH 1100000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 50;
CREATE SEQUENCE seq_moderation_case_id START WITH 1200000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 50;
CREATE SEQUENCE seq_moderation_action_id START WITH 1300000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 50;
CREATE SEQUENCE seq_moderation_restriction_id START WITH 1400000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 50;

-- 群组模块延续原有独立序列
CREATE SEQUENCE seq_group_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE seq_group_member_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE seq_group_post_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE seq_group_comment_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE seq_group_invite_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE seq_group_audit_log_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE seq_group_post_like_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE seq_group_comment_like_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE seq_chat_channel_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE seq_chat_message_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE seq_chat_message_media_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE seq_direct_conversation_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE seq_direct_message_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

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
COMMENT ON TABLE n_users IS '用户主表';
COMMENT ON COLUMN n_users.user_id IS '用户主键ID';
COMMENT ON COLUMN n_users.email IS '邮箱';
COMMENT ON COLUMN n_users.username IS '用户名';
COMMENT ON COLUMN n_users.password_hash IS '密码哈希';
COMMENT ON COLUMN n_users.avatar_url IS '头像地址';
COMMENT ON COLUMN n_users.avatar_media_id IS '头像媒体ID';
COMMENT ON COLUMN n_users.display_name IS '显示名称';
COMMENT ON COLUMN n_users.bio IS '个人简介';
COMMENT ON COLUMN n_users.location IS '位置';
COMMENT ON COLUMN n_users.website IS '个人网站';
COMMENT ON COLUMN n_users.birth_date IS '出生日期';
COMMENT ON COLUMN n_users.phone IS '手机号';
COMMENT ON COLUMN n_users.email_verified_at IS '邮箱验证时间';
COMMENT ON COLUMN n_users.is_verified IS '是否认证';
COMMENT ON COLUMN n_users.is_active IS '是否启用';
COMMENT ON COLUMN n_users.status IS '账户状态（active/disabled/suspended/pending）';
COMMENT ON COLUMN n_users.created_at IS '创建时间';
COMMENT ON COLUMN n_users.updated_at IS '更新时间';
COMMENT ON COLUMN n_users.last_login_at IS '最后登录时间';
COMMENT ON COLUMN n_users.created_by IS '创建人';
COMMENT ON COLUMN n_users.updated_by IS '更新人';


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
COMMENT ON TABLE n_user_stats IS '用户统计表';
COMMENT ON COLUMN n_user_stats.user_id IS '用户ID';
COMMENT ON COLUMN n_user_stats.followers_count IS '粉丝数';
COMMENT ON COLUMN n_user_stats.following_count IS '关注数';
COMMENT ON COLUMN n_user_stats.posts_count IS '发帖数';
COMMENT ON COLUMN n_user_stats.likes_count IS '点赞数';
COMMENT ON COLUMN n_user_stats.bookmarks_count IS '收藏数';
COMMENT ON COLUMN n_user_stats.comments_count IS '评论数';
COMMENT ON COLUMN n_user_stats.updated_at IS '更新时间';


-- 4.3 OTP 事件表
CREATE TABLE n_auth_otp_events (
    otp_event_id            NUMBER(15)      PRIMARY KEY,
    account                 VARCHAR2(100)   NOT NULL,
    otp_type                VARCHAR2(30)    NOT NULL CHECK (otp_type IN ('register', 'password_reset', 'change_email')),
    send_channel            VARCHAR2(20)    DEFAULT 'email' NOT NULL CHECK (send_channel IN ('email', 'sms')),
    verification_code_hash  VARCHAR2(255)   NOT NULL,
    verification_id         VARCHAR2(128)   DEFAULT RAWTOHEX(SYS_GUID()) NOT NULL,
    expires_at              TIMESTAMP       NOT NULL,
    verified_at             TIMESTAMP,
    created_at              TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT uk_auth_otp_verification_id UNIQUE (verification_id)
) TABLESPACE neko_data;
COMMENT ON TABLE n_auth_otp_events IS '验证码事件表';
COMMENT ON COLUMN n_auth_otp_events.otp_event_id IS '验证码事件ID';
COMMENT ON COLUMN n_auth_otp_events.account IS '账号（邮箱或用户名）';
COMMENT ON COLUMN n_auth_otp_events.otp_type IS '验证码用途';
COMMENT ON COLUMN n_auth_otp_events.send_channel IS '发送渠道（email/sms）';
COMMENT ON COLUMN n_auth_otp_events.verification_code_hash IS '验证码哈希';
COMMENT ON COLUMN n_auth_otp_events.verification_id IS '验证ID';
COMMENT ON COLUMN n_auth_otp_events.expires_at IS '过期时间';
COMMENT ON COLUMN n_auth_otp_events.verified_at IS '验证时间';
COMMENT ON COLUMN n_auth_otp_events.created_at IS '创建时间';


-- 4.4 会话表
-- 说明:
--   不再直接保存 access_token / refresh_token 原文。
--   session_id 与 access_jti 都允许由应用生成；数据库也提供默认兜底。
CREATE TABLE n_auth_sessions (
    session_id                VARCHAR2(128)  PRIMARY KEY,
    user_id                   NUMBER(10)     NOT NULL,
    access_jti                VARCHAR2(128)  NOT NULL,
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
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT uk_auth_sessions_access_jti UNIQUE (access_jti),
    CONSTRAINT uk_auth_sessions_refresh_hash UNIQUE (refresh_token_hash),
    CONSTRAINT ck_auth_sessions_expiry CHECK (refresh_token_expires_at > access_token_expires_at)
) TABLESPACE neko_data;
COMMENT ON TABLE n_auth_sessions IS '认证会话表';
COMMENT ON COLUMN n_auth_sessions.session_id IS '会话ID';
COMMENT ON COLUMN n_auth_sessions.user_id IS '用户ID';
COMMENT ON COLUMN n_auth_sessions.access_jti IS '访问令牌唯一标识（JTI）';
COMMENT ON COLUMN n_auth_sessions.refresh_token_hash IS '刷新令牌哈希';
COMMENT ON COLUMN n_auth_sessions.device_info IS '设备信息';
COMMENT ON COLUMN n_auth_sessions.device_fingerprint IS '设备指纹';
COMMENT ON COLUMN n_auth_sessions.ip_address IS 'IP地址';
COMMENT ON COLUMN n_auth_sessions.user_agent IS '用户代理';
COMMENT ON COLUMN n_auth_sessions.access_token_expires_at IS '访问令牌过期时间';
COMMENT ON COLUMN n_auth_sessions.refresh_token_expires_at IS '刷新令牌过期时间';
COMMENT ON COLUMN n_auth_sessions.last_accessed_at IS '最后访问时间';
COMMENT ON COLUMN n_auth_sessions.last_refresh_at IS '最后刷新时间';
COMMENT ON COLUMN n_auth_sessions.revoked_at IS '撤销时间';
COMMENT ON COLUMN n_auth_sessions.created_at IS '创建时间';


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
COMMENT ON TABLE n_user_follows IS '用户关注关系表';
COMMENT ON COLUMN n_user_follows.follow_id IS '关注关系ID';
COMMENT ON COLUMN n_user_follows.follower_id IS '关注者用户ID';
COMMENT ON COLUMN n_user_follows.following_id IS '被关注用户ID';
COMMENT ON COLUMN n_user_follows.status IS '关注状态（active/cancelled）';
COMMENT ON COLUMN n_user_follows.created_at IS '创建时间';
COMMENT ON COLUMN n_user_follows.updated_at IS '更新时间';


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
COMMENT ON TABLE n_user_blocks IS '用户屏蔽关系表';
COMMENT ON COLUMN n_user_blocks.block_id IS '屏蔽关系ID';
COMMENT ON COLUMN n_user_blocks.user_id IS '用户ID';
COMMENT ON COLUMN n_user_blocks.target_user_id IS '目标用户ID';
COMMENT ON COLUMN n_user_blocks.created_at IS '创建时间';


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
COMMENT ON TABLE n_user_mutes IS '用户静音关系表';
COMMENT ON COLUMN n_user_mutes.mute_id IS '静音关系ID';
COMMENT ON COLUMN n_user_mutes.user_id IS '用户ID';
COMMENT ON COLUMN n_user_mutes.target_user_id IS '目标用户ID';
COMMENT ON COLUMN n_user_mutes.expires_at IS '过期时间';
COMMENT ON COLUMN n_user_mutes.created_at IS '创建时间';


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
        REFERENCES n_posts(post_id),
    CONSTRAINT ck_posts_type_refs CHECK (
        (post_type = 'post' AND reply_to_post_id IS NULL AND repost_of_post_id IS NULL AND quoted_post_id IS NULL)
        OR (post_type = 'reply' AND reply_to_post_id IS NOT NULL AND repost_of_post_id IS NULL AND quoted_post_id IS NULL)
        OR (post_type = 'repost' AND reply_to_post_id IS NULL AND repost_of_post_id IS NOT NULL AND quoted_post_id IS NULL)
        OR (post_type = 'quote' AND reply_to_post_id IS NULL AND repost_of_post_id IS NULL AND quoted_post_id IS NOT NULL)
    )
) TABLESPACE neko_data;
COMMENT ON TABLE n_posts IS '帖子主表';
COMMENT ON COLUMN n_posts.post_id IS '帖子ID';
COMMENT ON COLUMN n_posts.author_id IS '作者用户ID';
COMMENT ON COLUMN n_posts.content IS '内容';
COMMENT ON COLUMN n_posts.post_type IS '帖子类型（post/reply/repost/quote）';
COMMENT ON COLUMN n_posts.reply_to_post_id IS '回复目标帖子ID';
COMMENT ON COLUMN n_posts.repost_of_post_id IS '转发来源帖子ID';
COMMENT ON COLUMN n_posts.quoted_post_id IS '引用帖子ID';
COMMENT ON COLUMN n_posts.visibility IS '帖子可见范围（public/followers/mentioned/private）';
COMMENT ON COLUMN n_posts.language IS '语言';
COMMENT ON COLUMN n_posts.location IS '位置';
COMMENT ON COLUMN n_posts.is_deleted IS '是否删除';
COMMENT ON COLUMN n_posts.deleted_at IS '删除时间';
COMMENT ON COLUMN n_posts.created_at IS '创建时间';
COMMENT ON COLUMN n_posts.updated_at IS '更新时间';
COMMENT ON COLUMN n_posts.created_by IS '创建人';
COMMENT ON COLUMN n_posts.updated_by IS '更新人';


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
COMMENT ON TABLE n_post_stats IS '帖子统计表';
COMMENT ON COLUMN n_post_stats.post_id IS '帖子ID';
COMMENT ON COLUMN n_post_stats.likes_count IS '点赞数';
COMMENT ON COLUMN n_post_stats.comments_count IS '评论数';
COMMENT ON COLUMN n_post_stats.replies_count IS '回复数';
COMMENT ON COLUMN n_post_stats.retweets_count IS '转发数';
COMMENT ON COLUMN n_post_stats.views_count IS '浏览数';
COMMENT ON COLUMN n_post_stats.engagement_score IS '互动热度分';
COMMENT ON COLUMN n_post_stats.updated_at IS '更新时间';


-- 4.10 媒体资源表
CREATE TABLE n_media_assets (
    media_id               NUMBER(15)      PRIMARY KEY,
    owner_user_id          NUMBER(10)      NOT NULL,
    media_type             VARCHAR2(20)    NOT NULL CHECK (media_type IN ('image', 'video', 'audio', 'gif', 'file')),
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
    updated_at             TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_media_assets_owner FOREIGN KEY (owner_user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT uk_media_assets_storage_key UNIQUE (storage_key),
    CONSTRAINT ck_media_assets_file_size CHECK (file_size >= 0),
    CONSTRAINT ck_media_assets_dimensions CHECK (
        (width IS NULL OR width > 0)
        AND (height IS NULL OR height > 0)
    ),
    CONSTRAINT ck_media_assets_duration CHECK (duration IS NULL OR duration >= 0)
) TABLESPACE neko_data;
COMMENT ON TABLE n_media_assets IS '媒体资源表';
COMMENT ON COLUMN n_media_assets.media_id IS '媒体ID';
COMMENT ON COLUMN n_media_assets.owner_user_id IS '归属用户ID';
COMMENT ON COLUMN n_media_assets.media_type IS '媒体类型：image-图片，video-视频，audio-音频，gif-动图，file-普通附件';
COMMENT ON COLUMN n_media_assets.file_name IS '文件名';
COMMENT ON COLUMN n_media_assets.storage_key IS '存储键';
COMMENT ON COLUMN n_media_assets.public_url IS '公开访问地址';
COMMENT ON COLUMN n_media_assets.file_size IS '文件大小（字节）';
COMMENT ON COLUMN n_media_assets.mime_type IS 'MIME类型';
COMMENT ON COLUMN n_media_assets.width IS '宽度';
COMMENT ON COLUMN n_media_assets.height IS '高度';
COMMENT ON COLUMN n_media_assets.duration IS '时长（秒）';
COMMENT ON COLUMN n_media_assets.thumbnail_url IS '缩略图地址';
COMMENT ON COLUMN n_media_assets.alt_text IS '媒体替代文本';
COMMENT ON COLUMN n_media_assets.status IS '媒体处理状态（uploaded/processing/ready/failed）';
COMMENT ON COLUMN n_media_assets.created_at IS '创建时间';
COMMENT ON COLUMN n_media_assets.updated_at IS '更新时间';


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
        REFERENCES n_media_assets(media_id) ON DELETE CASCADE,
    CONSTRAINT uk_post_media_order UNIQUE (post_id, sort_order),
    CONSTRAINT ck_post_media_sort_order CHECK (sort_order > 0)
) TABLESPACE neko_data;
COMMENT ON TABLE n_post_media IS '帖子媒体关联表';
COMMENT ON COLUMN n_post_media.post_id IS '帖子ID';
COMMENT ON COLUMN n_post_media.media_id IS '媒体ID';
COMMENT ON COLUMN n_post_media.sort_order IS '排序序号';
COMMENT ON COLUMN n_post_media.created_at IS '创建时间';


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
COMMENT ON TABLE n_post_likes IS '帖子点赞表';
COMMENT ON COLUMN n_post_likes.post_like_id IS '帖子点赞ID';
COMMENT ON COLUMN n_post_likes.post_id IS '帖子ID';
COMMENT ON COLUMN n_post_likes.user_id IS '用户ID';
COMMENT ON COLUMN n_post_likes.created_at IS '创建时间';


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
COMMENT ON TABLE n_post_bookmarks IS '帖子收藏表';
COMMENT ON COLUMN n_post_bookmarks.bookmark_id IS '收藏ID';
COMMENT ON COLUMN n_post_bookmarks.post_id IS '帖子ID';
COMMENT ON COLUMN n_post_bookmarks.user_id IS '用户ID';
COMMENT ON COLUMN n_post_bookmarks.created_at IS '创建时间';


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
        REFERENCES n_comments(comment_id),
    CONSTRAINT fk_comments_root FOREIGN KEY (root_comment_id)
        REFERENCES n_comments(comment_id)
) TABLESPACE neko_data;
COMMENT ON TABLE n_comments IS '评论主表';
COMMENT ON COLUMN n_comments.comment_id IS '评论ID';
COMMENT ON COLUMN n_comments.post_id IS '帖子ID';
COMMENT ON COLUMN n_comments.user_id IS '用户ID';
COMMENT ON COLUMN n_comments.parent_comment_id IS '父评论ID';
COMMENT ON COLUMN n_comments.root_comment_id IS '根评论ID';
COMMENT ON COLUMN n_comments.content IS '内容';
COMMENT ON COLUMN n_comments.is_deleted IS '是否删除';
COMMENT ON COLUMN n_comments.deleted_at IS '删除时间';
COMMENT ON COLUMN n_comments.created_at IS '创建时间';
COMMENT ON COLUMN n_comments.updated_at IS '更新时间';


-- 4.15 评论统计表
CREATE TABLE n_comment_stats (
    comment_id             NUMBER(15)      PRIMARY KEY,
    likes_count            NUMBER(10)      DEFAULT 0 NOT NULL,
    replies_count          NUMBER(10)      DEFAULT 0 NOT NULL,
    updated_at             TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_comment_stats_comment FOREIGN KEY (comment_id)
        REFERENCES n_comments(comment_id) ON DELETE CASCADE
) TABLESPACE neko_data;
COMMENT ON TABLE n_comment_stats IS '评论统计表';
COMMENT ON COLUMN n_comment_stats.comment_id IS '评论ID';
COMMENT ON COLUMN n_comment_stats.likes_count IS '点赞数';
COMMENT ON COLUMN n_comment_stats.replies_count IS '回复数';
COMMENT ON COLUMN n_comment_stats.updated_at IS '更新时间';


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
COMMENT ON TABLE n_comment_likes IS '评论点赞表';
COMMENT ON COLUMN n_comment_likes.comment_like_id IS '评论点赞ID';
COMMENT ON COLUMN n_comment_likes.comment_id IS '评论ID';
COMMENT ON COLUMN n_comment_likes.user_id IS '用户ID';
COMMENT ON COLUMN n_comment_likes.created_at IS '创建时间';


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
COMMENT ON TABLE n_tags IS '标签表';
COMMENT ON COLUMN n_tags.tag_id IS '标签ID';
COMMENT ON COLUMN n_tags.name IS '名称';
COMMENT ON COLUMN n_tags.name_lower IS '名称小写';
COMMENT ON COLUMN n_tags.usage_count IS '使用次数';
COMMENT ON COLUMN n_tags.trending_score IS '趋势分';
COMMENT ON COLUMN n_tags.is_trending IS '是否热门';
COMMENT ON COLUMN n_tags.created_at IS '创建时间';
COMMENT ON COLUMN n_tags.updated_at IS '更新时间';


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
COMMENT ON TABLE n_post_tags IS '帖子标签关联表';
COMMENT ON COLUMN n_post_tags.post_id IS '帖子ID';
COMMENT ON COLUMN n_post_tags.tag_id IS '标签ID';
COMMENT ON COLUMN n_post_tags.created_at IS '创建时间';


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
COMMENT ON TABLE n_post_mentions IS '帖子提及关联表';
COMMENT ON COLUMN n_post_mentions.post_id IS '帖子ID';
COMMENT ON COLUMN n_post_mentions.mentioned_user_id IS '被提及用户ID';
COMMENT ON COLUMN n_post_mentions.created_at IS '创建时间';


-- 4.20 通知主表
CREATE TABLE n_notifications (
    notification_id         NUMBER(15)      PRIMARY KEY,
    user_id                 NUMBER(10)      NOT NULL,
    actor_id                NUMBER(10),
    type                    VARCHAR2(30)    NOT NULL,
    title                   VARCHAR2(200),
    message                 VARCHAR2(1000),
    resource_type           VARCHAR2(30),
    resource_id             NUMBER(19),
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
COMMENT ON TABLE n_notifications IS '通知主表';
COMMENT ON COLUMN n_notifications.notification_id IS '通知ID';
COMMENT ON COLUMN n_notifications.user_id IS '用户ID';
COMMENT ON COLUMN n_notifications.actor_id IS '行为发起人用户ID';
COMMENT ON COLUMN n_notifications.type IS '通知类型';
COMMENT ON COLUMN n_notifications.title IS '标题';
COMMENT ON COLUMN n_notifications.message IS '消息内容';
COMMENT ON COLUMN n_notifications.resource_type IS '资源类型';
COMMENT ON COLUMN n_notifications.resource_id IS '资源ID';
COMMENT ON COLUMN n_notifications.priority IS '优先级';
COMMENT ON COLUMN n_notifications.is_read IS '是否已读';
COMMENT ON COLUMN n_notifications.read_at IS '已读时间';
COMMENT ON COLUMN n_notifications.deleted_at IS '删除时间';
COMMENT ON COLUMN n_notifications.metadata_json IS '扩展元数据（JSON）';
COMMENT ON COLUMN n_notifications.created_at IS '创建时间';


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
COMMENT ON TABLE n_notification_preferences IS '通知偏好表';
COMMENT ON COLUMN n_notification_preferences.user_id IS '用户ID';
COMMENT ON COLUMN n_notification_preferences.notification_type IS '通知类型';
COMMENT ON COLUMN n_notification_preferences.is_enabled IS '是否启用';
COMMENT ON COLUMN n_notification_preferences.updated_at IS '更新时间';


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
COMMENT ON TABLE n_user_settings IS '用户设置表';
COMMENT ON COLUMN n_user_settings.user_id IS '用户ID';
COMMENT ON COLUMN n_user_settings.two_factor_enabled IS '是否开启双因素认证';
COMMENT ON COLUMN n_user_settings.login_alerts IS '是否开启登录提醒';
COMMENT ON COLUMN n_user_settings.profile_visibility IS '资料可见性';
COMMENT ON COLUMN n_user_settings.show_online_status IS '是否显示在线状态';
COMMENT ON COLUMN n_user_settings.allow_dm_from_strangers IS '是否允许陌生人私信';
COMMENT ON COLUMN n_user_settings.push_notification_enabled IS '是否开启推送通知';
COMMENT ON COLUMN n_user_settings.email_notification_enabled IS '是否开启邮件通知';
COMMENT ON COLUMN n_user_settings.updated_at IS '更新时间';


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
COMMENT ON TABLE n_account_statements IS '账户处置记录表';
COMMENT ON COLUMN n_account_statements.statement_id IS '处置记录ID';
COMMENT ON COLUMN n_account_statements.user_id IS '用户ID';
COMMENT ON COLUMN n_account_statements.statement_type IS '处置类型';
COMMENT ON COLUMN n_account_statements.title IS '标题';
COMMENT ON COLUMN n_account_statements.message IS '消息内容';
COMMENT ON COLUMN n_account_statements.policy_code IS '策略编码';
COMMENT ON COLUMN n_account_statements.status IS '处理状态（unread/read/resolved/dismissed/appealed）';
COMMENT ON COLUMN n_account_statements.created_at IS '创建时间';
COMMENT ON COLUMN n_account_statements.updated_at IS '更新时间';


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
COMMENT ON TABLE n_statement_appeals IS '申诉表';
COMMENT ON COLUMN n_statement_appeals.appeal_id IS '申诉ID';
COMMENT ON COLUMN n_statement_appeals.statement_id IS '处置记录ID';
COMMENT ON COLUMN n_statement_appeals.user_id IS '用户ID';
COMMENT ON COLUMN n_statement_appeals.appeal_message IS '申诉内容';
COMMENT ON COLUMN n_statement_appeals.appeal_status IS '申诉状态（pending/approved/rejected）';
COMMENT ON COLUMN n_statement_appeals.admin_response IS '管理员回复';
COMMENT ON COLUMN n_statement_appeals.created_at IS '创建时间';
COMMENT ON COLUMN n_statement_appeals.updated_at IS '更新时间';


-- 4.25 审核举报表
CREATE TABLE n_moderation_reports (
    report_id                NUMBER(15)      PRIMARY KEY,
    target_type              VARCHAR2(20)    NOT NULL,
    target_id                NUMBER(15)      NOT NULL,
    reporter_user_id         NUMBER(10),
    reason                   VARCHAR2(30)    NOT NULL,
    description              VARCHAR2(1000),
    evidence_url             VARCHAR2(1000),
    status                   VARCHAR2(20)    DEFAULT 'pending' NOT NULL,
    priority                 VARCHAR2(20)    DEFAULT 'normal' NOT NULL,
    handled_by               NUMBER(10),
    created_at               TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at               TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    resolved_at              TIMESTAMP,
    CONSTRAINT ck_mod_reports_target CHECK (target_type IN ('post', 'comment', 'user')),
    CONSTRAINT ck_mod_reports_reason CHECK (reason IN ('spam', 'harassment', 'hate', 'violence', 'adult', 'misinformation', 'copyright', 'other')),
    CONSTRAINT ck_mod_reports_status CHECK (status IN ('pending', 'in_review', 'resolved', 'dismissed')),
    CONSTRAINT ck_mod_reports_priority CHECK (priority IN ('low', 'normal', 'high', 'urgent')),
    CONSTRAINT fk_mod_reports_reporter FOREIGN KEY (reporter_user_id)
        REFERENCES n_users(user_id),
    CONSTRAINT fk_mod_reports_handler FOREIGN KEY (handled_by)
        REFERENCES n_users(user_id)
) TABLESPACE neko_data;
COMMENT ON TABLE n_moderation_reports IS '内容举报记录表';
COMMENT ON COLUMN n_moderation_reports.report_id IS '举报ID';
COMMENT ON COLUMN n_moderation_reports.target_type IS '举报目标类型（post/comment/user）';
COMMENT ON COLUMN n_moderation_reports.target_id IS '举报目标ID';
COMMENT ON COLUMN n_moderation_reports.reporter_user_id IS '举报人用户ID';
COMMENT ON COLUMN n_moderation_reports.reason IS '举报原因';
COMMENT ON COLUMN n_moderation_reports.description IS '举报补充说明';
COMMENT ON COLUMN n_moderation_reports.evidence_url IS '证据链接';
COMMENT ON COLUMN n_moderation_reports.status IS '举报状态（pending/in_review/resolved/dismissed）';
COMMENT ON COLUMN n_moderation_reports.priority IS '优先级（low/normal/high/urgent）';
COMMENT ON COLUMN n_moderation_reports.handled_by IS '处理人用户ID';
COMMENT ON COLUMN n_moderation_reports.created_at IS '创建时间';
COMMENT ON COLUMN n_moderation_reports.updated_at IS '更新时间';
COMMENT ON COLUMN n_moderation_reports.resolved_at IS '处理完成时间';


-- 4.26 审核案件表
CREATE TABLE n_moderation_cases (
    case_id                  NUMBER(15)      PRIMARY KEY,
    target_type              VARCHAR2(20)    NOT NULL,
    target_id                NUMBER(15)      NOT NULL,
    status                   VARCHAR2(20)    DEFAULT 'pending' NOT NULL,
    priority                 VARCHAR2(20)    DEFAULT 'normal' NOT NULL,
    assigned_to              NUMBER(10),
    report_count             NUMBER(10)      DEFAULT 0 NOT NULL,
    latest_reported_at       TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    created_at               TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at               TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    resolved_at              TIMESTAMP,
    CONSTRAINT uk_mod_cases_target UNIQUE (target_type, target_id),
    CONSTRAINT ck_mod_cases_target CHECK (target_type IN ('post', 'comment', 'user')),
    CONSTRAINT ck_mod_cases_status CHECK (status IN ('pending', 'approved', 'rejected', 'flagged', 'removed', 'restored')),
    CONSTRAINT ck_mod_cases_priority CHECK (priority IN ('low', 'normal', 'high', 'urgent')),
    CONSTRAINT fk_mod_cases_assignee FOREIGN KEY (assigned_to)
        REFERENCES n_users(user_id)
) TABLESPACE neko_data;
COMMENT ON TABLE n_moderation_cases IS '审核案件队列表';
COMMENT ON COLUMN n_moderation_cases.case_id IS '审核案件ID';
COMMENT ON COLUMN n_moderation_cases.target_type IS '审核目标类型（post/comment/user）';
COMMENT ON COLUMN n_moderation_cases.target_id IS '审核目标ID';
COMMENT ON COLUMN n_moderation_cases.status IS '案件状态（pending/approved/rejected/flagged/removed/restored）';
COMMENT ON COLUMN n_moderation_cases.priority IS '优先级（low/normal/high/urgent）';
COMMENT ON COLUMN n_moderation_cases.assigned_to IS '领取/分配的审核员用户ID';
COMMENT ON COLUMN n_moderation_cases.report_count IS '关联举报数量';
COMMENT ON COLUMN n_moderation_cases.latest_reported_at IS '最近举报时间';
COMMENT ON COLUMN n_moderation_cases.created_at IS '创建时间';
COMMENT ON COLUMN n_moderation_cases.updated_at IS '更新时间';
COMMENT ON COLUMN n_moderation_cases.resolved_at IS '处理完成时间';


-- 4.27 审核操作日志表
CREATE TABLE n_moderation_actions (
    action_id                NUMBER(15)      PRIMARY KEY,
    case_id                  NUMBER(15),
    target_type              VARCHAR2(20)    NOT NULL,
    target_id                NUMBER(15)      NOT NULL,
    action                   VARCHAR2(30)    NOT NULL,
    moderator_user_id        NUMBER(10)      NOT NULL,
    reason                   VARCHAR2(200),
    note                     CLOB,
    duration_hours           NUMBER(10),
    created_at               TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_mod_actions_case FOREIGN KEY (case_id)
        REFERENCES n_moderation_cases(case_id),
    CONSTRAINT fk_mod_actions_user FOREIGN KEY (moderator_user_id)
        REFERENCES n_users(user_id)
) TABLESPACE neko_data;
COMMENT ON TABLE n_moderation_actions IS '审核操作留痕表';
COMMENT ON COLUMN n_moderation_actions.action_id IS '审核操作ID';
COMMENT ON COLUMN n_moderation_actions.case_id IS '关联审核案件ID';
COMMENT ON COLUMN n_moderation_actions.target_type IS '操作目标类型（post/comment/user）';
COMMENT ON COLUMN n_moderation_actions.target_id IS '操作目标ID';
COMMENT ON COLUMN n_moderation_actions.action IS '审核动作';
COMMENT ON COLUMN n_moderation_actions.moderator_user_id IS '审核员用户ID';
COMMENT ON COLUMN n_moderation_actions.reason IS '动作原因';
COMMENT ON COLUMN n_moderation_actions.note IS '审核备注';
COMMENT ON COLUMN n_moderation_actions.duration_hours IS '处罚持续小时数';
COMMENT ON COLUMN n_moderation_actions.created_at IS '创建时间';


-- 4.28 用户处罚/限制表
CREATE TABLE n_moderation_user_restrictions (
    restriction_id           NUMBER(15)      PRIMARY KEY,
    user_id                  NUMBER(10)      NOT NULL,
    restriction_type         VARCHAR2(20)    NOT NULL,
    status                   VARCHAR2(20)    DEFAULT 'active' NOT NULL,
    reason                   VARCHAR2(200),
    starts_at                TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    ends_at                  TIMESTAMP,
    created_by               NUMBER(10)      NOT NULL,
    revoked_by               NUMBER(10),
    revoked_at               TIMESTAMP,
    CONSTRAINT ck_mod_restriction_type CHECK (restriction_type IN ('ban', 'mute')),
    CONSTRAINT ck_mod_restriction_status CHECK (status IN ('active', 'revoked', 'expired')),
    CONSTRAINT fk_mod_restriction_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id),
    CONSTRAINT fk_mod_restriction_created FOREIGN KEY (created_by)
        REFERENCES n_users(user_id),
    CONSTRAINT fk_mod_restriction_revoked FOREIGN KEY (revoked_by)
        REFERENCES n_users(user_id)
) TABLESPACE neko_data;
COMMENT ON TABLE n_moderation_user_restrictions IS '用户处罚与限制表';
COMMENT ON COLUMN n_moderation_user_restrictions.restriction_id IS '处罚/限制ID';
COMMENT ON COLUMN n_moderation_user_restrictions.user_id IS '被处罚用户ID';
COMMENT ON COLUMN n_moderation_user_restrictions.restriction_type IS '限制类型（ban/mute）';
COMMENT ON COLUMN n_moderation_user_restrictions.status IS '限制状态（active/revoked/expired）';
COMMENT ON COLUMN n_moderation_user_restrictions.reason IS '限制原因';
COMMENT ON COLUMN n_moderation_user_restrictions.starts_at IS '开始时间';
COMMENT ON COLUMN n_moderation_user_restrictions.ends_at IS '结束时间';
COMMENT ON COLUMN n_moderation_user_restrictions.created_by IS '创建人用户ID';
COMMENT ON COLUMN n_moderation_user_restrictions.revoked_by IS '撤销人用户ID';
COMMENT ON COLUMN n_moderation_user_restrictions.revoked_at IS '撤销时间';


-- 4.29 审核设置表
CREATE TABLE n_moderation_settings (
    setting_key              VARCHAR2(80)    PRIMARY KEY,
    setting_value            VARCHAR2(1000)  NOT NULL,
    value_type               VARCHAR2(20)    DEFAULT 'string' NOT NULL,
    label                    VARCHAR2(120)   NOT NULL,
    description              VARCHAR2(500),
    updated_at               TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by               NUMBER(10),
    CONSTRAINT ck_mod_settings_type CHECK (value_type IN ('boolean', 'number', 'string')),
    CONSTRAINT fk_mod_settings_user FOREIGN KEY (updated_by)
        REFERENCES n_users(user_id)
) TABLESPACE neko_data;
COMMENT ON TABLE n_moderation_settings IS '审核中心配置表';
COMMENT ON COLUMN n_moderation_settings.setting_key IS '配置键';
COMMENT ON COLUMN n_moderation_settings.setting_value IS '配置值';
COMMENT ON COLUMN n_moderation_settings.value_type IS '值类型（boolean/number/string）';
COMMENT ON COLUMN n_moderation_settings.label IS '配置名称';
COMMENT ON COLUMN n_moderation_settings.description IS '配置说明';
COMMENT ON COLUMN n_moderation_settings.updated_at IS '更新时间';
COMMENT ON COLUMN n_moderation_settings.updated_by IS '更新人用户ID';


-- ==========================================
-- 5. 群组模块表（沿用 with-group 设计，作为 V2 正式群组模型）
-- ==========================================

CREATE TABLE n_groups (
    group_id                 NUMBER(19)      PRIMARY KEY,
    name                     VARCHAR2(100)   NOT NULL,
    slug                     VARCHAR2(100)   NOT NULL,
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
    CONSTRAINT uk_groups_slug UNIQUE (slug),
    CONSTRAINT chk_groups_privacy CHECK (privacy IN ('public', 'private', 'secret')),
    CONSTRAINT chk_groups_join_approval CHECK (join_approval IN (0, 1)),
    CONSTRAINT chk_groups_post_perm CHECK (post_permission IN ('all', 'admin_only', 'moderator_up')),
    CONSTRAINT chk_groups_is_active CHECK (is_active IN (0, 1)),
    CONSTRAINT chk_groups_is_deleted CHECK (is_deleted IN (0, 1)),
    CONSTRAINT chk_groups_counts CHECK (member_count >= 0 AND post_count >= 0)
) TABLESPACE neko_data;
COMMENT ON TABLE n_groups IS '群组主表';
COMMENT ON COLUMN n_groups.group_id IS '群组ID';
COMMENT ON COLUMN n_groups.name IS '名称';
COMMENT ON COLUMN n_groups.slug IS '短标识';
COMMENT ON COLUMN n_groups.description IS '描述';
COMMENT ON COLUMN n_groups.avatar_url IS '头像地址';
COMMENT ON COLUMN n_groups.cover_url IS '封面图地址';
COMMENT ON COLUMN n_groups.owner_id IS '所有者用户ID';
COMMENT ON COLUMN n_groups.privacy IS '群组可见性（public/private/secret）';
COMMENT ON COLUMN n_groups.join_approval IS '入群是否需审批';
COMMENT ON COLUMN n_groups.post_permission IS '群组发帖权限（all/admin_only/moderator_up）';
COMMENT ON COLUMN n_groups.member_count IS '成员数';
COMMENT ON COLUMN n_groups.post_count IS '帖子数';
COMMENT ON COLUMN n_groups.is_active IS '是否启用';
COMMENT ON COLUMN n_groups.is_deleted IS '是否删除';
COMMENT ON COLUMN n_groups.created_at IS '创建时间';
COMMENT ON COLUMN n_groups.updated_at IS '更新时间';


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
COMMENT ON COLUMN n_group_members.member_id IS '成员ID';
COMMENT ON COLUMN n_group_members.group_id IS '群组ID';
COMMENT ON COLUMN n_group_members.user_id IS '用户ID';
COMMENT ON COLUMN n_group_members.role IS '成员角色（owner/admin/moderator/member）';
COMMENT ON COLUMN n_group_members.status IS '成员状态（pending/active/muted/banned）';
COMMENT ON COLUMN n_group_members.nickname IS '群昵称';
COMMENT ON COLUMN n_group_members.mute_until IS '禁言截止时间';
COMMENT ON COLUMN n_group_members.ban_reason IS '封禁原因';
COMMENT ON COLUMN n_group_members.invited_by IS '邀请来源用户ID';
COMMENT ON COLUMN n_group_members.joined_at IS '加入时间';
COMMENT ON COLUMN n_group_members.updated_at IS '更新时间';


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
        REFERENCES n_users(user_id) ON DELETE SET NULL,
    CONSTRAINT chk_group_posts_flags CHECK (is_pinned IN (0, 1) AND is_announcement IN (0, 1) AND is_deleted IN (0, 1)),
    CONSTRAINT chk_group_posts_counts CHECK (likes_count >= 0 AND comments_count >= 0 AND views_count >= 0)
) TABLESPACE neko_data;
COMMENT ON TABLE n_group_posts IS '群组帖子表';
COMMENT ON COLUMN n_group_posts.post_id IS '帖子ID';
COMMENT ON COLUMN n_group_posts.group_id IS '群组ID';
COMMENT ON COLUMN n_group_posts.author_id IS '作者用户ID';
COMMENT ON COLUMN n_group_posts.content IS '内容';
COMMENT ON COLUMN n_group_posts.media_urls IS '媒体地址列表';
COMMENT ON COLUMN n_group_posts.is_pinned IS '是否置顶';
COMMENT ON COLUMN n_group_posts.is_announcement IS '是否公告';
COMMENT ON COLUMN n_group_posts.likes_count IS '点赞数';
COMMENT ON COLUMN n_group_posts.comments_count IS '评论数';
COMMENT ON COLUMN n_group_posts.views_count IS '浏览数';
COMMENT ON COLUMN n_group_posts.is_deleted IS '是否删除';
COMMENT ON COLUMN n_group_posts.deleted_by IS '删除操作人用户ID';
COMMENT ON COLUMN n_group_posts.delete_reason IS '删除原因';
COMMENT ON COLUMN n_group_posts.created_at IS '创建时间';
COMMENT ON COLUMN n_group_posts.updated_at IS '更新时间';


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
        REFERENCES n_users(user_id) ON DELETE SET NULL,
    CONSTRAINT chk_group_comments_flags CHECK (is_deleted IN (0, 1)),
    CONSTRAINT chk_group_comments_counts CHECK (likes_count >= 0)
) TABLESPACE neko_data;
COMMENT ON TABLE n_group_comments IS '群组评论表';
COMMENT ON COLUMN n_group_comments.comment_id IS '评论ID';
COMMENT ON COLUMN n_group_comments.post_id IS '帖子ID';
COMMENT ON COLUMN n_group_comments.author_id IS '作者用户ID';
COMMENT ON COLUMN n_group_comments.parent_comment_id IS '父评论ID';
COMMENT ON COLUMN n_group_comments.reply_to_user_id IS '回复目标用户ID';
COMMENT ON COLUMN n_group_comments.content IS '内容';
COMMENT ON COLUMN n_group_comments.likes_count IS '点赞数';
COMMENT ON COLUMN n_group_comments.is_deleted IS '是否删除';
COMMENT ON COLUMN n_group_comments.deleted_by IS '删除操作人用户ID';
COMMENT ON COLUMN n_group_comments.delete_reason IS '删除原因';
COMMENT ON COLUMN n_group_comments.created_at IS '创建时间';
COMMENT ON COLUMN n_group_comments.updated_at IS '更新时间';


CREATE TABLE n_group_invites (
    invite_id                 NUMBER(19)      PRIMARY KEY,
    group_id                  NUMBER(19)      NOT NULL,
    inviter_id                NUMBER(10)      NOT NULL,
    invitee_id                NUMBER(10),
    invite_code               VARCHAR2(32),
    status                    VARCHAR2(20)    DEFAULT 'pending' NOT NULL,
    message                   VARCHAR2(200),
    max_uses                  NUMBER(5)       DEFAULT 1,
    used_count                NUMBER(5)       DEFAULT 0 NOT NULL,
    expires_at                TIMESTAMP,
    created_at                TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    responded_at              TIMESTAMP,
    CONSTRAINT fk_group_invites_group FOREIGN KEY (group_id)
        REFERENCES n_groups(group_id) ON DELETE CASCADE,
    CONSTRAINT fk_group_invites_inviter FOREIGN KEY (inviter_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_group_invites_invitee FOREIGN KEY (invitee_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT uk_group_invites_code UNIQUE (invite_code),
    CONSTRAINT chk_invite_status CHECK (status IN ('pending', 'accepted', 'rejected', 'expired')),
    CONSTRAINT chk_invite_type CHECK (invitee_id IS NOT NULL OR invite_code IS NOT NULL),
    CONSTRAINT chk_invite_counts CHECK (
        used_count >= 0
        AND (max_uses IS NULL OR max_uses > 0)
        AND (max_uses IS NULL OR used_count <= max_uses)
    )
) TABLESPACE neko_data;
COMMENT ON TABLE n_group_invites IS '群组邀请表';
COMMENT ON COLUMN n_group_invites.invite_id IS '邀请ID';
COMMENT ON COLUMN n_group_invites.group_id IS '群组ID';
COMMENT ON COLUMN n_group_invites.inviter_id IS '邀请人用户ID';
COMMENT ON COLUMN n_group_invites.invitee_id IS '被邀请用户ID';
COMMENT ON COLUMN n_group_invites.invite_code IS '邀请码';
COMMENT ON COLUMN n_group_invites.status IS '邀请状态（pending/accepted/rejected/expired）';
COMMENT ON COLUMN n_group_invites.message IS '消息内容';
COMMENT ON COLUMN n_group_invites.max_uses IS '最大使用次数';
COMMENT ON COLUMN n_group_invites.used_count IS '已使用次数';
COMMENT ON COLUMN n_group_invites.expires_at IS '过期时间';
COMMENT ON COLUMN n_group_invites.created_at IS '创建时间';
COMMENT ON COLUMN n_group_invites.responded_at IS '响应时间';


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
COMMENT ON COLUMN n_group_audit_logs.log_id IS '日志ID';
COMMENT ON COLUMN n_group_audit_logs.group_id IS '群组ID';
COMMENT ON COLUMN n_group_audit_logs.actor_id IS '行为发起人用户ID';
COMMENT ON COLUMN n_group_audit_logs.target_user_id IS '目标用户ID';
COMMENT ON COLUMN n_group_audit_logs.target_post_id IS '目标帖子ID';
COMMENT ON COLUMN n_group_audit_logs.target_comment_id IS '目标评论ID';
COMMENT ON COLUMN n_group_audit_logs.action IS '操作动作';
COMMENT ON COLUMN n_group_audit_logs.details IS '详情';
COMMENT ON COLUMN n_group_audit_logs.ip_address IS 'IP地址';
COMMENT ON COLUMN n_group_audit_logs.user_agent IS '用户代理';
COMMENT ON COLUMN n_group_audit_logs.created_at IS '创建时间';


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
COMMENT ON COLUMN n_group_post_likes.like_id IS '点赞ID';
COMMENT ON COLUMN n_group_post_likes.post_id IS '帖子ID';
COMMENT ON COLUMN n_group_post_likes.user_id IS '用户ID';
COMMENT ON COLUMN n_group_post_likes.created_at IS '创建时间';


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
COMMENT ON COLUMN n_group_comment_likes.like_id IS '点赞ID';
COMMENT ON COLUMN n_group_comment_likes.comment_id IS '评论ID';
COMMENT ON COLUMN n_group_comment_likes.user_id IS '用户ID';
COMMENT ON COLUMN n_group_comment_likes.created_at IS '创建时间';


CREATE TABLE n_chat_channels (
    channel_id               NUMBER(19)      PRIMARY KEY,
    group_id                 NUMBER(19)      NOT NULL,
    name                     VARCHAR2(100)   NOT NULL,
    channel_type             VARCHAR2(20)    DEFAULT 'text' NOT NULL,
    category                 VARCHAR2(50)    DEFAULT '文字频道' NOT NULL,
    position                 NUMBER(10)      DEFAULT 0 NOT NULL,
    is_private               NUMBER(1)       DEFAULT 0 NOT NULL,
    is_deleted               NUMBER(1)       DEFAULT 0 NOT NULL,
    created_by               NUMBER(10)      NOT NULL,
    last_message_id          NUMBER(19),
    last_message_at          TIMESTAMP,
    message_count            NUMBER(10)      DEFAULT 0 NOT NULL,
    created_at               TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at               TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT fk_chat_channels_group FOREIGN KEY (group_id)
        REFERENCES n_groups(group_id) ON DELETE CASCADE,
    CONSTRAINT fk_chat_channels_creator FOREIGN KEY (created_by)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT chk_chat_channel_type CHECK (channel_type IN ('text', 'announcement', 'voice', 'video')),
    CONSTRAINT chk_chat_channel_flags CHECK (is_private IN (0, 1) AND is_deleted IN (0, 1)),
    CONSTRAINT chk_chat_channel_counts CHECK (message_count >= 0)
) TABLESPACE neko_data;
COMMENT ON TABLE n_chat_channels IS '群组聊天频道表';
COMMENT ON COLUMN n_chat_channels.channel_id IS '频道ID';
COMMENT ON COLUMN n_chat_channels.group_id IS '群组ID';
COMMENT ON COLUMN n_chat_channels.name IS '频道名称';
COMMENT ON COLUMN n_chat_channels.channel_type IS '频道类型（text/announcement/voice/video）';
COMMENT ON COLUMN n_chat_channels.category IS '频道分组名称';
COMMENT ON COLUMN n_chat_channels.position IS '频道排序值';
COMMENT ON COLUMN n_chat_channels.is_private IS '是否私密频道';
COMMENT ON COLUMN n_chat_channels.is_deleted IS '是否删除';
COMMENT ON COLUMN n_chat_channels.created_by IS '创建人用户ID';
COMMENT ON COLUMN n_chat_channels.last_message_id IS '最后消息ID';
COMMENT ON COLUMN n_chat_channels.last_message_at IS '最后消息时间';
COMMENT ON COLUMN n_chat_channels.message_count IS '消息数量';
COMMENT ON COLUMN n_chat_channels.created_at IS '创建时间';
COMMENT ON COLUMN n_chat_channels.updated_at IS '更新时间';


CREATE TABLE n_chat_messages (
    message_id               NUMBER(19)      PRIMARY KEY,
    channel_id               NUMBER(19)      NOT NULL,
    group_id                 NUMBER(19)      NOT NULL,
    author_id                NUMBER(10)      NOT NULL,
    message_type             VARCHAR2(20)    DEFAULT 'text' NOT NULL,
    content                  VARCHAR2(4000),
    reply_to_message_id      NUMBER(19),
    is_pinned                NUMBER(1)       DEFAULT 0 NOT NULL,
    is_deleted               NUMBER(1)       DEFAULT 0 NOT NULL,
    deleted_by               NUMBER(10),
    created_at               TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at               TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    edited_at                TIMESTAMP,
    deleted_at               TIMESTAMP,
    CONSTRAINT fk_chat_messages_channel FOREIGN KEY (channel_id)
        REFERENCES n_chat_channels(channel_id) ON DELETE CASCADE,
    CONSTRAINT fk_chat_messages_group FOREIGN KEY (group_id)
        REFERENCES n_groups(group_id) ON DELETE CASCADE,
    CONSTRAINT fk_chat_messages_author FOREIGN KEY (author_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_chat_messages_reply FOREIGN KEY (reply_to_message_id)
        REFERENCES n_chat_messages(message_id) ON DELETE SET NULL,
    CONSTRAINT fk_chat_messages_deleter FOREIGN KEY (deleted_by)
        REFERENCES n_users(user_id) ON DELETE SET NULL,
    CONSTRAINT chk_chat_message_type CHECK (message_type IN ('text', 'system')),
    CONSTRAINT chk_chat_message_flags CHECK (is_pinned IN (0, 1) AND is_deleted IN (0, 1))
) TABLESPACE neko_data;
COMMENT ON TABLE n_chat_messages IS '群组聊天消息表';
COMMENT ON COLUMN n_chat_messages.message_id IS '消息ID';
COMMENT ON COLUMN n_chat_messages.channel_id IS '频道ID';
COMMENT ON COLUMN n_chat_messages.group_id IS '群组ID';
COMMENT ON COLUMN n_chat_messages.author_id IS '作者用户ID';
COMMENT ON COLUMN n_chat_messages.message_type IS '消息类型（text/system）';
COMMENT ON COLUMN n_chat_messages.content IS '消息文本内容';
COMMENT ON COLUMN n_chat_messages.reply_to_message_id IS '回复目标消息ID';
COMMENT ON COLUMN n_chat_messages.is_pinned IS '是否置顶';
COMMENT ON COLUMN n_chat_messages.is_deleted IS '是否删除';
COMMENT ON COLUMN n_chat_messages.deleted_by IS '删除操作人用户ID';
COMMENT ON COLUMN n_chat_messages.created_at IS '创建时间';
COMMENT ON COLUMN n_chat_messages.updated_at IS '更新时间';
COMMENT ON COLUMN n_chat_messages.edited_at IS '编辑时间';
COMMENT ON COLUMN n_chat_messages.deleted_at IS '删除时间';


CREATE TABLE n_chat_message_media (
    chat_message_media_id    NUMBER(19)      PRIMARY KEY,
    message_id               NUMBER(19)      NOT NULL,
    media_id                 NUMBER(19)      NOT NULL,
    position                 NUMBER(10)      DEFAULT 1 NOT NULL,
    created_at               TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT fk_chat_msg_media_message FOREIGN KEY (message_id)
        REFERENCES n_chat_messages(message_id) ON DELETE CASCADE,
    CONSTRAINT fk_chat_msg_media_asset FOREIGN KEY (media_id)
        REFERENCES n_media_assets(media_id) ON DELETE CASCADE,
    CONSTRAINT uk_chat_msg_media UNIQUE (message_id, media_id)
) TABLESPACE neko_data;
COMMENT ON TABLE n_chat_message_media IS '聊天消息媒体附件关联表';
COMMENT ON COLUMN n_chat_message_media.chat_message_media_id IS '关联ID';
COMMENT ON COLUMN n_chat_message_media.message_id IS '消息ID';
COMMENT ON COLUMN n_chat_message_media.media_id IS '媒体ID';
COMMENT ON COLUMN n_chat_message_media.position IS '附件排序值';
COMMENT ON COLUMN n_chat_message_media.created_at IS '创建时间';


CREATE TABLE n_chat_message_reactions (
    message_id               NUMBER(19)      NOT NULL,
    user_id                  NUMBER(10)      NOT NULL,
    emoji                    VARCHAR2(32)    NOT NULL,
    created_at               TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_chat_message_reactions PRIMARY KEY (message_id, user_id, emoji),
    CONSTRAINT fk_chat_reactions_message FOREIGN KEY (message_id)
        REFERENCES n_chat_messages(message_id) ON DELETE CASCADE,
    CONSTRAINT fk_chat_reactions_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE
) TABLESPACE neko_data;
COMMENT ON TABLE n_chat_message_reactions IS '聊天消息表情反应表';
COMMENT ON COLUMN n_chat_message_reactions.message_id IS '消息ID';
COMMENT ON COLUMN n_chat_message_reactions.user_id IS '用户ID';
COMMENT ON COLUMN n_chat_message_reactions.emoji IS '表情';
COMMENT ON COLUMN n_chat_message_reactions.created_at IS '创建时间';


CREATE TABLE n_chat_channel_reads (
    channel_id               NUMBER(19)      NOT NULL,
    user_id                  NUMBER(10)      NOT NULL,
    last_read_message_id     NUMBER(19),
    last_read_at             TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_chat_channel_reads PRIMARY KEY (channel_id, user_id),
    CONSTRAINT fk_chat_reads_channel FOREIGN KEY (channel_id)
        REFERENCES n_chat_channels(channel_id) ON DELETE CASCADE,
    CONSTRAINT fk_chat_reads_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_chat_reads_message FOREIGN KEY (last_read_message_id)
        REFERENCES n_chat_messages(message_id) ON DELETE SET NULL
) TABLESPACE neko_data;
COMMENT ON TABLE n_chat_channel_reads IS '聊天频道已读状态表';
COMMENT ON COLUMN n_chat_channel_reads.channel_id IS '频道ID';
COMMENT ON COLUMN n_chat_channel_reads.user_id IS '用户ID';
COMMENT ON COLUMN n_chat_channel_reads.last_read_message_id IS '最后已读消息ID';
COMMENT ON COLUMN n_chat_channel_reads.last_read_at IS '最后已读时间';


CREATE TABLE n_chat_channel_mutes (
    channel_id               NUMBER(19)      NOT NULL,
    user_id                  NUMBER(10)      NOT NULL,
    created_at               TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_chat_channel_mutes PRIMARY KEY (channel_id, user_id),
    CONSTRAINT fk_chat_mutes_channel FOREIGN KEY (channel_id)
        REFERENCES n_chat_channels(channel_id) ON DELETE CASCADE,
    CONSTRAINT fk_chat_mutes_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE
) TABLESPACE neko_data;
COMMENT ON TABLE n_chat_channel_mutes IS '聊天频道静音表';
COMMENT ON COLUMN n_chat_channel_mutes.channel_id IS '频道ID';
COMMENT ON COLUMN n_chat_channel_mutes.user_id IS '用户ID';
COMMENT ON COLUMN n_chat_channel_mutes.created_at IS '创建时间';

CREATE TABLE n_direct_conversations (
    conversation_id          NUMBER(19)      PRIMARY KEY,
    user_low_id              NUMBER(19)      NOT NULL,
    user_high_id             NUMBER(19)      NOT NULL,
    created_by               NUMBER(19)      NOT NULL,
    last_message_id          NUMBER(19),
    last_message_at          TIMESTAMP,
    message_count            NUMBER(10)      DEFAULT 0 NOT NULL,
    is_deleted               NUMBER(1)       DEFAULT 0 NOT NULL,
    created_at               TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at               TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_direct_conv_low_user FOREIGN KEY (user_low_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_direct_conv_high_user FOREIGN KEY (user_high_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_direct_conv_creator FOREIGN KEY (created_by)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT uk_direct_conversation_pair UNIQUE (user_low_id, user_high_id),
    CONSTRAINT chk_direct_conversation_pair CHECK (user_low_id < user_high_id),
    CONSTRAINT chk_direct_conversation_flags CHECK (is_deleted IN (0, 1)),
    CONSTRAINT chk_direct_conversation_counts CHECK (message_count >= 0)
) TABLESPACE neko_data;
COMMENT ON TABLE n_direct_conversations IS '私聊会话表';
COMMENT ON COLUMN n_direct_conversations.conversation_id IS '会话ID';
COMMENT ON COLUMN n_direct_conversations.user_low_id IS '较小用户ID';
COMMENT ON COLUMN n_direct_conversations.user_high_id IS '较大用户ID';
COMMENT ON COLUMN n_direct_conversations.created_by IS '创建人用户ID';
COMMENT ON COLUMN n_direct_conversations.last_message_id IS '最后消息ID';
COMMENT ON COLUMN n_direct_conversations.last_message_at IS '最后消息时间';
COMMENT ON COLUMN n_direct_conversations.message_count IS '消息数量';
COMMENT ON COLUMN n_direct_conversations.is_deleted IS '是否删除';

CREATE TABLE n_direct_messages (
    message_id               NUMBER(19)      PRIMARY KEY,
    conversation_id          NUMBER(19)      NOT NULL,
    sender_id                NUMBER(19)      NOT NULL,
    content                  VARCHAR2(4000)  NOT NULL,
    is_deleted               NUMBER(1)       DEFAULT 0 NOT NULL,
    deleted_by               NUMBER(19),
    created_at               TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at               TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    edited_at                TIMESTAMP,
    deleted_at               TIMESTAMP,
    CONSTRAINT fk_direct_messages_conversation FOREIGN KEY (conversation_id)
        REFERENCES n_direct_conversations(conversation_id) ON DELETE CASCADE,
    CONSTRAINT fk_direct_messages_sender FOREIGN KEY (sender_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_direct_messages_deleter FOREIGN KEY (deleted_by)
        REFERENCES n_users(user_id) ON DELETE SET NULL,
    CONSTRAINT chk_direct_message_flags CHECK (is_deleted IN (0, 1))
) TABLESPACE neko_data;
COMMENT ON TABLE n_direct_messages IS '私聊消息表';
COMMENT ON COLUMN n_direct_messages.message_id IS '消息ID';
COMMENT ON COLUMN n_direct_messages.conversation_id IS '会话ID';
COMMENT ON COLUMN n_direct_messages.sender_id IS '发送者用户ID';
COMMENT ON COLUMN n_direct_messages.content IS '消息文本内容';
COMMENT ON COLUMN n_direct_messages.is_deleted IS '是否删除';

CREATE TABLE n_direct_conversation_reads (
    conversation_id          NUMBER(19)      NOT NULL,
    user_id                  NUMBER(19)      NOT NULL,
    last_read_message_id     NUMBER(19),
    last_read_at             TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT pk_direct_conversation_reads PRIMARY KEY (conversation_id, user_id),
    CONSTRAINT fk_direct_reads_conversation FOREIGN KEY (conversation_id)
        REFERENCES n_direct_conversations(conversation_id) ON DELETE CASCADE,
    CONSTRAINT fk_direct_reads_user FOREIGN KEY (user_id)
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_direct_reads_message FOREIGN KEY (last_read_message_id)
        REFERENCES n_direct_messages(message_id) ON DELETE SET NULL
) TABLESPACE neko_data;
COMMENT ON TABLE n_direct_conversation_reads IS '私聊会话已读状态表';
COMMENT ON COLUMN n_direct_conversation_reads.conversation_id IS '会话ID';
COMMENT ON COLUMN n_direct_conversation_reads.user_id IS '用户ID';
COMMENT ON COLUMN n_direct_conversation_reads.last_read_message_id IS '最后已读消息ID';
COMMENT ON COLUMN n_direct_conversation_reads.last_read_at IS '最后已读时间';


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
CREATE INDEX idx_user_blocks_target ON n_user_blocks(target_user_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_user_mutes_user ON n_user_mutes(user_id, expires_at) TABLESPACE neko_index;
CREATE INDEX idx_user_mutes_target ON n_user_mutes(target_user_id, expires_at) TABLESPACE neko_index;

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
CREATE INDEX idx_comments_user ON n_comments(user_id, is_deleted, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_comments_parent ON n_comments(parent_comment_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_comments_root ON n_comments(root_comment_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_comment_likes_comment ON n_comment_likes(comment_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_comment_likes_user ON n_comment_likes(user_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_media_assets_owner ON n_media_assets(owner_user_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_media_assets_status ON n_media_assets(status, media_type) TABLESPACE neko_index;
CREATE INDEX idx_post_media_media ON n_post_media(media_id) TABLESPACE neko_index;

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
CREATE INDEX idx_statement_appeals_user ON n_statement_appeals(user_id, appeal_status, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_mod_reports_target ON n_moderation_reports(target_type, target_id) TABLESPACE neko_index;
CREATE INDEX idx_mod_reports_status ON n_moderation_reports(status, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_mod_cases_status ON n_moderation_cases(status, latest_reported_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_mod_actions_target ON n_moderation_actions(target_type, target_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_mod_restrictions_user ON n_moderation_user_restrictions(user_id, status) TABLESPACE neko_index;

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
CREATE INDEX idx_group_members_invited_by ON n_group_members(invited_by) TABLESPACE neko_index;

CREATE INDEX idx_group_posts_group_time ON n_group_posts(group_id, is_deleted, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_group_posts_group_pinned ON n_group_posts(group_id, is_pinned DESC, is_announcement DESC, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_group_posts_author_id ON n_group_posts(author_id) TABLESPACE neko_index;
CREATE INDEX idx_group_posts_deleted_by ON n_group_posts(deleted_by) TABLESPACE neko_index;

CREATE INDEX idx_group_comments_post_id ON n_group_comments(post_id, is_deleted, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_group_comments_parent_id ON n_group_comments(parent_comment_id) TABLESPACE neko_index;
CREATE INDEX idx_group_comments_author_id ON n_group_comments(author_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_group_comments_reply_to ON n_group_comments(reply_to_user_id) TABLESPACE neko_index;
CREATE INDEX idx_group_comments_deleted_by ON n_group_comments(deleted_by) TABLESPACE neko_index;

CREATE INDEX idx_group_invites_group_id ON n_group_invites(group_id, status) TABLESPACE neko_index;
CREATE INDEX idx_group_invites_inviter_id ON n_group_invites(inviter_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_group_invites_invitee_id ON n_group_invites(invitee_id, status) TABLESPACE neko_index;

CREATE INDEX idx_group_audit_logs_group_time ON n_group_audit_logs(group_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_group_audit_logs_actor_id ON n_group_audit_logs(actor_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_group_audit_logs_target_user ON n_group_audit_logs(target_user_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_group_audit_logs_target_post ON n_group_audit_logs(target_post_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_group_audit_logs_target_comment ON n_group_audit_logs(target_comment_id, created_at DESC) TABLESPACE neko_index;

CREATE INDEX idx_group_post_likes_post_id ON n_group_post_likes(post_id) TABLESPACE neko_index;
CREATE INDEX idx_group_post_likes_user_id ON n_group_post_likes(user_id) TABLESPACE neko_index;
CREATE INDEX idx_group_comment_likes_comment_id ON n_group_comment_likes(comment_id) TABLESPACE neko_index;
CREATE INDEX idx_group_comment_likes_user_id ON n_group_comment_likes(user_id) TABLESPACE neko_index;

-- 群组聊天索引
CREATE INDEX idx_chat_channels_group ON n_chat_channels(group_id, is_deleted, position) TABLESPACE neko_index;
CREATE INDEX idx_chat_channels_last_message ON n_chat_channels(last_message_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_chat_messages_channel_time ON n_chat_messages(channel_id, is_deleted, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_chat_messages_group_time ON n_chat_messages(group_id, is_deleted, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_chat_messages_author ON n_chat_messages(author_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_chat_messages_reply ON n_chat_messages(reply_to_message_id) TABLESPACE neko_index;
CREATE INDEX idx_chat_messages_pinned ON n_chat_messages(channel_id, is_pinned DESC, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_chat_msg_media_message ON n_chat_message_media(message_id, position) TABLESPACE neko_index;
CREATE INDEX idx_chat_msg_media_asset ON n_chat_message_media(media_id) TABLESPACE neko_index;
CREATE INDEX idx_chat_reactions_user ON n_chat_message_reactions(user_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_chat_reads_user ON n_chat_channel_reads(user_id, last_read_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_chat_mutes_user ON n_chat_channel_mutes(user_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_direct_conv_low_user ON n_direct_conversations(user_low_id, updated_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_direct_conv_high_user ON n_direct_conversations(user_high_id, updated_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_direct_messages_conv_time ON n_direct_messages(conversation_id, is_deleted, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_direct_messages_sender ON n_direct_messages(sender_id, created_at DESC) TABLESPACE neko_index;
CREATE INDEX idx_direct_reads_user ON n_direct_conversation_reads(user_id, last_read_at DESC) TABLESPACE neko_index;

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
    p_created_at        IN TIMESTAMP
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

    v_age_hours := GREATEST(
        ROUND((CAST(CURRENT_TIMESTAMP AS DATE) - CAST(p_created_at AS DATE)) * 24, 2),
        0
    );

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

-- 7.4.1 检查用户通知偏好
CREATE OR REPLACE FUNCTION fn_check_notification_preference(
    p_user_id             IN NUMBER,
    p_notification_type   IN VARCHAR2
) RETURN NUMBER
AS
    v_allowed NUMBER := 1;
BEGIN
    IF p_notification_type = 'system' THEN
        RETURN 1;
    END IF;

    BEGIN
        SELECT is_enabled
        INTO v_allowed
        FROM n_notification_preferences
        WHERE user_id = p_user_id
          AND notification_type = p_notification_type;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            v_allowed := 1;
    END;

    RETURN NVL(v_allowed, 1);
EXCEPTION
    WHEN OTHERS THEN
        RETURN 1;
END fn_check_notification_preference;
/

-- 7.4.2 格式化通知消息
CREATE OR REPLACE FUNCTION fn_format_notification_message(
    p_type              IN VARCHAR2,
    p_actor_username    IN VARCHAR2,
    p_related_content   IN VARCHAR2 DEFAULT NULL
) RETURN VARCHAR2
AS
    v_message VARCHAR2(1000);
BEGIN
    CASE p_type
        WHEN 'like' THEN
            v_message := p_actor_username || ' 点赞了你的帖子';
        WHEN 'comment' THEN
            v_message := p_actor_username || ' 评论了你的帖子';
        WHEN 'reply' THEN
            v_message := p_actor_username || ' 回复了你的评论';
        WHEN 'repost' THEN
            v_message := p_actor_username || ' 转发了你的帖子';
        WHEN 'follow' THEN
            v_message := p_actor_username || ' 关注了你';
        WHEN 'mention' THEN
            v_message := p_actor_username || ' 在帖子里提到了你';
        WHEN 'group_invite' THEN
            v_message := p_actor_username || ' 邀请你加入群组';
        WHEN 'system' THEN
            v_message := '系统通知';
        ELSE
            v_message := p_actor_username || ' 触发了一条通知';
    END CASE;

    IF p_related_content IS NOT NULL AND p_type IN ('like', 'comment', 'reply', 'repost') THEN
        v_message := v_message || '：' || SUBSTR(p_related_content, 1, 50);
        IF LENGTH(p_related_content) > 50 THEN
            v_message := v_message || '...';
        END IF;
    END IF;

    RETURN v_message;
EXCEPTION
    WHEN OTHERS THEN
        RETURN '通知消息';
END fn_format_notification_message;
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
    v_code   VARCHAR2(32);
    v_exists NUMBER := 0;
BEGIN
    FOR i IN 1..10 LOOP
        SELECT DBMS_RANDOM.STRING('X', 32) INTO v_code FROM DUAL;

        SELECT COUNT(*) INTO v_exists
        FROM n_group_invites
        WHERE invite_code = v_code;

        IF v_exists = 0 THEN
            RETURN v_code;
        END IF;
    END LOOP;

    v_code := RAWTOHEX(SYS_GUID());
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

CREATE OR REPLACE TRIGGER trg_moderation_reports_pk
BEFORE INSERT ON n_moderation_reports
FOR EACH ROW
WHEN (NEW.report_id IS NULL)
BEGIN
    SELECT seq_moderation_report_id.NEXTVAL INTO :NEW.report_id FROM dual;
END;
/

CREATE OR REPLACE TRIGGER trg_moderation_cases_pk
BEFORE INSERT ON n_moderation_cases
FOR EACH ROW
WHEN (NEW.case_id IS NULL)
BEGIN
    SELECT seq_moderation_case_id.NEXTVAL INTO :NEW.case_id FROM dual;
END;
/

CREATE OR REPLACE TRIGGER trg_moderation_actions_pk
BEFORE INSERT ON n_moderation_actions
FOR EACH ROW
WHEN (NEW.action_id IS NULL)
BEGIN
    SELECT seq_moderation_action_id.NEXTVAL INTO :NEW.action_id FROM dual;
END;
/

CREATE OR REPLACE TRIGGER trg_moderation_restrictions_pk
BEFORE INSERT ON n_moderation_user_restrictions
FOR EACH ROW
WHEN (NEW.restriction_id IS NULL)
BEGIN
    SELECT seq_moderation_restriction_id.NEXTVAL INTO :NEW.restriction_id FROM dual;
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

-- 8.7.1 通用规范化与 updated_at 触发器
CREATE OR REPLACE TRIGGER trg_tags_normalize
BEFORE INSERT OR UPDATE ON n_tags
FOR EACH ROW
BEGIN
    :NEW.name := TRIM(:NEW.name);
    :NEW.name_lower := LOWER(TRIM(:NEW.name));

    IF INSERTING AND :NEW.created_at IS NULL THEN
        :NEW.created_at := CURRENT_TIMESTAMP;
    END IF;

    :NEW.updated_at := CURRENT_TIMESTAMP;
END;
/

CREATE OR REPLACE TRIGGER trg_media_assets_updated_at
BEFORE UPDATE ON n_media_assets
FOR EACH ROW
BEGIN
    :NEW.updated_at := CURRENT_TIMESTAMP;
END;
/

CREATE OR REPLACE TRIGGER trg_notification_preferences_updated_at
BEFORE UPDATE ON n_notification_preferences
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

CREATE OR REPLACE TRIGGER trg_moderation_reports_updated_at
BEFORE UPDATE ON n_moderation_reports
FOR EACH ROW
BEGIN
    :NEW.updated_at := CURRENT_TIMESTAMP;
END;
/

CREATE OR REPLACE TRIGGER trg_moderation_cases_updated_at
BEFORE UPDATE ON n_moderation_cases
FOR EACH ROW
BEGIN
    :NEW.updated_at := CURRENT_TIMESTAMP;
END;
/

CREATE OR REPLACE TRIGGER trg_moderation_settings_updated_at
BEFORE UPDATE ON n_moderation_settings
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

CREATE OR REPLACE TRIGGER trg_chat_channels_id
BEFORE INSERT ON n_chat_channels
FOR EACH ROW
BEGIN
    IF :NEW.channel_id IS NULL THEN
        :NEW.channel_id := seq_chat_channel_id.NEXTVAL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_chat_messages_id
BEFORE INSERT ON n_chat_messages
FOR EACH ROW
BEGIN
    IF :NEW.message_id IS NULL THEN
        :NEW.message_id := seq_chat_message_id.NEXTVAL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_chat_message_media_id
BEFORE INSERT ON n_chat_message_media
FOR EACH ROW
BEGIN
    IF :NEW.chat_message_media_id IS NULL THEN
        :NEW.chat_message_media_id := seq_chat_message_media_id.NEXTVAL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_direct_conversations_id
BEFORE INSERT ON n_direct_conversations
FOR EACH ROW
BEGIN
    IF :NEW.conversation_id IS NULL THEN
        :NEW.conversation_id := seq_direct_conversation_id.NEXTVAL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_direct_messages_id
BEFORE INSERT ON n_direct_messages
FOR EACH ROW
BEGIN
    IF :NEW.message_id IS NULL THEN
        :NEW.message_id := seq_direct_message_id.NEXTVAL;
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

CREATE OR REPLACE TRIGGER trg_chat_channels_updated_at
BEFORE UPDATE ON n_chat_channels
FOR EACH ROW
BEGIN
    :NEW.updated_at := SYSTIMESTAMP;
END;
/

CREATE OR REPLACE TRIGGER trg_chat_messages_updated_at
BEFORE UPDATE ON n_chat_messages
FOR EACH ROW
BEGIN
    :NEW.updated_at := SYSTIMESTAMP;
END;
/

CREATE OR REPLACE TRIGGER trg_direct_conversations_updated_at
BEFORE UPDATE ON n_direct_conversations
FOR EACH ROW
BEGIN
    :NEW.updated_at := SYSTIMESTAMP;
END;
/

CREATE OR REPLACE TRIGGER trg_direct_messages_updated_at
BEFORE UPDATE ON n_direct_messages
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
    v_allowed := fn_check_notification_preference(p_user_id, p_type);

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

-- 9.3.1 清理旧通知
CREATE OR REPLACE PROCEDURE sp_cleanup_old_notifications(
    p_days_to_keep  IN NUMBER DEFAULT 30,
    p_result        OUT VARCHAR2
)
AS
    v_deleted_count NUMBER := 0;
BEGIN
    DELETE FROM n_notifications
    WHERE deleted_at IS NOT NULL
      AND deleted_at < CURRENT_TIMESTAMP - NUMTODSINTERVAL(p_days_to_keep, 'DAY');

    v_deleted_count := SQL%ROWCOUNT;

    DELETE FROM n_notifications
    WHERE deleted_at IS NULL
      AND is_read = 1
      AND created_at < CURRENT_TIMESTAMP - NUMTODSINTERVAL(p_days_to_keep * 3, 'DAY')
      AND priority = 'low';

    v_deleted_count := v_deleted_count + SQL%ROWCOUNT;

    COMMIT;
    p_result := 'SUCCESS: 共清理 ' || v_deleted_count || ' 条通知';
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_cleanup_old_notifications;
/

-- 9.4 创建帖子
CREATE OR REPLACE PROCEDURE sp_create_post(
    p_author_id           IN NUMBER,
    p_content             IN CLOB,
    p_post_type           IN VARCHAR2 DEFAULT 'post',
    p_reply_to_post_id    IN NUMBER DEFAULT NULL,
    p_repost_of_post_id   IN NUMBER DEFAULT NULL,
    p_quoted_post_id      IN NUMBER DEFAULT NULL,
    p_visibility          IN VARCHAR2 DEFAULT 'public',
    p_language            IN VARCHAR2 DEFAULT 'zh',
    p_location            IN VARCHAR2 DEFAULT NULL,
    p_post_id             OUT NUMBER,
    p_result              OUT VARCHAR2
)
AS
    v_parent_exists NUMBER := 0;
BEGIN
    IF p_post_type NOT IN ('post', 'reply', 'repost', 'quote') THEN
        p_result := 'ERROR: 非法的 post_type';
        RETURN;
    END IF;

    IF p_post_type = 'reply' AND p_reply_to_post_id IS NULL THEN
        p_result := 'ERROR: 回复贴必须指定 reply_to_post_id';
        RETURN;
    END IF;

    IF p_post_type = 'repost' AND p_repost_of_post_id IS NULL THEN
        p_result := 'ERROR: 转发贴必须指定 repost_of_post_id';
        RETURN;
    END IF;

    IF p_post_type = 'quote' AND p_quoted_post_id IS NULL THEN
        p_result := 'ERROR: 引用贴必须指定 quoted_post_id';
        RETURN;
    END IF;

    IF p_post_type = 'post'
       AND (p_reply_to_post_id IS NOT NULL OR p_repost_of_post_id IS NOT NULL OR p_quoted_post_id IS NOT NULL) THEN
        p_result := 'ERROR: 普通帖子不能指定 reply/repost/quote 引用';
        RETURN;
    END IF;

    IF p_post_type = 'reply'
       AND (p_repost_of_post_id IS NOT NULL OR p_quoted_post_id IS NOT NULL) THEN
        p_result := 'ERROR: 回复贴只能指定 reply_to_post_id';
        RETURN;
    END IF;

    IF p_post_type = 'repost'
       AND (p_reply_to_post_id IS NOT NULL OR p_quoted_post_id IS NOT NULL) THEN
        p_result := 'ERROR: 转发贴只能指定 repost_of_post_id';
        RETURN;
    END IF;

    IF p_post_type = 'quote'
       AND (p_reply_to_post_id IS NOT NULL OR p_repost_of_post_id IS NOT NULL) THEN
        p_result := 'ERROR: 引用贴只能指定 quoted_post_id';
        RETURN;
    END IF;

    IF p_visibility NOT IN ('public', 'followers', 'mentioned', 'private') THEN
        p_result := 'ERROR: 非法的 visibility';
        RETURN;
    END IF;

    IF p_reply_to_post_id IS NOT NULL THEN
        SELECT COUNT(*) INTO v_parent_exists
        FROM n_posts
        WHERE post_id = p_reply_to_post_id
          AND is_deleted = 0;
        IF v_parent_exists = 0 THEN
            p_result := 'ERROR: reply_to_post 不存在';
            RETURN;
        END IF;
    END IF;

    IF p_repost_of_post_id IS NOT NULL THEN
        SELECT COUNT(*) INTO v_parent_exists
        FROM n_posts
        WHERE post_id = p_repost_of_post_id
          AND is_deleted = 0;
        IF v_parent_exists = 0 THEN
            p_result := 'ERROR: repost_of_post 不存在';
            RETURN;
        END IF;
    END IF;

    IF p_quoted_post_id IS NOT NULL THEN
        SELECT COUNT(*) INTO v_parent_exists
        FROM n_posts
        WHERE post_id = p_quoted_post_id
          AND is_deleted = 0;
        IF v_parent_exists = 0 THEN
            p_result := 'ERROR: quoted_post 不存在';
            RETURN;
        END IF;
    END IF;

    INSERT INTO n_posts (
        author_id,
        content,
        post_type,
        reply_to_post_id,
        repost_of_post_id,
        quoted_post_id,
        visibility,
        language,
        location
    ) VALUES (
        p_author_id,
        p_content,
        p_post_type,
        p_reply_to_post_id,
        p_repost_of_post_id,
        p_quoted_post_id,
        p_visibility,
        p_language,
        p_location
    ) RETURNING post_id INTO p_post_id;

    p_result := 'SUCCESS: 帖子创建成功，ID=' || p_post_id;
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_create_post;
/

-- 9.5 删除帖子（软删除）
CREATE OR REPLACE PROCEDURE sp_delete_post(
    p_post_id      IN NUMBER,
    p_actor_id     IN NUMBER,
    p_result       OUT VARCHAR2
)
AS
    v_author_id NUMBER;
    v_exists    NUMBER := 0;
BEGIN
    SELECT COUNT(*) INTO v_exists
    FROM n_posts
    WHERE post_id = p_post_id
      AND is_deleted = 0;

    IF v_exists = 0 THEN
        p_result := 'ERROR: 帖子不存在';
        RETURN;
    END IF;

    SELECT author_id INTO v_author_id
    FROM n_posts
    WHERE post_id = p_post_id;

    IF v_author_id != p_actor_id THEN
        p_result := 'ERROR: 只能删除自己的帖子';
        RETURN;
    END IF;

    UPDATE n_posts
    SET is_deleted = 1
    WHERE post_id = p_post_id;

    p_result := 'SUCCESS: 帖子删除成功';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_delete_post;
/

-- 9.6 创建评论
CREATE OR REPLACE PROCEDURE sp_create_comment(
    p_post_id             IN NUMBER,
    p_user_id             IN NUMBER,
    p_content             IN CLOB,
    p_parent_comment_id   IN NUMBER DEFAULT NULL,
    p_root_comment_id     IN NUMBER DEFAULT NULL,
    p_comment_id          OUT NUMBER,
    p_result              OUT VARCHAR2
)
AS
    v_post_exists                NUMBER := 0;
    v_parent_exists              NUMBER := 0;
    v_effective_root_comment_id  NUMBER := NULL;
BEGIN
    SELECT COUNT(*) INTO v_post_exists
    FROM n_posts
    WHERE post_id = p_post_id
      AND is_deleted = 0;

    IF v_post_exists = 0 THEN
        p_result := 'ERROR: 帖子不存在';
        RETURN;
    END IF;

    IF p_parent_comment_id IS NOT NULL THEN
        SELECT COUNT(*) INTO v_parent_exists
        FROM n_comments
        WHERE comment_id = p_parent_comment_id
          AND post_id = p_post_id
          AND is_deleted = 0;

        IF v_parent_exists = 0 THEN
            p_result := 'ERROR: 父评论不存在或不属于当前帖子';
            RETURN;
        END IF;

        SELECT NVL(root_comment_id, comment_id)
        INTO v_effective_root_comment_id
        FROM n_comments
        WHERE comment_id = p_parent_comment_id;
    END IF;

    IF p_root_comment_id IS NOT NULL THEN
        SELECT COUNT(*) INTO v_parent_exists
        FROM n_comments
        WHERE comment_id = p_root_comment_id
          AND post_id = p_post_id
          AND is_deleted = 0;

        IF v_parent_exists = 0 THEN
            p_result := 'ERROR: 根评论不存在或不属于当前帖子';
            RETURN;
        END IF;

        IF v_effective_root_comment_id IS NOT NULL
           AND v_effective_root_comment_id != p_root_comment_id THEN
            p_result := 'ERROR: 根评论与父评论不一致';
            RETURN;
        END IF;

        v_effective_root_comment_id := p_root_comment_id;
    END IF;

    INSERT INTO n_comments (
        post_id,
        user_id,
        parent_comment_id,
        root_comment_id,
        content
    ) VALUES (
        p_post_id,
        p_user_id,
        p_parent_comment_id,
        v_effective_root_comment_id,
        p_content
    ) RETURNING comment_id INTO p_comment_id;

    IF p_parent_comment_id IS NULL AND v_effective_root_comment_id IS NULL THEN
        UPDATE n_comments
        SET root_comment_id = p_comment_id
        WHERE comment_id = p_comment_id;
    END IF;

    p_result := 'SUCCESS: 评论创建成功，ID=' || p_comment_id;
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_create_comment;
/

-- 9.7 删除评论（软删除）
CREATE OR REPLACE PROCEDURE sp_delete_comment(
    p_comment_id    IN NUMBER,
    p_actor_id      IN NUMBER,
    p_result        OUT VARCHAR2
)
AS
    v_author_id NUMBER;
    v_exists NUMBER := 0;
BEGIN
    SELECT COUNT(*) INTO v_exists
    FROM n_comments
    WHERE comment_id = p_comment_id
      AND is_deleted = 0;

    IF v_exists = 0 THEN
        p_result := 'ERROR: 评论不存在';
        RETURN;
    END IF;

    SELECT user_id INTO v_author_id
    FROM n_comments
    WHERE comment_id = p_comment_id;

    IF v_author_id != p_actor_id THEN
        p_result := 'ERROR: 只能删除自己的评论';
        RETURN;
    END IF;

    UPDATE n_comments
    SET is_deleted = 1
    WHERE comment_id = p_comment_id;

    p_result := 'SUCCESS: 评论删除成功';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_delete_comment;
/

-- 9.8 关注用户
CREATE OR REPLACE PROCEDURE sp_follow_user(
    p_follower_id    IN NUMBER,
    p_following_id   IN NUMBER,
    p_result         OUT VARCHAR2
)
AS
    v_blocking_count NUMBER := 0;
BEGIN
    IF p_follower_id = p_following_id THEN
        p_result := 'ERROR: 不能关注自己';
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_blocking_count
    FROM n_user_blocks
    WHERE (user_id = p_follower_id AND target_user_id = p_following_id)
       OR (user_id = p_following_id AND target_user_id = p_follower_id);

    IF v_blocking_count > 0 THEN
        p_result := 'ERROR: 当前关系不允许关注';
        RETURN;
    END IF;

    MERGE INTO n_user_follows f
    USING (SELECT p_follower_id AS follower_id, p_following_id AS following_id FROM dual) src
    ON (f.follower_id = src.follower_id AND f.following_id = src.following_id)
    WHEN MATCHED THEN
        UPDATE SET f.status = 'active', f.updated_at = CURRENT_TIMESTAMP
    WHEN NOT MATCHED THEN
        INSERT (follower_id, following_id, status)
        VALUES (p_follower_id, p_following_id, 'active');

    p_result := 'SUCCESS: 关注成功';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_follow_user;
/

-- 9.9 取消关注
CREATE OR REPLACE PROCEDURE sp_unfollow_user(
    p_follower_id    IN NUMBER,
    p_following_id   IN NUMBER,
    p_result         OUT VARCHAR2
)
AS
BEGIN
    UPDATE n_user_follows
    SET status = 'cancelled',
        updated_at = CURRENT_TIMESTAMP
    WHERE follower_id = p_follower_id
      AND following_id = p_following_id
      AND status = 'active';

    IF SQL%ROWCOUNT = 0 THEN
        p_result := 'ERROR: 未找到有效关注关系';
        RETURN;
    END IF;

    p_result := 'SUCCESS: 取消关注成功';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_unfollow_user;
/

-- 9.10 屏蔽用户
CREATE OR REPLACE PROCEDURE sp_block_user(
    p_user_id        IN NUMBER,
    p_target_user_id IN NUMBER,
    p_result         OUT VARCHAR2
)
AS
BEGIN
    IF p_user_id = p_target_user_id THEN
        p_result := 'ERROR: 不能屏蔽自己';
        RETURN;
    END IF;

    MERGE INTO n_user_blocks b
    USING (SELECT p_user_id AS user_id, p_target_user_id AS target_user_id FROM dual) src
    ON (b.user_id = src.user_id AND b.target_user_id = src.target_user_id)
    WHEN NOT MATCHED THEN
        INSERT (user_id, target_user_id) VALUES (p_user_id, p_target_user_id);

    -- 屏蔽后主动取消双方 follow 关系
    UPDATE n_user_follows
    SET status = 'cancelled',
        updated_at = CURRENT_TIMESTAMP
    WHERE (follower_id = p_user_id AND following_id = p_target_user_id)
       OR (follower_id = p_target_user_id AND following_id = p_user_id);

    p_result := 'SUCCESS: 屏蔽成功';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_block_user;
/

-- 9.11 取消屏蔽
CREATE OR REPLACE PROCEDURE sp_unblock_user(
    p_user_id        IN NUMBER,
    p_target_user_id IN NUMBER,
    p_result         OUT VARCHAR2
)
AS
BEGIN
    DELETE FROM n_user_blocks
    WHERE user_id = p_user_id
      AND target_user_id = p_target_user_id;

    IF SQL%ROWCOUNT = 0 THEN
        p_result := 'ERROR: 未找到屏蔽关系';
        RETURN;
    END IF;

    p_result := 'SUCCESS: 取消屏蔽成功';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_unblock_user;
/

-- 9.12 静音用户
CREATE OR REPLACE PROCEDURE sp_mute_user(
    p_user_id        IN NUMBER,
    p_target_user_id IN NUMBER,
    p_expires_at     IN TIMESTAMP DEFAULT NULL,
    p_result         OUT VARCHAR2
)
AS
BEGIN
    IF p_user_id = p_target_user_id THEN
        p_result := 'ERROR: 不能静音自己';
        RETURN;
    END IF;

    MERGE INTO n_user_mutes m
    USING (SELECT p_user_id AS user_id, p_target_user_id AS target_user_id, p_expires_at AS expires_at FROM dual) src
    ON (m.user_id = src.user_id AND m.target_user_id = src.target_user_id)
    WHEN MATCHED THEN
        UPDATE SET m.expires_at = src.expires_at
    WHEN NOT MATCHED THEN
        INSERT (user_id, target_user_id, expires_at)
        VALUES (p_user_id, p_target_user_id, p_expires_at);

    p_result := 'SUCCESS: 静音成功';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_mute_user;
/

-- 9.13 取消静音
CREATE OR REPLACE PROCEDURE sp_unmute_user(
    p_user_id        IN NUMBER,
    p_target_user_id IN NUMBER,
    p_result         OUT VARCHAR2
)
AS
BEGIN
    DELETE FROM n_user_mutes
    WHERE user_id = p_user_id
      AND target_user_id = p_target_user_id;

    IF SQL%ROWCOUNT = 0 THEN
        p_result := 'ERROR: 未找到静音关系';
        RETURN;
    END IF;

    p_result := 'SUCCESS: 取消静音成功';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_unmute_user;
/

-- 9.14 创建群组
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
    CASE
        WHEN NVL(us.show_online_status, 1) = 0 THEN 'hidden'
        WHEN u.last_login_at > CAST(CURRENT_TIMESTAMP AS TIMESTAMP) - INTERVAL '7' DAY THEN 'active'
        WHEN u.last_login_at > CAST(CURRENT_TIMESTAMP AS TIMESTAMP) - INTERVAL '30' DAY THEN 'normal'
        ELSE 'inactive'
    END AS activity_status
FROM n_users u
JOIN n_user_stats s ON s.user_id = u.user_id
LEFT JOIN n_user_settings us ON us.user_id = u.user_id;
COMMENT ON TABLE v_user_profile_public IS '用户公开资料视图';

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
COMMENT ON TABLE v_user_profile_self IS '当前用户资料视图（含敏感字段）';

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
COMMENT ON TABLE v_post_detail IS '帖子详情视图';

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
COMMENT ON TABLE v_post_comment_list_item IS '帖子评论列表项视图';

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
COMMENT ON TABLE v_notification_list_item IS '通知列表项视图';

-- 10.4.1 通知摘要视图
CREATE OR REPLACE VIEW v_notification_summary AS
SELECT
    user_id,
    COUNT(*) AS total_notifications,
    SUM(CASE WHEN is_read = 0 AND deleted_at IS NULL THEN 1 ELSE 0 END) AS unread_count,
    SUM(CASE WHEN priority IN ('high', 'urgent') AND deleted_at IS NULL THEN 1 ELSE 0 END) AS high_priority_count,
    MAX(created_at) AS latest_notification_at
FROM n_notifications
GROUP BY user_id;
COMMENT ON TABLE v_notification_summary IS '通知摘要视图';

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
COMMENT ON TABLE v_user_analytics IS '用户分析视图';

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
COMMENT ON TABLE v_post_analytics IS '帖子分析视图';

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
COMMENT ON TABLE v_tag_analytics IS '标签分析视图';

-- 10.8 时间线 / 列表视图
CREATE OR REPLACE VIEW v_post_feed_item AS
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
        SELECT LISTAGG(ma.public_url, ',') WITHIN GROUP (ORDER BY pm.sort_order)
        FROM n_post_media pm
        JOIN n_media_assets ma ON ma.media_id = pm.media_id
        WHERE pm.post_id = p.post_id
    ) AS media_urls
FROM n_posts p
JOIN n_users u ON u.user_id = p.author_id
JOIN n_post_stats ps ON ps.post_id = p.post_id
WHERE p.is_deleted = 0;
COMMENT ON TABLE v_post_feed_item IS '帖子时间线列表项视图';

CREATE OR REPLACE VIEW v_trending_tags AS
SELECT
    tag_id,
    name,
    name_lower,
    usage_count,
    trending_score,
    is_trending,
    created_at,
    updated_at
FROM n_tags
WHERE is_trending = 1
ORDER BY trending_score DESC, usage_count DESC, updated_at DESC;
COMMENT ON TABLE v_trending_tags IS '热门标签视图';

CREATE OR REPLACE VIEW v_trending_posts AS
SELECT
    p.post_id,
    p.author_id,
    u.username,
    u.display_name,
    u.avatar_url,
    u.is_verified,
    p.content,
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
WHERE p.is_deleted = 0
  AND p.visibility = 'public'
ORDER BY ps.engagement_score DESC, p.created_at DESC;
COMMENT ON TABLE v_trending_posts IS '热门帖子视图';

-- 10.9 帖子互动明细视图
CREATE OR REPLACE VIEW v_post_interactions AS
SELECT
    p.post_id,
    p.author_id,
    u.username AS author_username,
    u.display_name AS author_display_name,
    p.created_at,
    ps.likes_count,
    ps.comments_count,
    ps.replies_count,
    ps.retweets_count,
    ps.views_count,
    ps.engagement_score,
    (
        SELECT LISTAGG(lu.username, ', ') WITHIN GROUP (ORDER BY pl.created_at DESC)
        FROM n_post_likes pl
        JOIN n_users lu ON lu.user_id = pl.user_id
        WHERE pl.post_id = p.post_id
    ) AS liked_by_users
FROM n_posts p
JOIN n_users u ON u.user_id = p.author_id
JOIN n_post_stats ps ON ps.post_id = p.post_id
WHERE p.is_deleted = 0;
COMMENT ON TABLE v_post_interactions IS '帖子互动明细视图';

-- 10.10 群组详情视图
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

-- 10.11 群组成员详情视图
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

-- 10.12 群组帖子详情视图
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

-- 10.13 群组评论详情视图
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

-- 10.14 群组邀请详情视图
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

-- 10.15 群组审计日志详情视图
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

-- 10.16 用户群组列表视图
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

-- 10.17 热门群组视图
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

-- 10.18 群组时间线视图
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
GRANT SELECT ON n_posts TO neko_readonly;
GRANT SELECT ON n_post_stats TO neko_readonly;
GRANT SELECT ON n_post_media TO neko_readonly;
GRANT SELECT ON n_post_tags TO neko_readonly;
GRANT SELECT ON n_post_mentions TO neko_readonly;
GRANT SELECT ON n_comments TO neko_readonly;
GRANT SELECT ON n_comment_stats TO neko_readonly;
GRANT SELECT ON n_media_assets TO neko_readonly;
GRANT SELECT ON n_tags TO neko_readonly;
GRANT SELECT ON n_notifications TO neko_readonly;
GRANT SELECT ON n_groups TO neko_readonly;
GRANT SELECT ON n_group_members TO neko_readonly;
GRANT SELECT ON n_group_posts TO neko_readonly;
GRANT SELECT ON n_group_comments TO neko_readonly;
GRANT SELECT ON n_group_invites TO neko_readonly;
GRANT SELECT ON n_group_audit_logs TO neko_readonly;
GRANT SELECT ON n_group_post_likes TO neko_readonly;
GRANT SELECT ON n_group_comment_likes TO neko_readonly;
GRANT SELECT ON n_chat_channels TO neko_readonly;
GRANT SELECT ON n_chat_messages TO neko_readonly;
GRANT SELECT ON n_chat_message_media TO neko_readonly;
GRANT SELECT ON n_chat_message_reactions TO neko_readonly;
GRANT SELECT ON n_chat_channel_reads TO neko_readonly;
GRANT SELECT ON n_chat_channel_mutes TO neko_readonly;
GRANT SELECT ON n_direct_conversations TO neko_readonly;
GRANT SELECT ON n_direct_messages TO neko_readonly;
GRANT SELECT ON n_direct_conversation_reads TO neko_readonly;

-- 安全边界:
--   neko_readonly 不直接授权 n_auth_sessions / n_auth_otp_events 等认证秘密表。
--   v_user_profile_self 含 email / phone / birth_date 等敏感字段，仅建议应用用户按当前登录人查询。
GRANT SELECT ON v_user_profile_public TO neko_readonly;
GRANT SELECT ON v_post_detail TO neko_readonly;
GRANT SELECT ON v_post_comment_list_item TO neko_readonly;
GRANT SELECT ON v_notification_list_item TO neko_readonly;
GRANT SELECT ON v_notification_summary TO neko_readonly;
GRANT SELECT ON v_user_analytics TO neko_readonly;
GRANT SELECT ON v_post_analytics TO neko_readonly;
GRANT SELECT ON v_tag_analytics TO neko_readonly;
GRANT SELECT ON v_post_feed_item TO neko_readonly;
GRANT SELECT ON v_trending_tags TO neko_readonly;
GRANT SELECT ON v_trending_posts TO neko_readonly;
GRANT SELECT ON v_post_interactions TO neko_readonly;
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
--    - 当前用户资料: v_user_profile_self
--    - 帖子详情: v_post_detail
--    - 时间线列表: v_post_feed_item
--    - 评论列表: v_post_comment_list_item
--    - 通知列表: v_notification_list_item
--    - 通知摘要: v_notification_summary
--    - 用户分析: v_user_analytics
--    - 帖子分析: v_post_analytics
--    - 标签分析: v_tag_analytics
--    - 热门标签: v_trending_tags
--    - 热门帖子: v_trending_posts
--
-- 2. 本脚本只提供 V2 正式对象，请直接按 V2 DTO 开发
--
-- 3. 标签趋势数据建议定时刷新:
--    BEGIN
--      DECLARE v_result VARCHAR2(500);
--      BEGIN
--          sp_refresh_tag_trends(v_result);
--      END;
--    END;
--    /
--
-- 4. 群组模块原则上可以直接沿用当前 API 的过程式写法；
--    社交主线 V2 建议优先使用 Repository + SQL，不再新增“万能 action 存储过程”。

-- ==========================================
-- 13. 开发期测试数据（可按需执行）
-- ==========================================
-- 说明:
--   1. 这部分数据用于本地或测试环境联调，不建议直接用于生产环境。
--   2. 如果你想创建一个完全“空库”的 V2 环境，可以从这里往下手动跳过。
--   3. 这里尽量使用固定 username / tag name 来做清理和重建，方便重复执行。

DELETE FROM n_group_comment_likes
WHERE user_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'));

DELETE FROM n_group_post_likes
WHERE user_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'));

DELETE FROM n_group_comments
WHERE author_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'));

DELETE FROM n_group_posts
WHERE author_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'));

DELETE FROM n_group_invites
WHERE inviter_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'))
   OR invitee_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'));

DELETE FROM n_group_members
WHERE user_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'));

DELETE FROM n_groups
WHERE slug IN ('v2-core-team', 'v2-design-lab');

DELETE FROM n_statement_appeals
WHERE user_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'));

DELETE FROM n_account_statements
WHERE user_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'));

DELETE FROM n_notifications
WHERE user_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'))
   OR actor_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'));

DELETE FROM n_post_mentions
WHERE mentioned_user_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'));

DELETE FROM n_post_tags
WHERE post_id IN (
    SELECT post_id FROM n_posts
    WHERE author_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'))
);

DELETE FROM n_post_media
WHERE post_id IN (
    SELECT post_id FROM n_posts
    WHERE author_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'))
);

DELETE FROM n_comment_likes
WHERE user_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'));

DELETE FROM n_comments
WHERE user_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'));

DELETE FROM n_post_bookmarks
WHERE user_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'));

DELETE FROM n_post_likes
WHERE user_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'));

DELETE FROM n_posts
WHERE author_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'));

DELETE FROM n_media_assets
WHERE owner_user_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'));

DELETE FROM n_user_mutes
WHERE user_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'))
   OR target_user_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'));

DELETE FROM n_user_blocks
WHERE user_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'))
   OR target_user_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'));

DELETE FROM n_user_follows
WHERE follower_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'))
   OR following_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'));

DELETE FROM n_auth_sessions
WHERE user_id IN (SELECT user_id FROM n_users WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm'));

DELETE FROM n_auth_otp_events
WHERE account IN ('v2_admin@example.com', 'v2_dev@example.com', 'v2_reader@example.com', 'v2_designer@example.com', 'v2_pm@example.com');

DELETE FROM n_tags
WHERE name IN ('v2', 'oracle', 'nuxt', 'design', 'product', 'backend', 'group', 'api');

DELETE FROM n_users
WHERE username IN ('v2_admin', 'v2_dev', 'v2_reader', 'v2_designer', 'v2_pm');

COMMIT;

-- 13.1 用户
INSERT INTO n_users (email, username, password_hash, display_name, bio, location, website, phone, is_verified, status)
VALUES ('v2_admin@example.com', 'v2_admin', '$2b$10$placeholder_admin_hash', 'V2 管理员', '负责 V2 开发环境管理和联调', '上海', 'https://example.com/admin', '13800000001', 1, 'active');

INSERT INTO n_users (email, username, password_hash, display_name, bio, location, website, phone, is_verified, status)
VALUES ('v2_dev@example.com', 'v2_dev', '$2b$10$placeholder_dev_hash', 'V2 后端开发', '关注 Oracle、API 设计、可维护性', '杭州', 'https://example.com/dev', '13800000002', 1, 'active');

INSERT INTO n_users (email, username, password_hash, display_name, bio, location, is_verified, status)
VALUES ('v2_reader@example.com', 'v2_reader', '$2b$10$placeholder_reader_hash', 'V2 普通用户', '主要用于看帖、点赞、收藏和评论', '深圳', 0, 'active');

INSERT INTO n_users (email, username, password_hash, display_name, bio, location, is_verified, status)
VALUES ('v2_designer@example.com', 'v2_designer', '$2b$10$placeholder_designer_hash', 'V2 设计师', '关注设计系统、体验和群组运营', '广州', 1, 'active');

INSERT INTO n_users (email, username, password_hash, display_name, bio, location, is_verified, status)
VALUES ('v2_pm@example.com', 'v2_pm', '$2b$10$placeholder_pm_hash', 'V2 产品经理', '用于验证推荐、通知和统计接口', '北京', 1, 'active');

-- 13.2 标签
INSERT INTO n_tags (name, name_lower, usage_count, trending_score, is_trending) VALUES ('v2', 'v2', 0, 0, 0);
INSERT INTO n_tags (name, name_lower, usage_count, trending_score, is_trending) VALUES ('oracle', 'oracle', 0, 0, 0);
INSERT INTO n_tags (name, name_lower, usage_count, trending_score, is_trending) VALUES ('nuxt', 'nuxt', 0, 0, 0);
INSERT INTO n_tags (name, name_lower, usage_count, trending_score, is_trending) VALUES ('design', 'design', 0, 0, 0);
INSERT INTO n_tags (name, name_lower, usage_count, trending_score, is_trending) VALUES ('product', 'product', 0, 0, 0);
INSERT INTO n_tags (name, name_lower, usage_count, trending_score, is_trending) VALUES ('backend', 'backend', 0, 0, 0);
INSERT INTO n_tags (name, name_lower, usage_count, trending_score, is_trending) VALUES ('group', 'group', 0, 0, 0);
INSERT INTO n_tags (name, name_lower, usage_count, trending_score, is_trending) VALUES ('api', 'api', 0, 0, 0);

-- 13.3 关系
DECLARE
    v_dev_id       NUMBER;
    v_admin_id     NUMBER;
    v_reader_id    NUMBER;
    v_designer_id  NUMBER;
    v_pm_id        NUMBER;
    v_result VARCHAR2(500);
BEGIN
    SELECT user_id INTO v_dev_id FROM n_users WHERE username = 'v2_dev';
    SELECT user_id INTO v_admin_id FROM n_users WHERE username = 'v2_admin';
    SELECT user_id INTO v_reader_id FROM n_users WHERE username = 'v2_reader';
    SELECT user_id INTO v_designer_id FROM n_users WHERE username = 'v2_designer';
    SELECT user_id INTO v_pm_id FROM n_users WHERE username = 'v2_pm';

    sp_follow_user(
        v_dev_id,
        v_admin_id,
        v_result
    );

    sp_follow_user(
        v_reader_id,
        v_dev_id,
        v_result
    );

    sp_follow_user(
        v_designer_id,
        v_dev_id,
        v_result
    );

    sp_follow_user(
        v_pm_id,
        v_admin_id,
        v_result
    );
END;
/

-- 13.4 会话
INSERT INTO n_auth_sessions (
    session_id,
    user_id,
    access_jti,
    refresh_token_hash,
    device_info,
    device_fingerprint,
    ip_address,
    user_agent,
    access_token_expires_at,
    refresh_token_expires_at
) VALUES (
    'sess_v2_admin',
    (SELECT user_id FROM n_users WHERE username = 'v2_admin'),
    'jti_v2_admin',
    'hash_refresh_admin',
    'Windows 11 / Chrome',
    'fingerprint_admin',
    '192.168.0.10',
    'Mozilla/5.0 Admin',
    CURRENT_TIMESTAMP + INTERVAL '30' MINUTE,
    CURRENT_TIMESTAMP + INTERVAL '7' DAY
);

INSERT INTO n_auth_sessions (
    session_id,
    user_id,
    access_jti,
    refresh_token_hash,
    device_info,
    device_fingerprint,
    ip_address,
    user_agent,
    access_token_expires_at,
    refresh_token_expires_at
) VALUES (
    'sess_v2_dev',
    (SELECT user_id FROM n_users WHERE username = 'v2_dev'),
    'jti_v2_dev',
    'hash_refresh_dev',
    'macOS / Safari',
    'fingerprint_dev',
    '192.168.0.11',
    'Mozilla/5.0 Dev',
    CURRENT_TIMESTAMP + INTERVAL '30' MINUTE,
    CURRENT_TIMESTAMP + INTERVAL '7' DAY
);

-- 13.5 媒体
INSERT INTO n_media_assets (
    owner_user_id, media_type, file_name, storage_key, public_url, file_size, mime_type, width, height, alt_text, status
) VALUES (
    (SELECT user_id FROM n_users WHERE username = 'v2_admin'),
    'image', 'v2-banner.jpg', 'media/v2-banner.jpg', '/upload/media/v2-banner.jpg',
    256000, 'image/jpeg', 1200, 630, 'V2 欢迎横幅', 'ready'
);

INSERT INTO n_media_assets (
    owner_user_id, media_type, file_name, storage_key, public_url, file_size, mime_type, width, height, alt_text, status
) VALUES (
    (SELECT user_id FROM n_users WHERE username = 'v2_dev'),
    'image', 'oracle-erd.png', 'media/oracle-erd.png', '/upload/media/oracle-erd.png',
    512000, 'image/png', 1280, 720, 'Oracle ER 图', 'ready'
);

UPDATE n_users
SET avatar_media_id = (SELECT media_id FROM n_media_assets WHERE storage_key = 'media/v2-banner.jpg'),
    avatar_url = '/upload/media/v2-banner.jpg'
WHERE username = 'v2_admin';

-- 13.6 帖子
DECLARE
    v_admin_id NUMBER;
    v_banner_media_id NUMBER;
    v_v2_tag_id NUMBER;
    v_api_tag_id NUMBER;
    v_post_id NUMBER;
    v_result VARCHAR2(500);
BEGIN
    SELECT user_id INTO v_admin_id FROM n_users WHERE username = 'v2_admin';
    SELECT media_id INTO v_banner_media_id FROM n_media_assets WHERE storage_key = 'media/v2-banner.jpg';
    SELECT tag_id INTO v_v2_tag_id FROM n_tags WHERE name_lower = 'v2';
    SELECT tag_id INTO v_api_tag_id FROM n_tags WHERE name_lower = 'api';

    sp_create_post(
        p_author_id         => v_admin_id,
        p_content           => '欢迎来到 NekoTribe V2 开发环境，这条帖子用于验证 posts 详情、时间线、通知和统计。',
        p_post_type         => 'post',
        p_visibility        => 'public',
        p_language          => 'zh',
        p_post_id           => v_post_id,
        p_result            => v_result
    );

    INSERT INTO n_post_media (post_id, media_id, sort_order)
    VALUES (
        v_post_id,
        v_banner_media_id,
        1
    );

    INSERT INTO n_post_tags (post_id, tag_id)
    VALUES (v_post_id, v_v2_tag_id);

    INSERT INTO n_post_tags (post_id, tag_id)
    VALUES (v_post_id, v_api_tag_id);
END;
/

DECLARE
    v_dev_id NUMBER;
    v_erd_media_id NUMBER;
    v_oracle_tag_id NUMBER;
    v_backend_tag_id NUMBER;
    v_api_tag_id NUMBER;
    v_post_id NUMBER;
    v_result VARCHAR2(500);
BEGIN
    SELECT user_id INTO v_dev_id FROM n_users WHERE username = 'v2_dev';
    SELECT media_id INTO v_erd_media_id FROM n_media_assets WHERE storage_key = 'media/oracle-erd.png';
    SELECT tag_id INTO v_oracle_tag_id FROM n_tags WHERE name_lower = 'oracle';
    SELECT tag_id INTO v_backend_tag_id FROM n_tags WHERE name_lower = 'backend';
    SELECT tag_id INTO v_api_tag_id FROM n_tags WHERE name_lower = 'api';

    sp_create_post(
        p_author_id         => v_dev_id,
        p_content           => '今天把 Oracle V2 基线库重构完成了，posts / comments / tags / notifications 都已经能直接开始开发。',
        p_post_type         => 'post',
        p_visibility        => 'public',
        p_language          => 'zh',
        p_post_id           => v_post_id,
        p_result            => v_result
    );

    INSERT INTO n_post_media (post_id, media_id, sort_order)
    VALUES (
        v_post_id,
        v_erd_media_id,
        1
    );

    INSERT INTO n_post_tags (post_id, tag_id)
    VALUES (v_post_id, v_oracle_tag_id);

    INSERT INTO n_post_tags (post_id, tag_id)
    VALUES (v_post_id, v_backend_tag_id);

    INSERT INTO n_post_tags (post_id, tag_id)
    VALUES (v_post_id, v_api_tag_id);
END;
/

DECLARE
    v_designer_id NUMBER;
    v_design_tag_id NUMBER;
    v_post_id NUMBER;
    v_result VARCHAR2(500);
BEGIN
    SELECT user_id INTO v_designer_id FROM n_users WHERE username = 'v2_designer';
    SELECT tag_id INTO v_design_tag_id FROM n_tags WHERE name_lower = 'design';

    sp_create_post(
        p_author_id         => v_designer_id,
        p_content           => 'V2 需要的不只是接口改名，还要一起整理响应结构和设计系统，这样前后端才能真正稳下来。',
        p_post_type         => 'post',
        p_visibility        => 'public',
        p_language          => 'zh',
        p_post_id           => v_post_id,
        p_result            => v_result
    );

    INSERT INTO n_post_tags (post_id, tag_id)
    VALUES (v_post_id, v_design_tag_id);
END;
/

-- 13.7 评论
DECLARE
    v_admin_id NUMBER;
    v_admin_post_id NUMBER;
    v_dev_id NUMBER;
    v_comment_id NUMBER;
    v_result VARCHAR2(500);
BEGIN
    SELECT user_id INTO v_admin_id FROM n_users WHERE username = 'v2_admin';
    SELECT user_id INTO v_dev_id FROM n_users WHERE username = 'v2_dev';
    SELECT MIN(post_id) INTO v_admin_post_id FROM n_posts WHERE author_id = v_admin_id;

    sp_create_comment(
        p_post_id           => v_admin_post_id,
        p_user_id           => v_dev_id,
        p_content           => '这条欢迎帖刚好可以拿来测试评论流和通知。',
        p_comment_id        => v_comment_id,
        p_result            => v_result
    );
END;
/

DECLARE
    v_dev_id NUMBER;
    v_dev_post_id NUMBER;
    v_reader_id NUMBER;
    v_comment_id NUMBER;
    v_result VARCHAR2(500);
BEGIN
    SELECT user_id INTO v_dev_id FROM n_users WHERE username = 'v2_dev';
    SELECT user_id INTO v_reader_id FROM n_users WHERE username = 'v2_reader';
    SELECT MIN(post_id) INTO v_dev_post_id FROM n_posts WHERE author_id = v_dev_id;

    sp_create_comment(
        p_post_id           => v_dev_post_id,
        p_user_id           => v_reader_id,
        p_content           => '请问这套 V2 SQL 也会覆盖群组接口吗？',
        p_comment_id        => v_comment_id,
        p_result            => v_result
    );
END;
/

-- 13.8 点赞 / 收藏 / 提及
INSERT INTO n_post_likes (post_id, user_id)
VALUES (
    (SELECT MIN(post_id) FROM n_posts WHERE author_id = (SELECT user_id FROM n_users WHERE username = 'v2_admin')),
    (SELECT user_id FROM n_users WHERE username = 'v2_dev')
);

INSERT INTO n_post_likes (post_id, user_id)
VALUES (
    (SELECT MIN(post_id) FROM n_posts WHERE author_id = (SELECT user_id FROM n_users WHERE username = 'v2_dev')),
    (SELECT user_id FROM n_users WHERE username = 'v2_reader')
);

INSERT INTO n_post_bookmarks (post_id, user_id)
VALUES (
    (SELECT MIN(post_id) FROM n_posts WHERE author_id = (SELECT user_id FROM n_users WHERE username = 'v2_dev')),
    (SELECT user_id FROM n_users WHERE username = 'v2_pm')
);

INSERT INTO n_post_mentions (post_id, mentioned_user_id)
VALUES (
    (SELECT MIN(post_id) FROM n_posts WHERE author_id = (SELECT user_id FROM n_users WHERE username = 'v2_admin')),
    (SELECT user_id FROM n_users WHERE username = 'v2_pm')
);

-- 13.9 通知
DECLARE
    v_pm_id NUMBER;
    v_admin_id NUMBER;
    v_admin_post_id NUMBER;
    v_dev_id NUMBER;
    v_result VARCHAR2(500);
BEGIN
    SELECT user_id INTO v_pm_id FROM n_users WHERE username = 'v2_pm';
    SELECT user_id INTO v_admin_id FROM n_users WHERE username = 'v2_admin';
    SELECT user_id INTO v_dev_id FROM n_users WHERE username = 'v2_dev';
    SELECT MIN(post_id) INTO v_admin_post_id FROM n_posts WHERE author_id = v_admin_id;

    sp_create_notification(
        p_user_id        => v_pm_id,
        p_type           => 'mention',
        p_title          => '你被提及了',
        p_message        => '管理员在欢迎帖里提到了你。',
        p_resource_type  => 'post',
        p_resource_id    => v_admin_post_id,
        p_actor_id       => v_admin_id,
        p_priority       => 'normal',
        p_result         => v_result
    );

    sp_create_notification(
        p_user_id        => v_dev_id,
        p_type           => 'system',
        p_title          => 'V2 开发提示',
        p_message        => '请优先使用 v_post_detail、v_post_feed_item、v_notification_list_item 等视图进行联调。',
        p_resource_type  => 'system',
        p_priority       => 'high',
        p_result         => v_result
    );
END;
/

-- 13.10 账户状态
INSERT INTO n_account_statements (user_id, statement_type, title, message, policy_code, status)
VALUES (
    (SELECT user_id FROM n_users WHERE username = 'v2_reader'),
    'warning',
    '开发环境示例提醒',
    '这是一条开发环境中的账户状态示例，可用于联调 account-statements 列表与详情。',
    'DEV-001',
    'unread'
);

INSERT INTO n_statement_appeals (statement_id, user_id, appeal_message, appeal_status)
VALUES (
    (SELECT statement_id FROM n_account_statements WHERE user_id = (SELECT user_id FROM n_users WHERE username = 'v2_reader') AND ROWNUM = 1),
    (SELECT user_id FROM n_users WHERE username = 'v2_reader'),
    '这是开发环境中的申诉示例，主要用于联调 appeals 子资源。',
    'pending'
);

-- 13.11 群组
DECLARE
    v_admin_id NUMBER;
    v_group_id NUMBER;
    v_result VARCHAR2(500);
BEGIN
    SELECT user_id INTO v_admin_id FROM n_users WHERE username = 'v2_admin';

    sp_create_group(
        p_owner_id        => v_admin_id,
        p_name            => 'V2 Core Team',
        p_description     => '用于联调群组详情、成员、帖子、邀请和时间线。',
        p_privacy         => 'public',
        p_post_permission => 'all',
        p_group_id        => v_group_id,
        p_result          => v_result
    );

    UPDATE n_groups
    SET slug = 'v2-core-team'
    WHERE group_id = v_group_id;
END;
/

DECLARE
    v_designer_id NUMBER;
    v_group_id NUMBER;
    v_result VARCHAR2(500);
BEGIN
    SELECT user_id INTO v_designer_id FROM n_users WHERE username = 'v2_designer';

    sp_create_group(
        p_owner_id        => v_designer_id,
        p_name            => 'V2 Design Lab',
        p_description     => '用于联调私密群组、邀请和审核流。',
        p_privacy         => 'private',
        p_join_approval   => 1,
        p_post_permission => 'moderator_up',
        p_group_id        => v_group_id,
        p_result          => v_result
    );

    UPDATE n_groups
    SET slug = 'v2-design-lab'
    WHERE group_id = v_group_id;
END;
/

DECLARE
    v_dev_id NUMBER;
    v_pm_id NUMBER;
    v_group_id NUMBER;
    v_member_id NUMBER;
    v_result VARCHAR2(500);
BEGIN
    SELECT user_id INTO v_dev_id FROM n_users WHERE username = 'v2_dev';
    SELECT user_id INTO v_pm_id FROM n_users WHERE username = 'v2_pm';
    SELECT group_id INTO v_group_id FROM n_groups WHERE slug = 'v2-core-team';

    sp_join_group(
        p_user_id     => v_dev_id,
        p_group_id    => v_group_id,
        p_member_id   => v_member_id,
        p_result      => v_result
    );

    sp_join_group(
        p_user_id     => v_pm_id,
        p_group_id    => v_group_id,
        p_member_id   => v_member_id,
        p_result      => v_result
    );
END;
/

DECLARE
    v_admin_id NUMBER;
    v_group_id NUMBER;
    v_post_id NUMBER;
    v_result VARCHAR2(500);
BEGIN
    SELECT user_id INTO v_admin_id FROM n_users WHERE username = 'v2_admin';
    SELECT group_id INTO v_group_id FROM n_groups WHERE slug = 'v2-core-team';

    sp_create_group_post(
        p_author_id  => v_admin_id,
        p_group_id   => v_group_id,
        p_content    => '欢迎进入 V2 Core Team 群组，这条帖子用于测试群组时间线。',
        p_post_id    => v_post_id,
        p_result     => v_result
    );
END;
/

DECLARE
    v_dev_id NUMBER;
    v_group_id NUMBER;
    v_group_post_id NUMBER;
    v_comment_id NUMBER;
    v_result VARCHAR2(500);
BEGIN
    SELECT user_id INTO v_dev_id FROM n_users WHERE username = 'v2_dev';
    SELECT group_id INTO v_group_id FROM n_groups WHERE slug = 'v2-core-team';
    SELECT MIN(post_id) INTO v_group_post_id FROM n_group_posts WHERE group_id = v_group_id;

    sp_create_group_comment(
        p_author_id   => v_dev_id,
        p_post_id     => v_group_post_id,
        p_content     => '群组评论流也可以直接开始联调了。',
        p_comment_id  => v_comment_id,
        p_result      => v_result
    );
END;
/

DECLARE
    v_result VARCHAR2(500);
BEGIN
    sp_refresh_tag_trends(v_result);
END;
/

COMMIT;

-- ==========================================
-- 14. 数据库统计信息收集
-- ==========================================
BEGIN
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_USERS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_USER_STATS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_AUTH_OTP_EVENTS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_AUTH_SESSIONS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_USER_FOLLOWS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_USER_BLOCKS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_USER_MUTES');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_POSTS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_POST_STATS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_POST_MEDIA');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_POST_LIKES');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_POST_BOOKMARKS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_COMMENTS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_COMMENT_STATS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_COMMENT_LIKES');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_MEDIA_ASSETS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_TAGS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_POST_TAGS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_POST_MENTIONS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_NOTIFICATIONS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_NOTIFICATION_PREFERENCES');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_USER_SETTINGS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_ACCOUNT_STATEMENTS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_STATEMENT_APPEALS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_GROUPS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_GROUP_MEMBERS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_GROUP_POSTS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_GROUP_COMMENTS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_GROUP_INVITES');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_GROUP_AUDIT_LOGS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_GROUP_POST_LIKES');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_GROUP_COMMENT_LIKES');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_CHAT_CHANNELS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_CHAT_MESSAGES');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_CHAT_MESSAGE_MEDIA');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_CHAT_MESSAGE_REACTIONS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_CHAT_CHANNEL_READS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_CHAT_CHANNEL_MUTES');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_DIRECT_CONVERSATIONS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_DIRECT_MESSAGES');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_DIRECT_CONVERSATION_READS');
END;
/

-- ==========================================
-- 15. 物化视图
-- ==========================================
-- 说明:
--   这些物化视图用于加速 V2 的分析与趋势类接口。
--   如果你暂时不需要，可单独注释掉。

DECLARE
    v_sql CLOB;
BEGIN
    v_sql := q'[
CREATE MATERIALIZED VIEW mv_user_activity_daily
REFRESH COMPLETE ON DEMAND
AS
SELECT
    TRUNC(p.created_at) AS activity_date,
    p.author_id AS user_id,
    COUNT(*) AS daily_posts,
    SUM(ps.likes_count) AS daily_likes_received,
    SUM(ps.comments_count) AS daily_comments_received,
    AVG(ps.engagement_score) AS avg_engagement_score
FROM n_posts p
JOIN n_post_stats ps ON ps.post_id = p.post_id
WHERE p.is_deleted = 0
GROUP BY TRUNC(p.created_at), p.author_id]';
    EXECUTE IMMEDIATE v_sql;
    EXECUTE IMMEDIATE 'GRANT SELECT ON mv_user_activity_daily TO neko_readonly';
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('跳过 mv_user_activity_daily: ' || SQLERRM);
END;
/

DECLARE
    v_sql CLOB;
BEGIN
    v_sql := q'[
CREATE MATERIALIZED VIEW mv_tag_trends_hourly
REFRESH COMPLETE ON DEMAND
AS
SELECT
    TRUNC(CAST(p.created_at AS DATE), ''HH24'') AS trend_hour,
    t.tag_id,
    t.name,
    COUNT(*) AS hourly_usage,
    COUNT(DISTINCT p.author_id) AS unique_users,
    AVG(ps.engagement_score) AS avg_engagement_score
FROM n_posts p
JOIN n_post_tags pt ON pt.post_id = p.post_id
JOIN n_tags t ON t.tag_id = pt.tag_id
JOIN n_post_stats ps ON ps.post_id = p.post_id
WHERE p.is_deleted = 0
GROUP BY TRUNC(CAST(p.created_at AS DATE), ''HH24''), t.tag_id, t.name]';
    EXECUTE IMMEDIATE v_sql;
    EXECUTE IMMEDIATE 'GRANT SELECT ON mv_tag_trends_hourly TO neko_readonly';
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('跳过 mv_tag_trends_hourly: ' || SQLERRM);
END;
/

DECLARE
    v_sql CLOB;
BEGIN
    v_sql := q'[
CREATE MATERIALIZED VIEW mv_post_engagement_daily
REFRESH COMPLETE ON DEMAND
AS
SELECT
    TRUNC(p.created_at) AS stat_date,
    p.post_id,
    p.author_id,
    p.post_type,
    p.visibility,
    ps.likes_count,
    ps.comments_count,
    ps.replies_count,
    ps.retweets_count,
    ps.views_count,
    ps.engagement_score
FROM n_posts p
JOIN n_post_stats ps ON ps.post_id = p.post_id
WHERE p.is_deleted = 0]';
    EXECUTE IMMEDIATE v_sql;
    EXECUTE IMMEDIATE 'GRANT SELECT ON mv_post_engagement_daily TO neko_readonly';
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('跳过 mv_post_engagement_daily: ' || SQLERRM);
END;
/

-- ==========================================
-- 16. 建库完成提示
-- ==========================================
SELECT
    'NekoTribe V2 数据库创建完成' AS status,
    '已包含社交主线、通知、设置、账户状态、群组聊天、测试数据、统计信息和物化视图' AS summary
FROM dual;



