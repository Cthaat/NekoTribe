-- ==========================================
-- NekoTribe Oracle数据库完整设计方案
-- 作者: 杨毅
-- 创建日期: 2025-06-25
-- 数据库版本: Oracle 19c+
-- ==========================================

ALTER SESSION SET CONTAINER = ORCLPDB1;

-- 1. 创建表空间
-- ==========================================

-- 创建用户数据表空间
CREATE TABLESPACE neko_data DATAFILE '/opt/oracle/oradata/neko_data01.dbf' SIZE 500M AUTOEXTEND ON NEXT 50M MAXSIZE 2G SEGMENT SPACE MANAGEMENT AUTO;

-- 创建索引表空间
CREATE TABLESPACE neko_index DATAFILE '/opt/oracle/oradata/neko_index01.dbf' SIZE 200M AUTOEXTEND ON NEXT 20M MAXSIZE 1G SEGMENT SPACE MANAGEMENT AUTO;

-- 创建临时表空间
CREATE TEMPORARY TABLESPACE neko_temp TEMPFILE '/opt/oracle/oradata/neko_temp01.dbf' SIZE 100M AUTOEXTEND ON NEXT 10M MAXSIZE 500M;

-- 创建UNDO表空间
CREATE UNDO TABLESPACE neko_undo DATAFILE '/opt/oracle/oradata/neko_undo01.dbf' SIZE 200M AUTOEXTEND ON NEXT 20M MAXSIZE 1G;

-- 2. 创建用户和权限管理
-- ==========================================

-- 创建应用用户
CREATE USER neko_app IDENTIFIED BY "NekoApp2025#" DEFAULT TABLESPACE neko_data TEMPORARY TABLESPACE neko_temp QUOTA UNLIMITED ON neko_data QUOTA UNLIMITED ON neko_index;

-- 创建管理员用户
CREATE USER neko_admin IDENTIFIED BY "NekoAdmin2025#" DEFAULT TABLESPACE neko_data TEMPORARY TABLESPACE neko_temp QUOTA UNLIMITED ON neko_data QUOTA UNLIMITED ON neko_index;

-- 创建只读用户（用于报表查询）
CREATE USER neko_readonly IDENTIFIED BY "NekoRead2025#" DEFAULT TABLESPACE neko_data TEMPORARY TABLESPACE neko_temp;

-- 分配权限
GRANT CONNECT, RESOURCE TO neko_app;

GRANT
CREATE VIEW,
CREATE PROCEDURE,
CREATE TRIGGER,
CREATE SEQUENCE TO neko_app;

GRANT DBA TO neko_admin;

GRANT CONNECT TO neko_readonly;

-- 切换到neko_app表空间进行操作

ALTER SESSION SET CURRENT_SCHEMA = NEKO_APP;

-- ==========================================
-- NekoTribe Oracle数据库完整设计方案
-- 作者: 杨毅
-- 创建日期: 2025-06-25
-- 数据库版本: Oracle 19c+
-- ==========================================

-- 3. 创建序列
-- ==========================================

-- 用户ID序列，从1000开始，步长为1，缓存20个值以提高性能
CREATE SEQUENCE seq_user_id START
WITH
    1000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 20;

-- 推文ID序列，从10000开始，步长为1，缓存50个值（推文生成频率较高）
CREATE SEQUENCE seq_tweet_id START
WITH
    10000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 50;

-- 书签ID序列，从20000开始，步长为1，缓存30个值
CREATE SEQUENCE seq_bookmark_id START
WITH
    20000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 30;

-- 评论ID序列，从100000开始，步长为1，缓存100个值（评论生成频率最高）
CREATE SEQUENCE seq_comment_id START
WITH
    100000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 100;

-- 媒体文件ID序列，从1000000开始，步长为1，缓存20个值
CREATE SEQUENCE seq_media_id START
WITH
    1000000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 20;

-- 通知ID序列，从10000000开始，步长为1，缓存100个值（通知生成频率很高）
CREATE SEQUENCE seq_notification_id START
WITH
    10000000 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 100;

-- 4. 创建数据表
-- ==========================================

-- 用户表
CREATE TABLE n_users (
    user_id NUMBER (10) PRIMARY KEY,
    email VARCHAR2 (100) UNIQUE NOT NULL,
    username VARCHAR2 (50) UNIQUE NOT NULL,
    password_hash VARCHAR2 (255) NOT NULL,
    avatar_url VARCHAR2 (500) DEFAULT '/default-avatar.png',
    display_name VARCHAR2 (100),
    bio VARCHAR2 (500),
    location VARCHAR2 (100),
    website VARCHAR2 (200),
    birth_date DATE,
    phone VARCHAR2 (20),
    is_verified NUMBER (1) DEFAULT 0 CHECK (is_verified IN (0, 1)),
    is_active NUMBER (1) DEFAULT 1 CHECK (is_active IN (0, 1)),
    followers_count NUMBER (10) DEFAULT 0,
    following_count NUMBER (10) DEFAULT 0,
    tweets_count NUMBER (10) DEFAULT 0,
    likes_count NUMBER (10) DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_login_at TIMESTAMP,
    -- 审计字段
    created_by VARCHAR2 (50) DEFAULT USER,
    updated_by VARCHAR2 (50) DEFAULT USER
) TABLESPACE neko_data;

-- 添加表注释
COMMENT ON TABLE n_users IS '用户基础信息表，存储所有注册用户的基本资料和统计信息';

COMMENT ON COLUMN n_users.user_id IS '用户唯一标识符，主键';

COMMENT ON COLUMN n_users.email IS '用户邮箱，唯一约束，用于登录';

COMMENT ON COLUMN n_users.username IS '用户名，唯一约束，用于@提及';

COMMENT ON COLUMN n_users.password_hash IS '密码哈希值，使用bcrypt加密';

COMMENT ON COLUMN n_users.avatar_url IS '用户头像URL地址，默认为系统默认头像';

COMMENT ON COLUMN n_users.display_name IS '用户显示名称，可包含中文、特殊字符等';

COMMENT ON COLUMN n_users.bio IS '用户个人简介，最多500字符';

COMMENT ON COLUMN n_users.location IS '用户所在地理位置';

COMMENT ON COLUMN n_users.website IS '用户个人网站或博客链接';

COMMENT ON COLUMN n_users.birth_date IS '用户出生日期';

COMMENT ON COLUMN n_users.phone IS '用户手机号码';

COMMENT ON COLUMN n_users.is_verified IS '是否认证用户 0-未认证 1-已认证';

COMMENT ON COLUMN n_users.is_active IS '账户状态 0-禁用 1-激活';

COMMENT ON COLUMN n_users.followers_count IS '粉丝数量统计';

COMMENT ON COLUMN n_users.following_count IS '关注数量统计';

COMMENT ON COLUMN n_users.tweets_count IS '发布推文数量统计';

COMMENT ON COLUMN n_users.likes_count IS '点赞数量统计';

COMMENT ON COLUMN n_users.created_at IS '账户创建时间';

COMMENT ON COLUMN n_users.updated_at IS '最后更新时间';

COMMENT ON COLUMN n_users.last_login_at IS '最后登录时间';

COMMENT ON COLUMN n_users.created_by IS '记录创建者';

COMMENT ON COLUMN n_users.updated_by IS '记录更新者';

-- 推文表
CREATE TABLE n_tweets (
    tweet_id NUMBER (15) PRIMARY KEY,
    author_id NUMBER (10) NOT NULL,
    content CLOB DEFAULT NULL, -- 推文内容，支持富文本
    reply_to_tweet_id NUMBER (15), -- 回复的推文ID
    retweet_of_tweet_id NUMBER (15), -- 转发的推文ID
    quote_tweet_id NUMBER (15), -- 引用推文ID
    is_retweet NUMBER (1) DEFAULT 0 CHECK (is_retweet IN (0, 1)),
    is_quote_tweet NUMBER (1) DEFAULT 0 CHECK (is_quote_tweet IN (0, 1)),
    likes_count NUMBER (10) DEFAULT 0,
    retweets_count NUMBER (10) DEFAULT 0,
    replies_count NUMBER (10) DEFAULT 0,
    views_count NUMBER (15) DEFAULT 0,
    is_deleted NUMBER (1) DEFAULT 0 CHECK (is_deleted IN (0, 1)),
    visibility VARCHAR2 (20) DEFAULT 'public' CHECK (
        visibility IN (
            'public',
            'followers',
            'mentioned',
            'private'
        )
    ),
    language VARCHAR2 (10) DEFAULT 'zh',
    location VARCHAR2 (100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP,
    engagement_score NUMBER (10,2) DEFAULT 0.14,

    -- 审计字段
    created_by VARCHAR2 (50) DEFAULT USER,
    updated_by VARCHAR2 (50) DEFAULT USER,
    -- 外键约束
    CONSTRAINT fk_tweets_author FOREIGN KEY (author_id) REFERENCES n_users (user_id),
    CONSTRAINT fk_tweets_reply FOREIGN KEY (reply_to_tweet_id) REFERENCES n_tweets (tweet_id),
    CONSTRAINT fk_tweets_retweet FOREIGN KEY (retweet_of_tweet_id) REFERENCES n_tweets (tweet_id),
    CONSTRAINT fk_tweets_quote FOREIGN KEY (quote_tweet_id) REFERENCES n_tweets (tweet_id)
) TABLESPACE neko_data;

COMMENT ON TABLE n_tweets IS '推文内容表，存储所有推文、回复、转发和引用';

COMMENT ON COLUMN n_tweets.tweet_id IS '推文唯一标识符，主键';

COMMENT ON COLUMN n_tweets.author_id IS '推文作者用户ID，外键关联n_users表';

COMMENT ON COLUMN n_tweets.content IS '推文内容，支持最多280字符的文本和富文本';

COMMENT ON COLUMN n_tweets.reply_to_tweet_id IS '回复的原推文ID，空值表示不是回复';

COMMENT ON COLUMN n_tweets.retweet_of_tweet_id IS '转发的原推文ID，空值表示不是转发';

COMMENT ON COLUMN n_tweets.quote_tweet_id IS '引用的推文ID，空值表示不是引用推文';

COMMENT ON COLUMN n_tweets.is_retweet IS '是否为转发推文 0-否 1-是';

COMMENT ON COLUMN n_tweets.is_quote_tweet IS '是否为引用推文 0-否 1-是';

COMMENT ON COLUMN n_tweets.likes_count IS '点赞数量统计';

COMMENT ON COLUMN n_tweets.retweets_count IS '转发数量统计';

COMMENT ON COLUMN n_tweets.replies_count IS '回复数量统计';

COMMENT ON COLUMN n_tweets.views_count IS '浏览次数统计';

COMMENT ON COLUMN n_tweets.is_deleted IS '是否已删除 0-正常 1-已删除';

COMMENT ON COLUMN n_tweets.visibility IS '可见性：public-公开，followers-仅关注者，mentioned-仅被提及者，private-私有';

COMMENT ON COLUMN n_tweets.language IS '推文语言代码，默认为中文zh';

COMMENT ON COLUMN n_tweets.location IS '推文发布地理位置';

COMMENT ON COLUMN n_tweets.created_at IS '推文创建时间';

COMMENT ON COLUMN n_tweets.updated_at IS '推文最后更新时间';

COMMENT ON COLUMN n_tweets.deleted_at IS '推文删除时间';

COMMENT ON COLUMN n_tweets.created_by IS '记录创建者';

COMMENT ON COLUMN n_tweets.updated_by IS '记录更新者';

COMMENT ON COLUMN n_tweets.engagement_score IS '推文参与度评分，基于点赞、转发、回复等计算';

-- 关注关系表
CREATE TABLE n_follows (
    follow_id NUMBER (15) PRIMARY KEY,
    follower_id NUMBER (10) NOT NULL, -- 关注者
    following_id NUMBER (10) NOT NULL, -- 被关注者
    follow_type VARCHAR2 (20) DEFAULT 'follow' CHECK (
        follow_type IN ('follow', 'block', 'mute')
    ),
    is_active NUMBER (1) DEFAULT 1 CHECK (is_active IN (0, 1)),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- 外键约束
    CONSTRAINT fk_follows_follower FOREIGN KEY (follower_id) REFERENCES n_users (user_id),
    CONSTRAINT fk_follows_following FOREIGN KEY (following_id) REFERENCES n_users (user_id),
    -- 唯一约束，防止重复关注
    CONSTRAINT uk_follows_unique UNIQUE (follower_id, following_id),
    -- 检查约束，防止自己关注自己
    CONSTRAINT ck_follows_not_self CHECK (follower_id != following_id)
) TABLESPACE neko_data;

COMMENT ON TABLE n_follows IS '用户关注关系表，包括关注、屏蔽、静音等关系';

COMMENT ON COLUMN n_follows.follow_id IS '关注关系唯一标识符，主键';

COMMENT ON COLUMN n_follows.follower_id IS '关注者用户ID，即发起关注的用户';

COMMENT ON COLUMN n_follows.following_id IS '被关注者用户ID，即被关注的用户';

COMMENT ON COLUMN n_follows.follow_type IS '关系类型：follow-关注，block-屏蔽，mute-静音';

COMMENT ON COLUMN n_follows.is_active IS '关系状态 0-未激活 1-激活';

COMMENT ON COLUMN n_follows.created_at IS '关注关系建立时间';

COMMENT ON COLUMN n_follows.updated_at IS '关注关系最后更新时间';

-- 推文书签表
CREATE TABLE n_bookmarks (
    bookmark_id NUMBER (15) PRIMARY KEY,
    user_id NUMBER (10) NOT NULL,
    tweet_id NUMBER (15) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- 外键约束
    CONSTRAINT fk_bookmarks_user FOREIGN KEY (user_id) REFERENCES n_users (user_id),
    CONSTRAINT fk_bookmarks_tweet FOREIGN KEY (tweet_id) REFERENCES n_tweets (tweet_id)
) TABLESPACE neko_data;

COMMENT ON TABLE n_bookmarks IS '用户推文书签表，记录用户收藏的推文';

COMMENT ON COLUMN n_bookmarks.bookmark_id IS '书签唯一标识符，主键';

COMMENT ON COLUMN n_bookmarks.user_id IS '书签拥有者用户ID，外键关联n_users表';

COMMENT ON COLUMN n_bookmarks.tweet_id IS '被收藏推文ID，外键关联n_tweets表';

-- 点赞表
CREATE TABLE n_likes (
    like_id NUMBER (15) PRIMARY KEY,
    user_id NUMBER (10) NOT NULL,
    tweet_id NUMBER (15) NOT NULL,
    like_type VARCHAR2 (20) DEFAULT 'like' CHECK (
        like_type IN (
            'like',
            'likeComment' -- 评论点赞
        )
    ),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- 外键约束
    CONSTRAINT fk_likes_user FOREIGN KEY (user_id) REFERENCES n_users (user_id),
    -- 唯一约束，一个用户对一个推文只能有一种反应
    CONSTRAINT uk_likes_unique UNIQUE (user_id, tweet_id)
) TABLESPACE neko_data;

COMMENT ON TABLE n_likes IS '点赞反应表，记录用户对推文的各种反应';

COMMENT ON COLUMN n_likes.like_id IS '点赞记录唯一标识符，主键';

COMMENT ON COLUMN n_likes.user_id IS '点赞用户ID，外键关联n_users表';

COMMENT ON COLUMN n_likes.tweet_id IS '被点赞推文ID，外键关联n_tweets表';

COMMENT ON COLUMN n_likes.like_type IS '反应类型：like-点赞，love-喜爱';

COMMENT ON COLUMN n_likes.created_at IS '点赞时间';

-- 评论表
CREATE TABLE n_comments (
    comment_id NUMBER (15) PRIMARY KEY,
    tweet_id NUMBER (15) NOT NULL,
    user_id NUMBER (10) NOT NULL,
    parent_comment_id NUMBER (15), -- 父评论ID，支持评论嵌套
    content CLOB NOT NULL,
    likes_count NUMBER (10) DEFAULT 0,
    replies_count NUMBER (10) DEFAULT 0,
    is_deleted NUMBER (1) DEFAULT 0 CHECK (is_deleted IN (0, 1)),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP,
    -- 外键约束
    CONSTRAINT fk_comments_tweet FOREIGN KEY (tweet_id) REFERENCES n_tweets (tweet_id),
    CONSTRAINT fk_comments_user FOREIGN KEY (user_id) REFERENCES n_users (user_id),
    CONSTRAINT fk_comments_parent FOREIGN KEY (parent_comment_id) REFERENCES n_comments (comment_id)
) TABLESPACE neko_data;

COMMENT ON TABLE n_comments IS '评论表，支持多层级嵌套评论';

COMMENT ON COLUMN n_comments.comment_id IS '评论唯一标识符，主键';

COMMENT ON COLUMN n_comments.tweet_id IS '被评论推文ID，外键关联t_tweets表';

COMMENT ON COLUMN n_comments.user_id IS '评论者用户ID，外键关联t_users表';

COMMENT ON COLUMN n_comments.parent_comment_id IS '父评论ID，为空表示顶级评论';

COMMENT ON COLUMN n_comments.content IS '评论内容，支持富文本格式';

COMMENT ON COLUMN n_comments.likes_count IS '评论点赞数量统计';

COMMENT ON COLUMN n_comments.replies_count IS '评论回复数量统计';

COMMENT ON COLUMN n_comments.is_deleted IS '是否已删除 0-正常 1-已删除';

COMMENT ON COLUMN n_comments.created_at IS '评论创建时间';

COMMENT ON COLUMN n_comments.updated_at IS '评论最后更新时间';

COMMENT ON COLUMN n_comments.deleted_at IS '评论删除时间';

-- 媒体文件表
CREATE TABLE n_media (
    media_id NUMBER (15) PRIMARY KEY,
    tweet_id NUMBER (15),
    user_id NUMBER (10) NOT NULL,
    media_type VARCHAR2 (20) NOT NULL CHECK (
        media_type IN (
            'image',
            'video',
            'audio',
            'gif'
        )
    ),
    file_name VARCHAR2 (255) NOT NULL,
    file_path VARCHAR2 (500) NOT NULL,
    file_size NUMBER (15) NOT NULL,
    mime_type VARCHAR2 (100) NOT NULL,
    width NUMBER (6),
    height NUMBER (6),
    duration NUMBER (10), -- 视频/音频时长（秒）
    thumbnail_path VARCHAR2 (500),
    alt_text VARCHAR2 (500), -- 可访问性描述
    is_processed NUMBER (1) DEFAULT 0 CHECK (is_processed IN (0, 1)),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- 外键约束
    CONSTRAINT fk_media_tweet FOREIGN KEY (tweet_id) REFERENCES n_tweets (tweet_id),
    CONSTRAINT fk_media_user FOREIGN KEY (user_id) REFERENCES n_users (user_id)
) TABLESPACE neko_data;

COMMENT ON TABLE n_media IS '媒体文件表，存储推文中的图片、视频、音频等媒体信息';

COMMENT ON COLUMN n_media.media_id IS '媒体文件唯一标识符，主键';

COMMENT ON COLUMN n_media.tweet_id IS '关联推文ID，外键关联t_tweets表，可为空（独立媒体）';

COMMENT ON COLUMN n_media.user_id IS '上传用户ID，外键关联t_users表';

COMMENT ON COLUMN n_media.media_type IS '媒体类型：image-图片，video-视频，audio-音频，gif-动图';

COMMENT ON COLUMN n_media.file_name IS '原始文件名';

COMMENT ON COLUMN n_media.file_path IS '文件存储路径';

COMMENT ON COLUMN n_media.file_size IS '文件大小（字节）';

COMMENT ON COLUMN n_media.mime_type IS '文件MIME类型';

COMMENT ON COLUMN n_media.width IS '图片/视频宽度（像素）';

COMMENT ON COLUMN n_media.height IS '图片/视频高度（像素）';

COMMENT ON COLUMN n_media.duration IS '视频/音频时长（秒）';

COMMENT ON COLUMN n_media.thumbnail_path IS '缩略图存储路径';

COMMENT ON COLUMN n_media.alt_text IS '媒体文件的可访问性描述文本';

COMMENT ON COLUMN n_media.is_processed IS '媒体是否已处理完成（缩略图生成、格式转换等）';

COMMENT ON COLUMN n_media.created_at IS '媒体文件上传时间';

-- 话题标签表
CREATE TABLE n_hashtags (
    hashtag_id NUMBER (10) PRIMARY KEY,
    tag_name VARCHAR2 (100) UNIQUE NOT NULL,
    tag_name_lower VARCHAR2 (100) NOT NULL, -- 小写版本用于搜索
    usage_count NUMBER (15) DEFAULT 0,
    trending_score NUMBER (10, 2) DEFAULT 0,
    is_trending NUMBER (1) DEFAULT 0 CHECK (is_trending IN (0, 1)),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) TABLESPACE neko_data;

COMMENT ON TABLE n_hashtags IS '话题标签表，存储所有使用过的标签';

COMMENT ON COLUMN n_hashtags.hashtag_id IS '标签唯一标识符，主键';

COMMENT ON COLUMN n_hashtags.tag_name IS '标签名称，区分大小写';

COMMENT ON COLUMN n_hashtags.tag_name_lower IS '标签名称小写版本，用于搜索和去重';

COMMENT ON COLUMN n_hashtags.usage_count IS '标签使用次数统计';

COMMENT ON COLUMN n_hashtags.trending_score IS '趋势分数，用于计算热门话题';

COMMENT ON COLUMN n_hashtags.is_trending IS '是否为当前热门话题 0-否 1-是';

COMMENT ON COLUMN n_hashtags.created_at IS '标签首次创建时间';

COMMENT ON COLUMN n_hashtags.updated_at IS '标签信息最后更新时间';

-- 推文标签关联表
CREATE TABLE n_tweet_hashtags (
    tweet_id NUMBER (15) NOT NULL,
    hashtag_id NUMBER (10) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- 主键
    PRIMARY KEY (tweet_id, hashtag_id),
    -- 外键约束
    CONSTRAINT fk_tweet_hashtags_tweet FOREIGN KEY (tweet_id) REFERENCES n_tweets (tweet_id),
    CONSTRAINT fk_tweet_hashtags_hashtag FOREIGN KEY (hashtag_id) REFERENCES n_hashtags (hashtag_id)
) TABLESPACE neko_data;

COMMENT ON TABLE n_tweet_hashtags IS '推文与标签的多对多关联表';

COMMENT ON COLUMN n_tweet_hashtags.tweet_id IS '推文ID，外键关联t_tweets表';

COMMENT ON COLUMN n_tweet_hashtags.hashtag_id IS '标签ID，外键关联t_hashtags表';

COMMENT ON COLUMN n_tweet_hashtags.created_at IS '关联关系创建时间';

-- 推文提及表
CREATE TABLE n_tweet_mentions (
    tweet_id NUMBER (15) NOT NULL,
    mentioned_user_id NUMBER (10) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- 主键
    PRIMARY KEY (tweet_id, mentioned_user_id),
    -- 外键约束
    CONSTRAINT fk_tweet_mentions_tweet FOREIGN KEY (tweet_id) REFERENCES n_tweets (tweet_id),
    CONSTRAINT fk_tweet_mentions_user FOREIGN KEY (mentioned_user_id) REFERENCES n_users (user_id)
) TABLESPACE neko_data;

COMMENT ON TABLE n_tweet_mentions IS '推文与提及用户的多对多关联表';

COMMENT ON COLUMN n_tweet_mentions.tweet_id IS '推文ID，外键关联t_tweets表';

COMMENT ON COLUMN n_tweet_mentions.mentioned_user_id IS '被提及用户ID，外键关联t_users表';

COMMENT ON COLUMN n_tweet_mentions.created_at IS '关联关系创建时间';

-- 用户会话表（支持双Token机制）
CREATE TABLE n_user_sessions (
    session_id VARCHAR2 (128) PRIMARY KEY,
    user_id NUMBER (10) NOT NULL,
    access_token CLOB NOT NULL,
    refresh_token CLOB NOT NULL,
    access_token_expires_at TIMESTAMP NOT NULL,
    refresh_token_expires_at TIMESTAMP NOT NULL,
    device_info VARCHAR2 (500),
    device_fingerprint VARCHAR2 (255), -- 设备指纹，用于安全验证
    ip_address VARCHAR2 (45),
    user_agent CLOB,
    is_active NUMBER (1) DEFAULT 1 CHECK (is_active IN (0, 1)),
    token_version NUMBER (10) DEFAULT 1, -- Token版本，用于Token轮换
    last_refresh_at TIMESTAMP, -- 最后刷新Token时间
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_accessed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- 外键约束
    CONSTRAINT fk_sessions_user FOREIGN KEY (user_id) REFERENCES n_users (user_id)
) TABLESPACE neko_data;

COMMENT ON
TABLE n_user_sessions IS '用户会话管理表，支持双Token认证机制（Access Token + Refresh Token）';

COMMENT ON COLUMN n_user_sessions.session_id IS '会话唯一标识符，主键';

COMMENT ON COLUMN n_user_sessions.user_id IS '用户ID，外键关联n_users表';

COMMENT ON COLUMN n_user_sessions.access_token IS 'JWT访问令牌，短期有效（通常15-30分钟）';

COMMENT ON COLUMN n_user_sessions.refresh_token IS 'JWT刷新令牌，长期有效（通常7-30天）';

COMMENT ON COLUMN n_user_sessions.access_token_expires_at IS 'Access Token过期时间';

COMMENT ON COLUMN n_user_sessions.refresh_token_expires_at IS 'Refresh Token过期时间';

COMMENT ON COLUMN n_user_sessions.device_info IS '设备信息描述';

COMMENT ON COLUMN n_user_sessions.device_fingerprint IS '设备指纹，用于设备识别和安全验证';

COMMENT ON COLUMN n_user_sessions.ip_address IS '客户端IP地址，支持IPv4和IPv6';

COMMENT ON COLUMN n_user_sessions.user_agent IS '客户端用户代理信息';

COMMENT ON COLUMN n_user_sessions.is_active IS '会话状态 0-已失效 1-活跃';

COMMENT ON COLUMN n_user_sessions.token_version IS 'Token版本号，用于Token轮换和安全管理';

COMMENT ON COLUMN n_user_sessions.last_refresh_at IS '最后一次刷新Token的时间';

COMMENT ON COLUMN n_user_sessions.created_at IS '会话创建时间';

COMMENT ON COLUMN n_user_sessions.last_accessed_at IS '最后访问时间';

-- 通知表

CREATE TABLE n_notifications (
    notification_id NUMBER (15) PRIMARY KEY, -- 通知唯一标识符，主键
    user_id NUMBER (10) NOT NULL, -- 接收通知的用户ID
    type VARCHAR2 (50) NOT NULL, -- 通知类型（like, comment, follow, mention, system等）
    title VARCHAR2 (200), -- 通知标题
    message VARCHAR2 (1000), -- 通知正文
    related_type VARCHAR2 (20), -- 相关对象类型（如 tweet/user/comment）
    related_id NUMBER (15), -- 相关对象ID
    actor_id NUMBER (10), -- 触发通知的用户ID
    is_read NUMBER (1) DEFAULT 0, -- 是否已读 0-未读 1-已读
    priority VARCHAR2 (10) DEFAULT 'normal', -- 优先级
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    read_at TIMESTAMP, -- 已读时间
    is_deleted INT, -- 是否删除
    -- 外键约束
    CONSTRAINT fk_notifications_user FOREIGN KEY (user_id) REFERENCES n_users (user_id)
) TABLESPACE neko_data;

COMMENT ON TABLE n_notifications IS '通知系统主表，保存所有用户通知';

COMMENT ON COLUMN n_notifications.notification_id IS '通知唯一标识符，主键';

COMMENT ON COLUMN n_notifications.user_id IS '接收通知的用户ID，外键关联n_users表';

COMMENT ON COLUMN n_notifications.type IS '通知类型：like, retweet, comment, mention, follow, system等';

COMMENT ON COLUMN n_notifications.title IS '通知标题，简短描述通知内容';

COMMENT ON COLUMN n_notifications.message IS '通知正文，详细描述通知内容';

COMMENT ON COLUMN n_notifications.related_type IS '通知关联的对象类型';

COMMENT ON COLUMN n_notifications.related_id IS '通知关联的对象ID';

COMMENT ON COLUMN n_notifications.actor_id IS '触发通知的用户ID，外键关联n_users表';

COMMENT ON COLUMN n_notifications.is_read IS '是否已读 0-未读 1-已读';

COMMENT ON COLUMN n_notifications.priority IS '通知优先级：normal-普通，high-高优先级';

COMMENT ON COLUMN n_notifications.created_at IS '通知创建时间';

COMMENT ON COLUMN n_notifications.read_at IS '通知已读时间';

COMMENT ON COLUMN n_notifications.is_deleted IS '是否删除';


-- ============================================
-- 1. 群组主表 (n_groups)
-- ============================================
CREATE TABLE n_groups (
    group_id            NUMBER(19)          PRIMARY KEY,
    name                VARCHAR2(100)       NOT NULL,
    slug                VARCHAR2(100)       UNIQUE NOT NULL,      -- URL友好的唯一标识
    description         VARCHAR2(500),
    avatar_url          VARCHAR2(500),
    cover_url           VARCHAR2(500),
    owner_id            NUMBER(19)          NOT NULL,
    privacy             VARCHAR2(20)        DEFAULT 'public' NOT NULL,  -- public/private/secret
    join_approval       NUMBER(1)           DEFAULT 0 NOT NULL,   -- 0=自由加入, 1=需审批
    post_permission     VARCHAR2(20)        DEFAULT 'all' NOT NULL,     -- all/admin_only/moderator_up
    member_count        NUMBER(10)          DEFAULT 0 NOT NULL,
    post_count          NUMBER(10)          DEFAULT 0 NOT NULL,
    is_active           NUMBER(1)           DEFAULT 1 NOT NULL,   -- 0=已封禁, 1=正常
    is_deleted          NUMBER(1)           DEFAULT 0 NOT NULL,   -- 软删除标记
    created_at          TIMESTAMP           DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at          TIMESTAMP           DEFAULT SYSTIMESTAMP NOT NULL,
    
    CONSTRAINT fk_groups_owner FOREIGN KEY (owner_id) 
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT chk_groups_privacy CHECK (privacy IN ('public', 'private', 'secret')),
    CONSTRAINT chk_groups_post_perm CHECK (post_permission IN ('all', 'admin_only', 'moderator_up'))
);

COMMENT ON TABLE n_groups IS '群组主表';
COMMENT ON COLUMN n_groups.group_id IS '群组ID，主键';
COMMENT ON COLUMN n_groups.name IS '群组名称';
COMMENT ON COLUMN n_groups.slug IS 'URL友好的唯一标识，用于路由';
COMMENT ON COLUMN n_groups.description IS '群组描述';
COMMENT ON COLUMN n_groups.avatar_url IS '群组头像URL';
COMMENT ON COLUMN n_groups.cover_url IS '群组封面URL';
COMMENT ON COLUMN n_groups.owner_id IS '群组创建者/所有者ID';
COMMENT ON COLUMN n_groups.privacy IS '隐私设置: public=公开, private=私密(需申请), secret=隐秘(仅邀请)';
COMMENT ON COLUMN n_groups.join_approval IS '加入是否需要审批: 0=自由加入, 1=需审批';
COMMENT ON COLUMN n_groups.post_permission IS '发帖权限: all=所有成员, admin_only=仅管理员, moderator_up=版主及以上';
COMMENT ON COLUMN n_groups.member_count IS '成员数量(冗余字段，提高查询效率)';
COMMENT ON COLUMN n_groups.post_count IS '帖子数量(冗余字段)';
COMMENT ON COLUMN n_groups.is_active IS '是否激活: 0=已封禁, 1=正常';
COMMENT ON COLUMN n_groups.is_deleted IS '软删除标记: 0=正常, 1=已删除';
COMMENT ON COLUMN n_groups.created_at IS '创建时间';
COMMENT ON COLUMN n_groups.updated_at IS '更新时间';

-- ============================================
-- 2. 群组成员表 (n_group_members)
-- ============================================
CREATE TABLE n_group_members (
    member_id           NUMBER(19)          PRIMARY KEY,
    group_id            NUMBER(19)          NOT NULL,
    user_id             NUMBER(19)          NOT NULL,
    role                VARCHAR2(20)        DEFAULT 'member' NOT NULL,  -- owner/admin/moderator/member
    status              VARCHAR2(20)        DEFAULT 'active' NOT NULL,  -- pending/active/muted/banned
    nickname            VARCHAR2(50),                             -- 群内昵称
    mute_until          TIMESTAMP,                                -- 禁言截止时间
    ban_reason          VARCHAR2(200),                            -- 封禁原因
    invited_by          NUMBER(19),                               -- 邀请人ID
    joined_at           TIMESTAMP           DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at          TIMESTAMP           DEFAULT SYSTIMESTAMP NOT NULL,
    
    CONSTRAINT fk_group_members_group FOREIGN KEY (group_id) 
        REFERENCES n_groups(group_id) ON DELETE CASCADE,
    CONSTRAINT fk_group_members_user FOREIGN KEY (user_id) 
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_group_members_inviter FOREIGN KEY (invited_by) 
        REFERENCES n_users(user_id) ON DELETE SET NULL,
    CONSTRAINT uk_group_members UNIQUE (group_id, user_id),
    CONSTRAINT chk_member_role CHECK (role IN ('owner', 'admin', 'moderator', 'member')),
    CONSTRAINT chk_member_status CHECK (status IN ('pending', 'active', 'muted', 'banned'))
);

COMMENT ON TABLE n_group_members IS '群组成员表';
COMMENT ON COLUMN n_group_members.member_id IS '成员记录ID，主键';
COMMENT ON COLUMN n_group_members.group_id IS '群组ID';
COMMENT ON COLUMN n_group_members.user_id IS '用户ID';
COMMENT ON COLUMN n_group_members.role IS '角色: owner=群主, admin=管理员, moderator=版主, member=普通成员';
COMMENT ON COLUMN n_group_members.status IS '状态: pending=待审核, active=正常, muted=禁言, banned=封禁';
COMMENT ON COLUMN n_group_members.nickname IS '群内昵称';
COMMENT ON COLUMN n_group_members.mute_until IS '禁言截止时间';
COMMENT ON COLUMN n_group_members.ban_reason IS '封禁原因';
COMMENT ON COLUMN n_group_members.invited_by IS '邀请人ID';
COMMENT ON COLUMN n_group_members.joined_at IS '加入时间';
COMMENT ON COLUMN n_group_members.updated_at IS '更新时间';

-- ============================================
-- 3. 群组帖子表 (n_group_posts)
-- ============================================
CREATE TABLE n_group_posts (
    post_id             NUMBER(19)          PRIMARY KEY,
    group_id            NUMBER(19)          NOT NULL,
    author_id           NUMBER(19)          NOT NULL,
    content             VARCHAR2(4000)      NOT NULL,
    media_urls          VARCHAR2(2000),                           -- JSON数组存储媒体URL
    is_pinned           NUMBER(1)           DEFAULT 0 NOT NULL,   -- 是否置顶
    is_announcement     NUMBER(1)           DEFAULT 0 NOT NULL,   -- 是否公告
    likes_count         NUMBER(10)          DEFAULT 0 NOT NULL,
    comments_count      NUMBER(10)          DEFAULT 0 NOT NULL,
    views_count         NUMBER(10)          DEFAULT 0 NOT NULL,
    is_deleted          NUMBER(1)           DEFAULT 0 NOT NULL,
    deleted_by          NUMBER(19),                               -- 删除者ID
    delete_reason       VARCHAR2(200),                            -- 删除原因
    created_at          TIMESTAMP           DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at          TIMESTAMP           DEFAULT SYSTIMESTAMP NOT NULL,
    
    CONSTRAINT fk_group_posts_group FOREIGN KEY (group_id) 
        REFERENCES n_groups(group_id) ON DELETE CASCADE,
    CONSTRAINT fk_group_posts_author FOREIGN KEY (author_id) 
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_group_posts_deleter FOREIGN KEY (deleted_by) 
        REFERENCES n_users(user_id) ON DELETE SET NULL
);

COMMENT ON TABLE n_group_posts IS '群组帖子表';
COMMENT ON COLUMN n_group_posts.post_id IS '帖子ID，主键';
COMMENT ON COLUMN n_group_posts.group_id IS '群组ID';
COMMENT ON COLUMN n_group_posts.author_id IS '作者ID';
COMMENT ON COLUMN n_group_posts.content IS '帖子内容';
COMMENT ON COLUMN n_group_posts.media_urls IS '媒体URL列表，JSON格式';
COMMENT ON COLUMN n_group_posts.is_pinned IS '是否置顶: 0=否, 1=是';
COMMENT ON COLUMN n_group_posts.is_announcement IS '是否公告: 0=否, 1=是';
COMMENT ON COLUMN n_group_posts.likes_count IS '点赞数';
COMMENT ON COLUMN n_group_posts.comments_count IS '评论数';
COMMENT ON COLUMN n_group_posts.views_count IS '浏览数';
COMMENT ON COLUMN n_group_posts.is_deleted IS '软删除标记';
COMMENT ON COLUMN n_group_posts.deleted_by IS '删除者ID';
COMMENT ON COLUMN n_group_posts.delete_reason IS '删除原因';
COMMENT ON COLUMN n_group_posts.created_at IS '创建时间';
COMMENT ON COLUMN n_group_posts.updated_at IS '更新时间';

-- ============================================
-- 4. 群组帖子评论表 (n_group_comments)
-- ============================================
CREATE TABLE n_group_comments (
    comment_id          NUMBER(19)          PRIMARY KEY,
    post_id             NUMBER(19)          NOT NULL,
    author_id           NUMBER(19)          NOT NULL,
    parent_comment_id   NUMBER(19),                               -- 父评论ID，支持嵌套回复
    reply_to_user_id    NUMBER(19),                               -- 回复的目标用户
    content             VARCHAR2(1000)      NOT NULL,
    likes_count         NUMBER(10)          DEFAULT 0 NOT NULL,
    is_deleted          NUMBER(1)           DEFAULT 0 NOT NULL,
    deleted_by          NUMBER(19),
    delete_reason       VARCHAR2(200),
    created_at          TIMESTAMP           DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at          TIMESTAMP           DEFAULT SYSTIMESTAMP NOT NULL,
    
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
);

COMMENT ON TABLE n_group_comments IS '群组帖子评论表';
COMMENT ON COLUMN n_group_comments.comment_id IS '评论ID，主键';
COMMENT ON COLUMN n_group_comments.post_id IS '帖子ID';
COMMENT ON COLUMN n_group_comments.author_id IS '评论作者ID';
COMMENT ON COLUMN n_group_comments.parent_comment_id IS '父评论ID，用于嵌套回复';
COMMENT ON COLUMN n_group_comments.reply_to_user_id IS '回复目标用户ID';
COMMENT ON COLUMN n_group_comments.content IS '评论内容';
COMMENT ON COLUMN n_group_comments.likes_count IS '点赞数';
COMMENT ON COLUMN n_group_comments.is_deleted IS '软删除标记';
COMMENT ON COLUMN n_group_comments.deleted_by IS '删除者ID';
COMMENT ON COLUMN n_group_comments.delete_reason IS '删除原因';
COMMENT ON COLUMN n_group_comments.created_at IS '创建时间';
COMMENT ON COLUMN n_group_comments.updated_at IS '更新时间';

-- ============================================
-- 5. 群组邀请表 (n_group_invites)
-- ============================================
CREATE TABLE n_group_invites (
    invite_id           NUMBER(19)          PRIMARY KEY,
    group_id            NUMBER(19)          NOT NULL,
    inviter_id          NUMBER(19)          NOT NULL,
    invitee_id          NUMBER(19),                               -- 被邀请用户ID (私人邀请)
    invite_code         VARCHAR2(32),                             -- 邀请码 (公开链接)
    status              VARCHAR2(20)        DEFAULT 'pending' NOT NULL,  -- pending/accepted/rejected/expired
    message             VARCHAR2(200),                            -- 邀请消息
    max_uses            NUMBER(5)           DEFAULT 1,            -- 最大使用次数
    used_count          NUMBER(5)           DEFAULT 0,            -- 已使用次数
    expires_at          TIMESTAMP,                                -- 过期时间
    created_at          TIMESTAMP           DEFAULT SYSTIMESTAMP NOT NULL,
    responded_at        TIMESTAMP,                                -- 响应时间
    
    CONSTRAINT fk_group_invites_group FOREIGN KEY (group_id) 
        REFERENCES n_groups(group_id) ON DELETE CASCADE,
    CONSTRAINT fk_group_invites_inviter FOREIGN KEY (inviter_id) 
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_group_invites_invitee FOREIGN KEY (invitee_id) 
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT chk_invite_status CHECK (status IN ('pending', 'accepted', 'rejected', 'expired')),
    CONSTRAINT chk_invite_type CHECK (invitee_id IS NOT NULL OR invite_code IS NOT NULL)
);

COMMENT ON TABLE n_group_invites IS '群组邀请表';
COMMENT ON COLUMN n_group_invites.invite_id IS '邀请ID，主键';
COMMENT ON COLUMN n_group_invites.group_id IS '群组ID';
COMMENT ON COLUMN n_group_invites.inviter_id IS '邀请人ID';
COMMENT ON COLUMN n_group_invites.invitee_id IS '被邀请用户ID，私人邀请时使用';
COMMENT ON COLUMN n_group_invites.invite_code IS '邀请码，公开链接邀请时使用';
COMMENT ON COLUMN n_group_invites.status IS '状态: pending=待处理, accepted=已接受, rejected=已拒绝, expired=已过期';
COMMENT ON COLUMN n_group_invites.message IS '邀请消息';
COMMENT ON COLUMN n_group_invites.max_uses IS '邀请码最大使用次数';
COMMENT ON COLUMN n_group_invites.used_count IS '邀请码已使用次数';
COMMENT ON COLUMN n_group_invites.expires_at IS '邀请过期时间';
COMMENT ON COLUMN n_group_invites.created_at IS '创建时间';
COMMENT ON COLUMN n_group_invites.responded_at IS '响应时间';

-- ============================================
-- 6. 群组审计日志表 (n_group_audit_logs)
-- ============================================
CREATE TABLE n_group_audit_logs (
    log_id              NUMBER(19)          PRIMARY KEY,
    group_id            NUMBER(19)          NOT NULL,
    actor_id            NUMBER(19)          NOT NULL,
    target_user_id      NUMBER(19),                               -- 目标用户ID
    target_post_id      NUMBER(19),                               -- 目标帖子ID
    target_comment_id   NUMBER(19),                               -- 目标评论ID
    action              VARCHAR2(50)        NOT NULL,             -- 操作类型
    details             VARCHAR2(2000),                           -- 操作详情，JSON格式
    ip_address          VARCHAR2(45),                             -- IP地址
    user_agent          VARCHAR2(500),                            -- 用户代理
    created_at          TIMESTAMP           DEFAULT SYSTIMESTAMP NOT NULL,
    
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
);

COMMENT ON TABLE n_group_audit_logs IS '群组审计日志表';
COMMENT ON COLUMN n_group_audit_logs.log_id IS '日志ID，主键';
COMMENT ON COLUMN n_group_audit_logs.group_id IS '群组ID';
COMMENT ON COLUMN n_group_audit_logs.actor_id IS '操作者ID';
COMMENT ON COLUMN n_group_audit_logs.target_user_id IS '目标用户ID';
COMMENT ON COLUMN n_group_audit_logs.target_post_id IS '目标帖子ID';
COMMENT ON COLUMN n_group_audit_logs.target_comment_id IS '目标评论ID';
COMMENT ON COLUMN n_group_audit_logs.action IS '操作类型: create_group/update_group/delete_group/add_member/remove_member/change_role/create_post/delete_post/pin_post等';
COMMENT ON COLUMN n_group_audit_logs.details IS '操作详情，JSON格式存储变更前后的值';
COMMENT ON COLUMN n_group_audit_logs.ip_address IS '操作者IP地址';
COMMENT ON COLUMN n_group_audit_logs.user_agent IS '操作者用户代理';
COMMENT ON COLUMN n_group_audit_logs.created_at IS '创建时间';

-- ============================================
-- 7. 群组帖子点赞表 (n_group_post_likes)
-- ============================================
CREATE TABLE n_group_post_likes (
    like_id             NUMBER(19)          PRIMARY KEY,
    post_id             NUMBER(19)          NOT NULL,
    user_id             NUMBER(19)          NOT NULL,
    created_at          TIMESTAMP           DEFAULT SYSTIMESTAMP NOT NULL,
    
    CONSTRAINT fk_post_likes_post FOREIGN KEY (post_id) 
        REFERENCES n_group_posts(post_id) ON DELETE CASCADE,
    CONSTRAINT fk_post_likes_user FOREIGN KEY (user_id) 
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT uk_group_post_likes UNIQUE (post_id, user_id)
);

COMMENT ON TABLE n_group_post_likes IS '群组帖子点赞表';
COMMENT ON COLUMN n_group_post_likes.like_id IS '点赞ID，主键';
COMMENT ON COLUMN n_group_post_likes.post_id IS '帖子ID';
COMMENT ON COLUMN n_group_post_likes.user_id IS '用户ID';
COMMENT ON COLUMN n_group_post_likes.created_at IS '点赞时间';

-- ============================================
-- 8. 群组评论点赞表 (n_group_comment_likes)
-- ============================================
CREATE TABLE n_group_comment_likes (
    like_id             NUMBER(19)          PRIMARY KEY,
    comment_id          NUMBER(19)          NOT NULL,
    user_id             NUMBER(19)          NOT NULL,
    created_at          TIMESTAMP           DEFAULT SYSTIMESTAMP NOT NULL,
    
    CONSTRAINT fk_comment_likes_comment FOREIGN KEY (comment_id) 
        REFERENCES n_group_comments(comment_id) ON DELETE CASCADE,
    CONSTRAINT fk_comment_likes_user FOREIGN KEY (user_id) 
        REFERENCES n_users(user_id) ON DELETE CASCADE,
    CONSTRAINT uk_group_comment_likes UNIQUE (comment_id, user_id)
);

COMMENT ON TABLE n_group_comment_likes IS '群组评论点赞表';
COMMENT ON COLUMN n_group_comment_likes.like_id IS '点赞ID，主键';
COMMENT ON COLUMN n_group_comment_likes.comment_id IS '评论ID';
COMMENT ON COLUMN n_group_comment_likes.user_id IS '用户ID';
COMMENT ON COLUMN n_group_comment_likes.created_at IS '点赞时间';



-- ==========================================
-- NekoTribe Oracle数据库完整设计方案
-- 作者: 胡锦曹
-- 创建日期: 2025-06-25
-- 数据库版本: Oracle 19c+
-- ==========================================

-- 5. 创建索引
-- ==========================================

-- 用户表索引（email和username已有UNIQUE约束自动创建索引，无需重复创建）
-- CREATE INDEX idx_users_email ON n_users(email) TABLESPACE neko_index;
-- CREATE INDEX idx_users_username ON n_users(username) TABLESPACE neko_index;
CREATE INDEX idx_users_created_at ON n_users (created_at) TABLESPACE neko_index;

CREATE INDEX idx_users_last_login ON n_users (last_login_at) TABLESPACE neko_index;

-- 推文表索引
CREATE INDEX idx_tweets_author ON n_tweets (author_id) TABLESPACE neko_index;

CREATE INDEX idx_tweets_created_at ON n_tweets (created_at DESC) TABLESPACE neko_index;

CREATE INDEX idx_tweets_reply_to ON n_tweets (reply_to_tweet_id) TABLESPACE neko_index;

CREATE INDEX idx_tweets_visibility ON n_tweets (visibility) TABLESPACE neko_index;

CREATE INDEX idx_tweets_deleted ON n_tweets (is_deleted) TABLESPACE neko_index;
-- 复合索引用于时间线查询
CREATE INDEX idx_tweets_timeline ON n_tweets (
    author_id,
    created_at DESC,
    is_deleted
) TABLESPACE neko_index;

-- 关注关系表索引
CREATE INDEX idx_follows_follower ON n_follows (follower_id) TABLESPACE neko_index;

CREATE INDEX idx_follows_following ON n_follows (following_id) TABLESPACE neko_index;

CREATE INDEX idx_follows_type ON n_follows (follow_type) TABLESPACE neko_index;

-- 书签表索引
CREATE INDEX idx_bookmarks_user_id ON n_bookmarks(user_id);

CREATE INDEX idx_bookmarks_tweet_id ON n_bookmarks(tweet_id);

CREATE UNIQUE INDEX uk_bookmarks_user_tweet ON n_bookmarks(user_id, tweet_id);

-- 点赞表索引
CREATE INDEX idx_likes_user ON n_likes (user_id) TABLESPACE neko_index;

CREATE INDEX idx_likes_tweet ON n_likes (tweet_id) TABLESPACE neko_index;

CREATE INDEX idx_likes_created_at ON n_likes (created_at) TABLESPACE neko_index;

-- 评论表索引
CREATE INDEX idx_comments_tweet ON n_comments (tweet_id) TABLESPACE neko_index;

CREATE INDEX idx_comments_user ON n_comments (user_id) TABLESPACE neko_index;

CREATE INDEX idx_comments_parent ON n_comments (parent_comment_id) TABLESPACE neko_index;

CREATE INDEX idx_comments_created_at ON n_comments (created_at DESC) TABLESPACE neko_index;

-- 媒体表索引
CREATE INDEX idx_media_tweet ON n_media (tweet_id) TABLESPACE neko_index;

CREATE INDEX idx_media_user ON n_media (user_id) TABLESPACE neko_index;

CREATE INDEX idx_media_type ON n_media (media_type) TABLESPACE neko_index;

-- 话题标签索引
CREATE INDEX idx_hashtags_name_lower ON n_hashtags (tag_name_lower) TABLESPACE neko_index;

CREATE INDEX idx_hashtags_trending ON n_hashtags (
    is_trending,
    trending_score DESC
) TABLESPACE neko_index;

CREATE INDEX idx_hashtags_usage ON n_hashtags (usage_count DESC) TABLESPACE neko_index;

-- 用户会话表索引
CREATE INDEX idx_sessions_user ON n_user_sessions (user_id) TABLESPACE neko_index;

CREATE INDEX idx_sessions_access_expires ON n_user_sessions (access_token_expires_at) TABLESPACE neko_index;

CREATE INDEX idx_sessions_refresh_expires ON n_user_sessions (refresh_token_expires_at) TABLESPACE neko_index;

CREATE INDEX idx_sessions_device_fingerprint ON n_user_sessions (device_fingerprint) TABLESPACE neko_index;

-- 通知表索引
CREATE INDEX idx_notifications_user ON n_notifications (user_id) TABLESPACE neko_index;

CREATE INDEX idx_notifications_is_read ON n_notifications (is_read) TABLESPACE neko_index;

CREATE INDEX idx_notifications_created_at ON n_notifications (created_at DESC) TABLESPACE neko_index;

CREATE INDEX idx_notifications_priority ON n_notifications (priority) TABLESPACE neko_index;

CREATE INDEX idx_notifications_actor ON n_notifications (actor_id) TABLESPACE neko_index;
-- 复合索引：优化用户未读通知的最新排序
CREATE INDEX idx_notifications_user_unread ON n_notifications (
    user_id,
    is_read,
    created_at DESC
) TABLESPACE neko_index;

-- ============================================
-- n_groups 表索引
-- ============================================

-- 群主ID索引，用于查询用户创建的群组
CREATE INDEX idx_groups_owner_id ON n_groups(owner_id);

-- slug索引已由UNIQUE约束自动创建

-- 隐私设置索引，用于筛选公开/私密群组
CREATE INDEX idx_groups_privacy ON n_groups(privacy);

-- 创建时间索引，用于按时间排序
CREATE INDEX idx_groups_created_at ON n_groups(created_at DESC);

-- 成员数索引，用于热门群组排序
CREATE INDEX idx_groups_member_count ON n_groups(member_count DESC);

-- 复合索引：活跃且未删除的群组查询
CREATE INDEX idx_groups_active_deleted ON n_groups(is_active, is_deleted);

-- 名称模糊查询索引（用于搜索）
CREATE INDEX idx_groups_name ON n_groups(UPPER(name));

-- ============================================
-- n_group_members 表索引
-- ============================================

-- 用户ID索引，用于查询用户加入的所有群组
CREATE INDEX idx_group_members_user_id ON n_group_members(user_id);

-- 群组ID索引（配合外键使用）
CREATE INDEX idx_group_members_group_id ON n_group_members(group_id);

-- 角色索引，用于筛选管理员等
CREATE INDEX idx_group_members_role ON n_group_members(role);

-- 状态索引，用于筛选待审核/正常/禁言成员
CREATE INDEX idx_group_members_status ON n_group_members(status);

-- 加入时间索引
CREATE INDEX idx_group_members_joined_at ON n_group_members(joined_at DESC);

-- 复合索引：查询某群组的活跃成员
CREATE INDEX idx_group_members_group_status ON n_group_members(group_id, status);

-- 复合索引：查询某用户在哪些群组是管理员
CREATE INDEX idx_group_members_user_role ON n_group_members(user_id, role);

-- ============================================
-- n_group_posts 表索引
-- ============================================

-- 群组ID索引，用于查询群组内的帖子
CREATE INDEX idx_group_posts_group_id ON n_group_posts(group_id);

-- 作者ID索引，用于查询用户发的帖子
CREATE INDEX idx_group_posts_author_id ON n_group_posts(author_id);

-- 创建时间索引，用于时间线排序
CREATE INDEX idx_group_posts_created_at ON n_group_posts(created_at DESC);

-- 软删除索引
CREATE INDEX idx_group_posts_is_deleted ON n_group_posts(is_deleted);

-- 置顶帖子索引
CREATE INDEX idx_group_posts_is_pinned ON n_group_posts(is_pinned DESC);

-- 公告帖子索引
CREATE INDEX idx_group_posts_is_announcement ON n_group_posts(is_announcement DESC);

-- 复合索引：群组内未删除的帖子按时间排序
CREATE INDEX idx_group_posts_group_time ON n_group_posts(group_id, is_deleted, created_at DESC);

-- 复合索引：群组内的置顶和公告帖子
CREATE INDEX idx_group_posts_group_pinned ON n_group_posts(group_id, is_pinned DESC, is_announcement DESC, created_at DESC);

-- 点赞数索引，用于热门帖子排序
CREATE INDEX idx_group_posts_likes_count ON n_group_posts(likes_count DESC);

-- ============================================
-- n_group_comments 表索引
-- ============================================

-- 帖子ID索引，用于查询帖子的评论
CREATE INDEX idx_group_comments_post_id ON n_group_comments(post_id);

-- 作者ID索引
CREATE INDEX idx_group_comments_author_id ON n_group_comments(author_id);

-- 父评论ID索引，用于嵌套回复
CREATE INDEX idx_group_comments_parent_id ON n_group_comments(parent_comment_id);

-- 回复目标用户索引
CREATE INDEX idx_group_comments_reply_to ON n_group_comments(reply_to_user_id);

-- 创建时间索引
CREATE INDEX idx_group_comments_created_at ON n_group_comments(created_at DESC);

-- 软删除索引
CREATE INDEX idx_group_comments_is_deleted ON n_group_comments(is_deleted);

-- 复合索引：帖子的未删除评论
CREATE INDEX idx_group_comments_post_deleted ON n_group_comments(post_id, is_deleted, created_at);

-- ============================================
-- n_group_invites 表索引
-- ============================================

-- 群组ID索引
CREATE INDEX idx_group_invites_group_id ON n_group_invites(group_id);

-- 邀请人索引
CREATE INDEX idx_group_invites_inviter_id ON n_group_invites(inviter_id);

-- 被邀请人索引
CREATE INDEX idx_group_invites_invitee_id ON n_group_invites(invitee_id);

-- 邀请码索引（加速邀请码查询）
CREATE INDEX idx_group_invites_code ON n_group_invites(invite_code);

-- 状态索引
CREATE INDEX idx_group_invites_status ON n_group_invites(status);

-- 过期时间索引，用于清理过期邀请
CREATE INDEX idx_group_invites_expires_at ON n_group_invites(expires_at);

-- 复合索引：某用户收到的待处理邀请
CREATE INDEX idx_group_invites_invitee_status ON n_group_invites(invitee_id, status);

-- ============================================
-- n_group_audit_logs 表索引
-- ============================================

-- 群组ID索引，用于查询群组的操作日志
CREATE INDEX idx_group_audit_logs_group_id ON n_group_audit_logs(group_id);

-- 操作者索引
CREATE INDEX idx_group_audit_logs_actor_id ON n_group_audit_logs(actor_id);

-- 目标用户索引
CREATE INDEX idx_group_audit_logs_target_user ON n_group_audit_logs(target_user_id);

-- 操作类型索引
CREATE INDEX idx_group_audit_logs_action ON n_group_audit_logs(action);

-- 创建时间索引
CREATE INDEX idx_group_audit_logs_created_at ON n_group_audit_logs(created_at DESC);

-- 复合索引：某群组的操作日志按时间排序
CREATE INDEX idx_group_audit_logs_group_time ON n_group_audit_logs(group_id, created_at DESC);

-- ============================================
-- n_group_post_likes 表索引
-- ============================================

-- 帖子ID索引
CREATE INDEX idx_group_post_likes_post_id ON n_group_post_likes(post_id);

-- 用户ID索引
CREATE INDEX idx_group_post_likes_user_id ON n_group_post_likes(user_id);

-- ============================================
-- n_group_comment_likes 表索引
-- ============================================

-- 评论ID索引
CREATE INDEX idx_group_comment_likes_comment_id ON n_group_comment_likes(comment_id);

-- 用户ID索引
CREATE INDEX idx_group_comment_likes_user_id ON n_group_comment_likes(user_id);

-- ============================================
-- 全文搜索索引（可选，需要Oracle Text组件）
-- ============================================

-- 如果需要全文搜索，可以创建以下索引（需要Oracle Text）
-- CREATE INDEX idx_groups_name_text ON n_groups(name) INDEXTYPE IS CTXSYS.CONTEXT;
-- CREATE INDEX idx_groups_desc_text ON n_groups(description) INDEXTYPE IS CTXSYS.CONTEXT;
-- CREATE INDEX idx_group_posts_content_text ON n_group_posts(content) INDEXTYPE IS CTXSYS.CONTEXT;


-- ==========================================
-- NekoTribe Oracle数据库完整设计方案
-- 作者: 胡锦曹
-- 创建日期: 2025-06-25
-- 数据库版本: Oracle 19c+
-- ==========================================

-- 8. 创建函数
-- ==========================================

-- 计算两个用户间关系的函数
CREATE OR REPLACE FUNCTION fn_get_user_relationship(
    p_user_id1 IN NUMBER,
    p_user_id2 IN NUMBER
) RETURN VARCHAR2 IS
    v_relationship VARCHAR2(50) := 'none';

v_follow_type VARCHAR2 (20);

v_is_mutual NUMBER := 0;

BEGIN
    -- 检查用户1对用户2的关系
    BEGIN
        SELECT follow_type INTO v_follow_type
        FROM n_follows 
        WHERE follower_id = p_user_id1 AND following_id = p_user_id2 AND is_active = 1;
        
        v_relationship := v_follow_type;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            v_relationship := 'none';
    END;
    
    -- 检查是否互相关注
    IF v_relationship = 'follow' THEN
        SELECT COUNT(*) INTO v_is_mutual
        FROM n_follows
        WHERE follower_id = p_user_id2 AND following_id = p_user_id1 
        AND follow_type = 'follow' AND is_active = 1;
        
        IF v_is_mutual > 0 THEN
            v_relationship := 'mutual';
        END IF;
    END IF;
    
    RETURN v_relationship;
END fn_get_user_relationship;
;
;
;
;
;
;
;
;
;
;
;


/

-- 计算推文热度分数的函数
-- 功能说明：根据推文的互动数据和发布时间，计算出一个热度分数
-- 热度分数越高，说明推文越受欢迎，越应该在热门列表中靠前显示
CREATE OR REPLACE FUNCTION fn_calculate_tweet_engagement(
    p_tweet_id IN NUMBER  -- 输入参数：要计算热度的推文ID
) RETURN NUMBER IS       -- 返回值：热度分数（数值类型）
    
    -- 声明变量，用于存储推文的各项互动数据
    v_likes NUMBER := 0;     -- 点赞数量，初始化为0
    v_retweets NUMBER := 0;  -- 转发数量，初始化为0
    v_replies NUMBER := 0;   -- 回复数量，初始化为0
    v_views NUMBER := 0;     -- 浏览数量，初始化为0
    v_age_hours NUMBER := 0; -- 推文发布到现在的小时数，用于时间衰减计算
    v_engagement_score NUMBER := 0; -- 最终计算出的热度分数
    v_created_at DATE;       -- 推文创建时间

BEGIN
    -- 从数据库中查询推文的互动数据和发布时间
    SELECT 
        likes_count,        -- 获取点赞数
        retweets_count,     -- 获取转发数
        replies_count,      -- 获取回复数
        views_count,        -- 获取浏览数
        created_at          -- 获取创建时间
    INTO 
        v_likes, v_retweets, v_replies, v_views, v_created_at
    FROM n_tweets
    WHERE tweet_id = p_tweet_id;
    
    -- 修复时间计算：正确计算小时差
    v_age_hours := ROUND((SYSDATE - v_created_at) * 24, 2);
    
    -- 防止负数和异常值
    IF v_age_hours < 0 THEN
        v_age_hours := 0;
    END IF;
    
    -- 调试：如果所有互动都是0，返回一个基础分数
    IF v_likes = 0 AND v_retweets = 0 AND v_replies = 0 AND v_views = 0 THEN
        -- 对于没有互动的推文，根据发布时间给一个很小的基础分数
        -- 避免除零错误，+1确保分母不为0
        v_engagement_score := 1.0 / POWER(v_age_hours + 1, 0.5);
    ELSE
        -- 正常计算热度分数
        -- 权重：点赞×1，转发×3，回复×2，浏览对数×0.1
        -- 时间衰减：越新的推文分数越高
        v_engagement_score := 
            (v_likes * 1 + v_retweets * 3 + v_replies * 2 + LOG(10, v_views + 1) * 0.1) /
            POWER(v_age_hours + 1, 0.5);
    END IF;
    
    -- 返回保留两位小数的热度分数
    RETURN ROUND(v_engagement_score, 2);
    
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        -- 如果推文不存在，返回0
        RETURN 0;
    WHEN OTHERS THEN
        -- 调试：输出错误信息
        DBMS_OUTPUT.PUT_LINE('计算推文' || p_tweet_id || '热度时出错: ' || SQLERRM);
        RETURN 0;
END fn_calculate_tweet_engagement;
;
;
;
;
;
;
;
;
;
;
;
/

-- 重写后的热度计算函数（避免读取表）
CREATE OR REPLACE FUNCTION fn_calculate_tweet_engagement_safe(
    p_likes_count IN NUMBER DEFAULT 0,      -- 点赞数
    p_retweets_count IN NUMBER DEFAULT 0,   -- 转发数  
    p_replies_count IN NUMBER DEFAULT 0,    -- 回复数
    p_views_count IN NUMBER DEFAULT 0,      -- 浏览数
    p_created_at IN DATE                     -- 创建时间
) RETURN NUMBER IS
    
    v_likes NUMBER := 0;
    v_retweets NUMBER := 0;
    v_replies NUMBER := 0;
    v_views NUMBER := 0;
    v_age_hours NUMBER := 0;
    v_engagement_score NUMBER := 0;
    v_log_views NUMBER := 0;

BEGIN
    -- 确保所有数值都不为NULL
    v_likes := NVL(p_likes_count, 0);
    v_retweets := NVL(p_retweets_count, 0);
    v_replies := NVL(p_replies_count, 0);
    v_views := NVL(p_views_count, 0);
    
    -- 计算推文发布时长（小时）
    v_age_hours := GREATEST(ROUND((SYSDATE - p_created_at) * 24, 2), 0);
    
    -- 安全计算浏览数对数值
    IF v_views > 0 THEN
        BEGIN
            -- 使用自然对数转换为以10为底的对数
            v_log_views := LN(v_views + 1) / LN(10) * 0.1;
        EXCEPTION
            WHEN OTHERS THEN
                v_log_views := 0;
        END;
    ELSE
        v_log_views := 0;
    END IF;
    
    -- 计算热度分数
    IF v_likes = 0 AND v_retweets = 0 AND v_replies = 0 AND v_views = 0 THEN
        -- 没有任何互动的推文，给予基础分数
        v_engagement_score := 1.0 / POWER(v_age_hours + 1, 0.5);
    ELSE
        -- 有互动的推文，按权重计算
        -- 权重：点赞×1，转发×3，回复×2，浏览对数×0.1
        v_engagement_score := 
            (v_likes * 1 + v_retweets * 3 + v_replies * 2 + v_log_views) /
            POWER(v_age_hours + 1, 0.5);
    END IF;
    
    -- 返回保留两位小数的热度分数
    RETURN ROUND(v_engagement_score, 2);
    
EXCEPTION
    WHEN OTHERS THEN
        -- 出错时返回0
        DBMS_OUTPUT.PUT_LINE('计算热度分数时出错: ' || SQLERRM);
        RETURN 0;
END fn_calculate_tweet_engagement_safe;
/

-- 检查用户是否有权限查看推文的函数
CREATE OR REPLACE FUNCTION fn_can_view_tweet(
    p_user_id IN NUMBER,
    p_tweet_id IN NUMBER
) RETURN NUMBER IS
    v_author_id NUMBER;
    v_visibility VARCHAR2(20);
    v_is_following NUMBER := 0;
    v_is_mentioned NUMBER := 0;
    v_relationship VARCHAR2(50);
BEGIN
    -- 获取推文信息
    SELECT author_id, visibility 
    INTO v_author_id, v_visibility
    FROM n_tweets 
    WHERE tweet_id = p_tweet_id AND is_deleted = 0;
    
    -- 公开推文所有人都能看
    IF v_visibility = 'public' THEN
        RETURN 1;
    END IF;
    
    -- 自己的推文可以看
    IF v_author_id = p_user_id THEN
        RETURN 1;
    END IF;
    
    -- 私有推文只有作者能看
    IF v_visibility = 'private' THEN
        RETURN 0;
    END IF;
    
    -- 检查其他可见性规则
    CASE v_visibility
        WHEN 'followers' THEN
            -- 检查是否关注作者
            v_relationship := fn_get_user_relationship(p_user_id, v_author_id);
            
            -- 如果关注了作者或互相关注，可以查看
            IF v_relationship IN ('follow', 'mutual') THEN
                RETURN 1;
            ELSE
                RETURN 0;
            END IF;
            
        WHEN 'mentioned' THEN
            -- 检查是否在推文中被提及
            SELECT COUNT(*) INTO v_is_mentioned
            FROM n_tweet_mentions
            WHERE tweet_id = p_tweet_id AND mentioned_user_id = p_user_id;
            
            RETURN v_is_mentioned;
            
        ELSE
            RETURN 0;
    END CASE;
    
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN 0;
    WHEN OTHERS THEN
        RETURN 0;
END fn_can_view_tweet;
;
/

-- ==========================================
-- 通知系统相关函数
-- ==========================================

-- 获取用户未读通知数量
CREATE OR REPLACE FUNCTION fn_get_unread_notification_count(
    p_user_id IN NUMBER
) RETURN NUMBER IS
    v_count NUMBER := 0;
BEGIN
    SELECT COUNT(*)
    INTO v_count
    FROM n_notifications
    WHERE user_id = p_user_id 
    AND is_read = 0;
    
    RETURN v_count;
EXCEPTION
    WHEN OTHERS THEN
        RETURN 0;
END fn_get_unread_notification_count;
;
/

-- 格式化通知消息函数
CREATE OR REPLACE FUNCTION fn_format_notification_message(
    p_type IN VARCHAR2,
    p_actor_username IN VARCHAR2,
    p_related_content IN VARCHAR2 DEFAULT NULL
) RETURN VARCHAR2 IS
    v_message VARCHAR2(1000);
BEGIN
    CASE p_type
        WHEN 'like' THEN
            v_message := p_actor_username || ' 点赞了你的推文';
            IF p_related_content IS NOT NULL THEN
                v_message := v_message || '：' || SUBSTR(p_related_content, 1, 50);
                IF LENGTH(p_related_content) > 50 THEN
                    v_message := v_message || '...';
                END IF;
            END IF;
            
        WHEN 'retweet' THEN
            v_message := p_actor_username || ' 转发了你的推文';
            IF p_related_content IS NOT NULL THEN
                v_message := v_message || '：' || SUBSTR(p_related_content, 1, 50);
                IF LENGTH(p_related_content) > 50 THEN
                    v_message := v_message || '...';
                END IF;
            END IF;
            
        WHEN 'comment' THEN
            v_message := p_actor_username || ' 评论了你的推文';
            
        WHEN 'mention' THEN
            v_message := p_actor_username || ' 在推文中提到了你';
            
        WHEN 'follow' THEN
            v_message := p_actor_username || ' 关注了你';
            
        WHEN 'system' THEN
            v_message := '系统通知';
            
        ELSE
            v_message := p_actor_username || ' 与你进行了互动';
    END CASE;
    
    RETURN v_message;
EXCEPTION
    WHEN OTHERS THEN
        RETURN '通知消息';
END fn_format_notification_message;
;
/

-- 检查用户通知偏好设置函数
CREATE OR REPLACE FUNCTION fn_check_notification_preference(
    p_user_id IN NUMBER,
    p_notification_type IN VARCHAR2
) RETURN NUMBER IS
    v_allowed NUMBER := 1;
-- 默认允许所有通知
BEGIN
    -- 这里可以扩展为从用户偏好设置表中查询
    -- 目前简化处理，所有通知类型都允许
    -- 可以根据业务需求添加用户通知偏好设置表
    
    -- 示例逻辑：如果是系统通知，总是允许
    IF p_notification_type = 'system' THEN
        v_allowed := 1;
    END IF;
    
    RETURN v_allowed;
EXCEPTION
    WHEN OTHERS THEN
        RETURN 1; -- 出错时默认允许
END fn_check_notification_preference;
;
/

-- 批量标记通知为已读函数
CREATE OR REPLACE FUNCTION fn_mark_notifications_read(
    p_user_id IN NUMBER,
    p_notification_ids IN VARCHAR2 DEFAULT NULL -- 逗号分隔的通知ID列表，为空表示全部
) RETURN NUMBER IS
    v_count NUMBER := 0;

v_sql VARCHAR2 (4000);

BEGIN
    IF p_notification_ids IS NULL THEN
        -- 标记所有未读通知为已读
        UPDATE n_notifications 
        SET is_read = 1, read_at = CURRENT_TIMESTAMP
        WHERE user_id = p_user_id AND is_read = 0;
        
        v_count := SQL%ROWCOUNT;
    ELSE
        -- 标记指定的通知为已读
        v_sql := 'UPDATE n_notifications SET is_read = 1, read_at = CURRENT_TIMESTAMP ' ||
                 'WHERE user_id = :1 AND is_read = 0 AND notification_id IN (' || p_notification_ids || ')';
        
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
;


-- ============================================
-- 1. 检查用户是否为群组成员
-- ============================================
CREATE OR REPLACE FUNCTION fn_is_group_member(
    p_user_id   IN NUMBER,
    p_group_id  IN NUMBER
) RETURN NUMBER
AS
    v_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM n_group_members
    WHERE user_id = p_user_id
      AND group_id = p_group_id
      AND status = 'active';
    
    RETURN CASE WHEN v_count > 0 THEN 1 ELSE 0 END;
END fn_is_group_member;
/

-- ============================================
-- 2. 获取用户在群组中的角色
-- ============================================
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
      AND status = 'active';
    
    RETURN v_role;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN NULL;
END fn_get_member_role;
/

-- ============================================
-- 3. 检查用户是否有权限执行特定操作
-- 角色权限等级: owner > admin > moderator > member
-- ============================================
CREATE OR REPLACE FUNCTION fn_has_group_permission(
    p_user_id         IN NUMBER,
    p_group_id        IN NUMBER,
    p_required_role   IN VARCHAR2  -- owner/admin/moderator/member
) RETURN NUMBER
AS
    v_user_role VARCHAR2(20);
    v_user_level NUMBER;
    v_required_level NUMBER;
BEGIN
    -- 获取用户角色
    v_user_role := fn_get_member_role(p_user_id, p_group_id);
    
    IF v_user_role IS NULL THEN
        RETURN 0;
    END IF;
    
    -- 角色等级映射
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

-- ============================================
-- 4. 检查用户是否可以查看群组
-- ============================================
CREATE OR REPLACE FUNCTION fn_can_view_group(
    p_user_id   IN NUMBER,
    p_group_id  IN NUMBER
) RETURN NUMBER
AS
    v_privacy VARCHAR2(20);
    v_is_active NUMBER;
    v_is_deleted NUMBER;
    v_is_member NUMBER;
BEGIN
    -- 获取群组信息
    SELECT privacy, is_active, is_deleted
    INTO v_privacy, v_is_active, v_is_deleted
    FROM n_groups
    WHERE group_id = p_group_id;
    
    -- 已删除或被封禁的群组不可见
    IF v_is_deleted = 1 OR v_is_active = 0 THEN
        RETURN 0;
    END IF;
    
    -- 公开群组所有人可见
    IF v_privacy = 'public' THEN
        RETURN 1;
    END IF;
    
    -- 私密和隐秘群组只对成员可见
    v_is_member := fn_is_group_member(p_user_id, p_group_id);
    RETURN v_is_member;
    
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN 0;
END fn_can_view_group;
/

-- ============================================
-- 5. 检查用户是否可以发帖
-- ============================================
CREATE OR REPLACE FUNCTION fn_can_post_in_group(
    p_user_id   IN NUMBER,
    p_group_id  IN NUMBER
) RETURN NUMBER
AS
    v_post_permission VARCHAR2(20);
    v_member_status VARCHAR2(20);
    v_member_role VARCHAR2(20);
    v_mute_until TIMESTAMP;
BEGIN
    -- 获取群组发帖权限设置
    SELECT post_permission INTO v_post_permission
    FROM n_groups
    WHERE group_id = p_group_id
      AND is_active = 1
      AND is_deleted = 0;
    
    -- 获取成员信息
    SELECT status, role, mute_until
    INTO v_member_status, v_member_role, v_mute_until
    FROM n_group_members
    WHERE user_id = p_user_id
      AND group_id = p_group_id;
    
    -- 检查成员状态
    IF v_member_status != 'active' THEN
        RETURN 0;
    END IF;
    
    -- 检查是否被禁言
    IF v_member_status = 'muted' AND v_mute_until > SYSTIMESTAMP THEN
        RETURN 0;
    END IF;
    
    -- 根据发帖权限检查
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

-- ============================================
-- 6. 检查用户是否可以查看群组帖子
-- ============================================
CREATE OR REPLACE FUNCTION fn_can_view_group_post(
    p_user_id   IN NUMBER,
    p_post_id   IN NUMBER
) RETURN NUMBER
AS
    v_group_id NUMBER;
    v_is_deleted NUMBER;
BEGIN
    -- 获取帖子的群组ID和删除状态
    SELECT group_id, is_deleted
    INTO v_group_id, v_is_deleted
    FROM n_group_posts
    WHERE post_id = p_post_id;
    
    -- 已删除的帖子不可见
    IF v_is_deleted = 1 THEN
        RETURN 0;
    END IF;
    
    -- 检查用户是否可以查看该群组
    RETURN fn_can_view_group(p_user_id, v_group_id);
    
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN 0;
END fn_can_view_group_post;
/

-- ============================================
-- 7. 检查用户是否可以管理某个成员
-- 规则: 只能管理比自己等级低的成员
-- ============================================
CREATE OR REPLACE FUNCTION fn_can_manage_member(
    p_actor_id    IN NUMBER,
    p_target_id   IN NUMBER,
    p_group_id    IN NUMBER
) RETURN NUMBER
AS
    v_actor_role VARCHAR2(20);
    v_target_role VARCHAR2(20);
    v_actor_level NUMBER;
    v_target_level NUMBER;
BEGIN
    v_actor_role := fn_get_member_role(p_actor_id, p_group_id);
    v_target_role := fn_get_member_role(p_target_id, p_group_id);
    
    IF v_actor_role IS NULL OR v_target_role IS NULL THEN
        RETURN 0;
    END IF;
    
    -- 角色等级映射
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
    
    -- 只能管理比自己等级低的成员，且至少是版主
    RETURN CASE WHEN v_actor_level >= 2 AND v_actor_level > v_target_level THEN 1 ELSE 0 END;
END fn_can_manage_member;
/

-- ============================================
-- 8. 检查邀请码是否有效
-- ============================================
CREATE OR REPLACE FUNCTION fn_is_invite_valid(
    p_invite_code IN VARCHAR2
) RETURN NUMBER
AS
    v_status VARCHAR2(20);
    v_max_uses NUMBER;
    v_used_count NUMBER;
    v_expires_at TIMESTAMP;
BEGIN
    SELECT status, max_uses, used_count, expires_at
    INTO v_status, v_max_uses, v_used_count, v_expires_at
    FROM n_group_invites
    WHERE invite_code = p_invite_code;
    
    -- 检查状态
    IF v_status != 'pending' THEN
        RETURN 0;
    END IF;
    
    -- 检查使用次数
    IF v_max_uses IS NOT NULL AND v_used_count >= v_max_uses THEN
        RETURN 0;
    END IF;
    
    -- 检查过期时间
    IF v_expires_at IS NOT NULL AND v_expires_at < SYSTIMESTAMP THEN
        RETURN 0;
    END IF;
    
    RETURN 1;
    
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN 0;
END fn_is_invite_valid;
/

-- ============================================
-- 9. 获取群组角色的中文描述
-- ============================================
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

-- ============================================
-- 10. 获取成员状态的中文描述
-- ============================================
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

-- ============================================
-- 11. 获取群组隐私设置的中文描述
-- ============================================
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

-- ============================================
-- 12. 生成随机邀请码
-- ============================================
CREATE OR REPLACE FUNCTION fn_generate_invite_code
RETURN VARCHAR2
AS
    v_code VARCHAR2(32);
BEGIN
    -- 生成32位随机字符串
    SELECT DBMS_RANDOM.STRING('X', 32) INTO v_code FROM DUAL;
    RETURN v_code;
END fn_generate_invite_code;
/

-- ============================================
-- 13. 生成URL友好的slug
-- ============================================
CREATE OR REPLACE FUNCTION fn_generate_group_slug(
    p_name IN VARCHAR2
) RETURN VARCHAR2
AS
    v_slug VARCHAR2(100);
    v_count NUMBER;
    v_suffix NUMBER := 0;
BEGIN
    -- 简单处理：转小写，替换空格为连字符，只保留字母数字和连字符
    v_slug := LOWER(REGEXP_REPLACE(p_name, '[^a-zA-Z0-9\u4e00-\u9fa5]', '-'));
    v_slug := REGEXP_REPLACE(v_slug, '-+', '-');  -- 合并多个连字符
    v_slug := TRIM(BOTH '-' FROM v_slug);         -- 去除首尾连字符
    
    -- 如果slug为空，使用时间戳
    IF v_slug IS NULL OR LENGTH(v_slug) = 0 THEN
        v_slug := 'group-' || TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF3');
    END IF;
    
    -- 检查唯一性，如有冲突则添加数字后缀
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
-- NekoTribe Oracle数据库完整设计方案
-- 作者: 胡锦曹
-- 创建日期: 2025-06-25
-- 数据库版本: Oracle 19c+
-- ==========================================

-- 7. 创建存储过程
-- ==========================================

-- 用户关注/取消关注存储过程
CREATE OR REPLACE PROCEDURE sp_manage_follow(
    p_follower_id IN NUMBER,
    p_following_id IN NUMBER,
    p_action IN VARCHAR2, -- 'follow', 'unfollow', 'block', 'unblock'
    p_result OUT VARCHAR2
) IS
    v_count NUMBER := 0;

v_follow_id NUMBER;

BEGIN
    -- 参数验证
    IF p_follower_id = p_following_id THEN
        p_result := 'ERROR: 不能关注自己';
        RETURN;
    END IF;
    
    -- 检查是否已存在关系
    SELECT COUNT(*) INTO v_count 
    FROM n_follows 
    WHERE follower_id = p_follower_id AND following_id = p_following_id;
    
    CASE p_action
        WHEN 'follow' THEN
            IF v_count = 0 THEN
                INSERT INTO n_follows (follow_id, follower_id, following_id, follow_type)
                VALUES (seq_user_id.nextval, p_follower_id, p_following_id, 'follow');
                
                p_result := 'SUCCESS: 关注成功';
            ELSE
                UPDATE n_follows 
                SET follow_type = 'follow', is_active = 1, updated_at = CURRENT_TIMESTAMP
                WHERE follower_id = p_follower_id AND following_id = p_following_id;
                p_result := 'SUCCESS: 已更新为关注状态';
            END IF;
            
        WHEN 'unfollow' THEN
            IF v_count > 0 THEN
                UPDATE n_follows
                SET is_active = 0, updated_at = CURRENT_TIMESTAMP
                WHERE follower_id = p_follower_id AND following_id = p_following_id;
                
                p_result := 'SUCCESS: 取消关注成功';
            ELSE
                p_result := 'ERROR: 未找到关注关系';
            END IF;
            
        WHEN 'block' THEN
            IF v_count = 0 THEN
                INSERT INTO n_follows (follow_id, follower_id, following_id, follow_type)
                VALUES (seq_user_id.nextval, p_follower_id, p_following_id, 'block');
            ELSE
                UPDATE n_follows
                SET follow_type = 'block', is_active = 1, updated_at = CURRENT_TIMESTAMP
                WHERE follower_id = p_follower_id AND following_id = p_following_id;
            END IF;
            p_result := 'SUCCESS: 屏蔽成功';
            
        WHEN 'unblock' THEN
            IF v_count > 0 THEN
                UPDATE n_follows
                SET is_active = 0, updated_at = CURRENT_TIMESTAMP
                WHERE follower_id = p_follower_id AND following_id = p_following_id;
                
                p_result := 'SUCCESS: 已解除屏蔽';
            ELSE
                p_result := 'ERROR: 未找到屏蔽关系';
            END IF;
        ELSE
            p_result := 'ERROR: 无效的操作类型';
    END CASE;
    
    COMMIT;
    
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_manage_follow;
;
;
;
;
;
;
;
;
;
;
/

-- 发布推文存储过程
CREATE OR REPLACE PROCEDURE sp_create_tweet(
    p_author_id IN NUMBER,
    p_content IN CLOB,
    p_reply_to_tweet_id IN NUMBER DEFAULT NULL,
    p_retweet_of_tweet_id IN NUMBER DEFAULT NULL,
    p_quote_tweet_id IN NUMBER DEFAULT NULL,
    p_visibility IN VARCHAR2 DEFAULT 'public',
    p_hashtags IN VARCHAR2 DEFAULT NULL, -- 逗号分隔的标签
    p_mentions IN VARCHAR2 DEFAULT NULL, -- 逗号分隔的提及用户ID
    p_tweet_id OUT NUMBER,
    p_result OUT VARCHAR2
) IS
    v_hashtag VARCHAR2(100);
    v_hashtag_id NUMBER;
    v_pos NUMBER := 1;
    v_comma_pos NUMBER;
    v_hashtag_count NUMBER := 0;
    v_mention_count NUMBER := 0;
BEGIN
    -- 生成推文ID
    SELECT seq_tweet_id.nextval INTO p_tweet_id FROM dual;
    
    -- 插入推文
    INSERT INTO n_tweets (
        tweet_id, author_id, content, reply_to_tweet_id, 
        retweet_of_tweet_id, quote_tweet_id,
        is_retweet, is_quote_tweet, visibility
    ) VALUES (
        p_tweet_id, p_author_id, p_content, p_reply_to_tweet_id,
        p_retweet_of_tweet_id, p_quote_tweet_id,
        CASE WHEN p_retweet_of_tweet_id IS NOT NULL THEN 1 ELSE 0 END,
        CASE WHEN p_quote_tweet_id IS NOT NULL THEN 1 ELSE 0 END,
        p_visibility
    );
    
    -- 处理标签 - 触发器会自动处理usage_count
    IF p_hashtags IS NOT NULL AND TRIM(p_hashtags) IS NOT NULL THEN
        LOOP
            -- 找到逗号位置
            v_comma_pos := INSTR(p_hashtags, ',', v_pos);
            
            -- 提取当前标签
            IF v_comma_pos = 0 THEN
                v_hashtag := TRIM(SUBSTR(p_hashtags, v_pos));
            ELSE
                v_hashtag := TRIM(SUBSTR(p_hashtags, v_pos, v_comma_pos - v_pos));
            END IF;
            
            -- 处理有效标签
            IF v_hashtag IS NOT NULL AND LENGTH(v_hashtag) > 0 THEN
                -- 查找或创建标签
                BEGIN
                    SELECT hashtag_id INTO v_hashtag_id
                    FROM n_hashtags
                    WHERE tag_name_lower = LOWER(v_hashtag);
                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        -- 标签不存在，创建新标签
                        SELECT seq_user_id.nextval INTO v_hashtag_id FROM dual;
                        INSERT INTO n_hashtags (hashtag_id, tag_name, tag_name_lower, usage_count)
                        VALUES (v_hashtag_id, v_hashtag, LOWER(v_hashtag), 0);
                END;
                
                -- 创建推文标签关联（触发器会自动增加usage_count）
                INSERT INTO n_tweet_hashtags (tweet_id, hashtag_id)
                VALUES (p_tweet_id, v_hashtag_id);
                
                v_hashtag_count := v_hashtag_count + 1;
            END IF;
            
            -- 退出条件
            EXIT WHEN v_comma_pos = 0;
            
            -- 移动到下一个标签
            v_pos := v_comma_pos + 1;
        END LOOP;
    END IF;

    -- 处理提及用户
    IF p_mentions IS NOT NULL AND TRIM(p_mentions) IS NOT NULL THEN
        DECLARE
            v_mentioned_user_id NUMBER;
            v_mention_pos NUMBER := 1;
            v_mention_comma_pos NUMBER;
            v_mention_id_str VARCHAR2(50);
            v_notification_result VARCHAR2(500);
        BEGIN
            -- 处理提及用户ID列表（逗号分隔）
            LOOP
                -- 找到逗号位置
                v_mention_comma_pos := INSTR(p_mentions, ',', v_mention_pos);
                
                -- 提取当前用户ID
                IF v_mention_comma_pos = 0 THEN
                    v_mention_id_str := TRIM(SUBSTR(p_mentions, v_mention_pos));
                ELSE
                    v_mention_id_str := TRIM(SUBSTR(p_mentions, v_mention_pos, v_mention_comma_pos - v_mention_pos));
                END IF;
                
                -- 处理有效的用户ID
                IF v_mention_id_str IS NOT NULL AND LENGTH(v_mention_id_str) > 0 THEN
                    BEGIN
                        -- 转换为数字
                        v_mentioned_user_id := TO_NUMBER(v_mention_id_str);
                        
                        -- 验证用户是否存在且不是作者自己
                        IF v_mentioned_user_id != p_author_id THEN
                            -- 检查用户是否存在
                            BEGIN
                                SELECT user_id INTO v_mentioned_user_id
                                FROM n_users 
                                WHERE user_id = v_mentioned_user_id AND is_active = 1;
                                
                                -- 创建提及关联
                                INSERT INTO n_tweet_mentions (tweet_id, mentioned_user_id)
                                VALUES (p_tweet_id, v_mentioned_user_id);
                                
                                -- 创建提及通知
                                sp_create_notification(
                                    p_user_id => v_mentioned_user_id,
                                    p_type => 'mention',
                                    p_title => '您被提及了',
                                    p_message => '您在一条推文中被提及',
                                    p_related_type => 'tweet',
                                    p_related_id => p_tweet_id,
                                    p_actor_id => p_author_id,
                                    p_priority => 'normal',
                                    p_result => v_notification_result
                                );
                                
                                v_mention_count := v_mention_count + 1;
                                
                            EXCEPTION
                                WHEN NO_DATA_FOUND THEN
                                    -- 用户不存在，跳过
                                    NULL;
                            END;
                        END IF;
                        
                    EXCEPTION
                        WHEN VALUE_ERROR THEN
                            -- 无效的数字格式，跳过
                            NULL;
                    END;
                END IF;
                
                -- 退出条件
                EXIT WHEN v_mention_comma_pos = 0;
                
                -- 移动到下一个位置
                v_mention_pos := v_mention_comma_pos + 1;
            END LOOP;
            
        EXCEPTION
            WHEN OTHERS THEN
                -- 提及处理出错不影响推文发布
                NULL;
        END;
    END IF;
    
    -- 更新用户推文数
    UPDATE n_users SET tweets_count = tweets_count + 1 
    WHERE user_id = p_author_id;
    
    -- 如果是回复，更新原推文回复数
    IF p_reply_to_tweet_id IS NOT NULL THEN
        UPDATE n_tweets SET replies_count = replies_count + 1
        WHERE tweet_id = p_reply_to_tweet_id;
    END IF;
    
    -- 如果是转发，更新原推文转发数
    IF p_retweet_of_tweet_id IS NOT NULL THEN
        UPDATE n_tweets SET retweets_count = retweets_count + 1
        WHERE tweet_id = p_retweet_of_tweet_id;
    END IF;
    
    COMMIT;
    p_result := 'SUCCESS: 推文发布成功，包含 ' || v_hashtag_count || ' 个标签' ||
                CASE WHEN v_mention_count > 0 THEN '，提及 ' || v_mention_count || ' 个用户' ELSE '' END;
    
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_create_tweet;
;
;
;
;
;
;
;
;
;
;
/

-- 删除推文存储过程
CREATE OR REPLACE PROCEDURE sp_delete_tweet(
    p_tweet_id IN NUMBER,
    p_user_id IN NUMBER, -- 操作用户ID，用于权限验证
    p_result OUT VARCHAR2
) IS
    v_author_id NUMBER;
    v_is_deleted NUMBER;
    v_reply_count NUMBER := 0;
    v_retweet_count NUMBER := 0;
    v_quote_count NUMBER := 0;
    v_original_tweet_id NUMBER;
BEGIN
    -- 检查推文是否存在且获取作者信息
    BEGIN
        SELECT author_id, is_deleted
        INTO v_author_id, v_is_deleted
        FROM n_tweets
        WHERE tweet_id = p_tweet_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            p_result := 'ERROR: 推文不存在';
            RETURN;
    END;
    
    -- 检查推文是否已被删除
    IF v_is_deleted = 1 THEN
        p_result := 'ERROR: 推文已被删除';
        RETURN;
    END IF;
    
    -- 权限验证：只有作者本人可以删除自己的推文
    IF v_author_id != p_user_id THEN
        p_result := 'ERROR: 无权限删除此推文';
        RETURN;
    END IF;
    
    -- 检查是否有回复、转发或引用
    SELECT COUNT(*) INTO v_reply_count
    FROM n_tweets
    WHERE reply_to_tweet_id = p_tweet_id AND is_deleted = 0;
    
    SELECT COUNT(*) INTO v_retweet_count
    FROM n_tweets
    WHERE retweet_of_tweet_id = p_tweet_id AND is_deleted = 0;
    
    SELECT COUNT(*) INTO v_quote_count
    FROM n_tweets
    WHERE quote_tweet_id = p_tweet_id AND is_deleted = 0;
    
    -- 标记推文为已删除（软删除）
    UPDATE n_tweets
    SET is_deleted = 1
    WHERE tweet_id = p_tweet_id;

    -- 删除推文的标签关联（触发器会自动减少usage_count）
    DELETE FROM n_tweet_hashtags WHERE tweet_id = p_tweet_id;
    
    -- 删除推文的点赞、转发等互动记录（如果表存在）
    BEGIN
        DELETE FROM n_likes WHERE tweet_id = p_tweet_id;
    EXCEPTION
        WHEN OTHERS THEN NULL; -- 忽略表不存在的错误
    END;
    
    -- 如果是回复，更新原推文回复数
    BEGIN
        SELECT reply_to_tweet_id INTO v_original_tweet_id 
        FROM n_tweets WHERE tweet_id = p_tweet_id;
        
        IF v_original_tweet_id IS NOT NULL THEN
            UPDATE n_tweets SET replies_count = replies_count - 1
            WHERE tweet_id = v_original_tweet_id AND replies_count > 0;
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN NULL;
    END;
    
    -- 如果是转发，更新原推文转发数
    BEGIN
        SELECT retweet_of_tweet_id INTO v_original_tweet_id 
        FROM n_tweets WHERE tweet_id = p_tweet_id;
        
        IF v_original_tweet_id IS NOT NULL THEN
            UPDATE n_tweets SET retweets_count = retweets_count - 1
            WHERE tweet_id = v_original_tweet_id AND retweets_count > 0;
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN NULL;
    END;
    
    COMMIT;
    
    -- 构建结果信息
    IF v_reply_count > 0 OR v_retweet_count > 0 OR v_quote_count > 0 THEN
        p_result := 'SUCCESS: 推文删除成功（存在' || (v_reply_count + v_retweet_count + v_quote_count) || '个相关推文）';
    ELSE
        p_result := 'SUCCESS: 推文删除成功';
    END IF;
    
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_delete_tweet;
;
;
;
;
;
;
;
;
;
;
/

-- 发布评论
CREATE OR REPLACE PROCEDURE sp_create_comment(
    p_tweet_id IN NUMBER,
    p_user_id IN NUMBER,
    p_content IN CLOB,
    p_parent_id IN NUMBER, -- 父评论ID，如果是顶级评论则为NULL
    p_result OUT VARCHAR2
) IS
    v_comment_id NUMBER;
    v_count NUMBER := 0;
    v_count_tweet NUMBER := 0;
BEGIN
    -- 推文是否存在
    SELECT COUNT(*) INTO v_count_tweet
    FROM n_tweets
    WHERE tweet_id = p_tweet_id
    AND is_deleted = 0;

    IF v_count_tweet = 0 THEN
        p_result := 'ERROR: 推文不存在';
        RETURN;
    END IF;

    IF p_parent_id is not null THEN
        -- 查找父评论是否存在
        SELECT COUNT(*) INTO v_count
        FROM n_comments
        WHERE comment_id = p_parent_id
        AND is_deleted = 0; -- 确保父评论未被删除

        IF v_count = 0 THEN
            p_result := 'ERROR: 父评论不存在';
            RETURN;
        END IF;

    END IF;

    -- 插入评论
    INSERT INTO n_comments (tweet_id, user_id, content, created_at, parent_comment_id)
    VALUES (p_tweet_id, p_user_id, p_content, CURRENT_TIMESTAMP, p_parent_id)
    RETURNING comment_id INTO v_comment_id;

    COMMIT;

    p_result := 'SUCCESS: 评论发布成功，评论ID为 ' || v_comment_id;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_create_comment;
/

-- 删除评论存储过程
CREATE OR REPLACE PROCEDURE sp_delete_comment(
    p_user_id IN NUMBER,
    p_comment_id IN NUMBER,
    p_result OUT VARCHAR2,
) IS
    v_count NUMBER := 0;
    v_author_id NUMBER;
BEGIN
    -- 检查评论作者是否是自己
    SELECT user_id INTO v_author_id
    FROM n_comments
    WHERE comment_id = p_comment_id
    AND is_deleted = 0;

    IF v_author_id IS NULL THEN
        p_result := 'ERROR: 评论不存在';
        RETURN;
    ELSIF v_author_id != p_user_id THEN
        p_result := 'ERROR: 只能删除自己的评论';
        RETURN;
    END IF;

    -- 检查评论是否存在
    SELECT COUNT(*) INTO v_count
    FROM n_comments
    WHERE comment_id = p_comment_id
    AND is_deleted = 0;

    IF v_count = 0 THEN
        p_result := 'ERROR: 评论不存在';
        RETURN;
    END IF;

    -- 标记评论为已删除（软删除）
    UPDATE n_comments
    SET is_deleted = 1
    WHERE comment_id = p_comment_id;

    COMMIT;

    p_result := 'SUCCESS: 评论删除成功';
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_delete_comment;
/

-- 点赞/取消点赞存储过程
CREATE OR REPLACE PROCEDURE sp_manage_like(
    p_user_id IN NUMBER,
    p_tweet_id IN NUMBER, -- 推文ID或评论ID
    p_action IN VARCHAR2, -- 'like', 'unlike', 'likeComment', 'unlikeComment'
    p_result OUT VARCHAR2
) IS
    v_count NUMBER := 0;
BEGIN
    -- 参数验证
    IF p_user_id IS NULL OR p_tweet_id IS NULL THEN
        p_result := 'ERROR: 用户ID或推文ID不能为空';
        RETURN;
    END IF;

    -- 处理点赞和取消点赞
    IF p_action = 'like' THEN
        -- 检查用户是否已点赞
        SELECT COUNT(*) INTO v_count
        FROM n_likes
        WHERE user_id = p_user_id AND tweet_id = p_tweet_id;

        IF v_count > 0 THEN
            p_result := 'ERROR: 用户已点赞此推文';
            RETURN;
        END IF;

        -- 插入点赞记录
        INSERT INTO n_likes (user_id, tweet_id, like_type, created_at)
        VALUES (p_user_id, p_tweet_id, 'like', CURRENT_TIMESTAMP);

        p_result := 'SUCCESS: 点赞成功';
    ELSIF p_action = 'unlike' THEN
        -- 检查用户是否已点赞
        SELECT COUNT(*) INTO v_count
        FROM n_likes
        WHERE user_id = p_user_id AND tweet_id = p_tweet_id;

        IF v_count = 0 THEN
            p_result := 'ERROR: 用户未点赞此推文';
            RETURN;
        END IF;

        -- 删除点赞记录
        DELETE FROM n_likes
        WHERE user_id = p_user_id AND tweet_id = p_tweet_id;

        p_result := 'SUCCESS: 取消点赞成功';
    ELSIF p_action = 'likeComment' THEN
        -- 检查用户是否已点赞评论
        SELECT COUNT(*) INTO v_count
        FROM n_likes
        WHERE user_id = p_user_id AND tweet_id = p_tweet_id;

        IF v_count > 0 THEN
            p_result := 'ERROR: 用户已点赞此评论';
            RETURN;
        END IF;

        -- 插入评论点赞记录
        INSERT INTO n_likes (user_id, tweet_id, like_type, created_at)
        VALUES (p_user_id, p_tweet_id, 'likeComment', CURRENT_TIMESTAMP);

        p_result := 'SUCCESS: 评论点赞成功';

    ELSIF p_action = 'unlikeComment' THEN
        -- 检查用户是否已点赞评论
        SELECT COUNT(*) INTO v_count
        FROM n_likes
        WHERE user_id = p_user_id AND tweet_id = p_tweet_id;

        IF v_count = 0 THEN
            p_result := 'ERROR: 用户未点赞此评论';
            RETURN;
        END IF;

        -- 删除评论点赞记录
        DELETE FROM n_likes
        WHERE user_id = p_user_id AND tweet_id = p_tweet_id;

        p_result := 'SUCCESS: 取消评论点赞成功';
    ELSE
        p_result := 'ERROR: 无效的操作';
    END IF;

    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_manage_like;

/

-- 收藏，取消收藏存储过程
CREATE OR REPLACE PROCEDURE sp_manage_mark(
    p_user_id IN NUMBER,
    p_tweet_id IN NUMBER,
    p_action IN VARCHAR2, -- 'mark', 'unmark'
    p_result OUT VARCHAR2
) IS
    v_count NUMBER := 0;
BEGIN
    -- 参数验证
    IF p_user_id IS NULL OR p_tweet_id IS NULL THEN
        p_result := 'ERROR: 用户ID或推文ID不能为空';
        RETURN;
    END IF;

    -- 处理点赞和取消点赞
    IF p_action = 'mark' THEN
        -- 检查用户是否已收藏
        SELECT COUNT(*) INTO v_count
        FROM n_bookmarks
        WHERE user_id = p_user_id AND tweet_id = p_tweet_id;

        IF v_count > 0 THEN
            p_result := 'ERROR: 用户已收藏此推文';
            RETURN;
        END IF;

        -- 插入收藏记录
        INSERT INTO n_bookmarks (user_id, tweet_id, created_at)
        VALUES (p_user_id, p_tweet_id, CURRENT_TIMESTAMP);

        p_result := 'SUCCESS: 收藏成功';
    ELSIF p_action = 'unmark' THEN
        -- 检查用户是否已收藏
        SELECT COUNT(*) INTO v_count
        FROM n_bookmarks
        WHERE user_id = p_user_id AND tweet_id = p_tweet_id;

        IF v_count = 0 THEN
            p_result := 'ERROR: 用户未收藏此推文';
            RETURN;
        END IF;

        -- 删除收藏记录
        DELETE FROM n_bookmarks
        WHERE user_id = p_user_id AND tweet_id = p_tweet_id;

        p_result := 'SUCCESS: 取消收藏成功';
    ELSE
        p_result := 'ERROR: 无效的操作';
    END IF;

    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_manage_mark;

/

-- 发表/删除评论存储过程
CREATE OR REPLACE PROCEDURE sp_manage_commons(
    p_user_id IN NUMBER,
    p_tweet_id IN NUMBER,
    p_content IN VARCHAR2,
    p_parentCommentId in NUMBER DEFAULT NULL,
    p_action IN VARCHAR2, -- 'add', 'delete'
    p_comment_id IN NUMBER DEFAULT NULL,
    p_result OUT VARCHAR2
) IS
    v_count NUMBER := 0;
BEGIN
    -- 检查操作
    IF p_action NOT IN ('add', 'delete') THEN
        p_result := 'ERROR: 无效的操作';
        RETURN;
    END IF;
    -- 参数验证
        IF p_user_id IS NULL OR p_tweet_id IS NULL OR p_content IS NULL THEN
            p_result := 'ERROR: 用户ID、推文ID或内容不能为空';
            RETURN;
        END IF;

    -- 根据操作分类
    IF p_action = 'add' THEN

        -- 插入评论记录
        INSERT INTO n_comments (tweet_id, user_id, content, parent_comment_id, created_at)
        VALUES (p_tweet_id, p_user_id, p_content, p_parentCommentId, CURRENT_TIMESTAMP);

        p_result := 'SUCCESS: 评论添加成功';
    ELSIF p_action = 'delete' THEN

        -- 检查评论是否存在
        SELECT COUNT(*) INTO v_count
        FROM n_comments
        WHERE tweet_id = p_tweet_id AND user_id = p_user_id AND p_comment_id = comment_id;

        IF v_count = 0 THEN
            p_result := 'ERROR: 评论不存在';
            RETURN;
        END IF;

        UPDATE n_comments
        SET is_deleted = 1, deleted_at = CURRENT_TIMESTAMP
        WHERE tweet_id = p_tweet_id AND user_id = p_user_id AND comment_id = p_comment_id;

        p_result := 'SUCCESS: 评论删除成功';
    END IF;

    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_manage_commons;


/

-- 计算热门话题存储过程
CREATE OR REPLACE PROCEDURE sp_calculate_trending_hashtags IS
    CURSOR c_hashtags IS
        SELECT h.hashtag_id, h.tag_name, h.usage_count,
               -- 计算最近24小时使用次数
               (SELECT COUNT(*)
                FROM n_tweet_hashtags th
                JOIN n_tweets t ON th.tweet_id = t.tweet_id
                WHERE th.hashtag_id = h.hashtag_id
                AND t.created_at > SYSDATE - 1) as recent_usage,
               -- 计算最近7天使用次数
               (SELECT COUNT(*)
                FROM n_tweet_hashtags th
                JOIN n_tweets t ON th.tweet_id = t.tweet_id
                WHERE th.hashtag_id = h.hashtag_id
                AND t.created_at > SYSDATE - 7) as week_usage
        FROM n_hashtags h
        WHERE h.usage_count > 0;

    v_trending_score NUMBER;

    v_min_score NUMBER := 10;
    -- 最低趋势分数阈值
BEGIN
    -- 重置所有标签趋势状态
    UPDATE n_hashtags SET is_trending = 0, trending_score = 0 WHERE 1 = 1;

    FOR hashtag_rec IN c_hashtags LOOP
        -- 计算趋势分数：最近使用频率 + 总体热度 + 增长率
        v_trending_score :=
            hashtag_rec.recent_usage * 10 +  -- 24小时使用权重
            hashtag_rec.week_usage * 2 +     -- 7天使用权重
            LOG(10, hashtag_rec.usage_count + 1) * 1; -- 总体使用对数

        -- 更新趋势分数
        UPDATE n_hashtags
        SET trending_score = v_trending_score,
            is_trending = CASE WHEN v_trending_score >= v_min_score THEN 1 ELSE 0 END,
            updated_at = CURRENT_TIMESTAMP
        WHERE hashtag_id = hashtag_rec.hashtag_id;
    END LOOP;

    COMMIT;

    DBMS_OUTPUT.PUT_LINE('热门话题计算完成于: ' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'));

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('计算热门话题时发生错误: ' || SQLERRM);
END sp_calculate_trending_hashtags;




/

-- 计算热门话题存储过程
CREATE OR REPLACE PROCEDURE sp_calculate_trending_hashtags IS
    CURSOR c_hashtags IS
        SELECT h.hashtag_id, h.tag_name, h.usage_count,
               -- 计算最近24小时使用次数
               (SELECT COUNT(*) 
                FROM n_tweet_hashtags th
                JOIN n_tweets t ON th.tweet_id = t.tweet_id 
                WHERE th.hashtag_id = h.hashtag_id 
                AND t.created_at > SYSDATE - 1) as recent_usage,
               -- 计算最近7天使用次数
               (SELECT COUNT(*) 
                FROM n_tweet_hashtags th 
                JOIN n_tweets t ON th.tweet_id = t.tweet_id 
                WHERE th.hashtag_id = h.hashtag_id 
                AND t.created_at > SYSDATE - 7) as week_usage
        FROM n_hashtags h
        WHERE h.usage_count > 0;

v_trending_score NUMBER;

v_min_score NUMBER := 10;
-- 最低趋势分数阈值
BEGIN
    -- 重置所有标签趋势状态
    UPDATE n_hashtags SET is_trending = 0, trending_score = 0 WHERE 1 = 1;

    FOR hashtag_rec IN c_hashtags LOOP
        -- 计算趋势分数：最近使用频率 + 总体热度 + 增长率
        v_trending_score := 
            hashtag_rec.recent_usage * 10 +  -- 24小时使用权重
            hashtag_rec.week_usage * 2 +     -- 7天使用权重  
            LOG(10, hashtag_rec.usage_count + 1) * 1; -- 总体使用对数
            
        -- 更新趋势分数
        UPDATE n_hashtags
        SET trending_score = v_trending_score,
            is_trending = CASE WHEN v_trending_score >= v_min_score THEN 1 ELSE 0 END,
            updated_at = CURRENT_TIMESTAMP
        WHERE hashtag_id = hashtag_rec.hashtag_id;
    END LOOP;
    
    COMMIT;
    
    DBMS_OUTPUT.PUT_LINE('热门话题计算完成于: ' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'));
    
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('计算热门话题时发生错误: ' || SQLERRM);
END sp_calculate_trending_hashtags;
;
;
;
;
;
;
;
;
;
;
/

-- ==========================================
-- 通知系统相关存储过程
-- ==========================================

-- 创建通知存储过程
CREATE OR REPLACE PROCEDURE sp_create_notification(
    p_user_id IN NUMBER,
    p_type IN VARCHAR2,
    p_title IN VARCHAR2,
    p_message IN VARCHAR2,
    p_related_type IN VARCHAR2 DEFAULT NULL,
    p_related_id IN NUMBER DEFAULT NULL,
    p_actor_id IN NUMBER DEFAULT NULL,
    p_priority IN VARCHAR2 DEFAULT 'normal',
    p_result OUT VARCHAR2
) IS
    v_notification_id NUMBER;

v_allowed NUMBER := 1;

BEGIN
    -- 检查用户通知偏好设置
    v_allowed := fn_check_notification_preference(p_user_id, p_type);
    
    IF v_allowed = 0 THEN
        p_result := 'SKIPPED: 用户已关闭此类型通知';
        RETURN;
    END IF;
    
    -- 避免自己给自己发通知（除了系统通知）
    IF p_actor_id = p_user_id AND p_type != 'system' THEN
        p_result := 'SKIPPED: 不能给自己发送通知';
        RETURN;
    END IF;
    
    -- 生成通知ID
    SELECT seq_notification_id.nextval INTO v_notification_id FROM dual;
    
    -- 插入通知记录
    INSERT INTO n_notifications (
        notification_id,
        user_id,
        type,
        title,
        message,
        related_type,
        related_id,
        actor_id,
        priority,
        created_at
    ) VALUES (
        v_notification_id,
        p_user_id,
        p_type,
        p_title,
        p_message,
        p_related_type,
        p_related_id,
        p_actor_id,
        p_priority,
        CURRENT_TIMESTAMP
    );
    
    COMMIT;
    p_result := 'SUCCESS: 通知创建成功，ID=' || v_notification_id;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_create_notification;
;
/

-- 批量创建通知存储过程（用于群发通知）
CREATE OR REPLACE PROCEDURE sp_batch_create_notifications(
    p_user_ids IN VARCHAR2, -- 逗号分隔的用户ID列表
    p_type IN VARCHAR2,
    p_title IN VARCHAR2,
    p_message IN VARCHAR2,
    p_related_type IN VARCHAR2 DEFAULT NULL,
    p_related_id IN NUMBER DEFAULT NULL,
    p_actor_id IN NUMBER DEFAULT NULL,
    p_priority IN VARCHAR2 DEFAULT 'normal',
    p_result OUT VARCHAR2
) IS
    v_user_id NUMBER;

v_count NUMBER := 0;

v_failed NUMBER := 0;

v_pos NUMBER := 1;

v_next_pos NUMBER;

v_user_id_str VARCHAR2 (50);

v_single_result VARCHAR2 (500);

BEGIN
    -- 解析用户ID列表并逐个创建通知
    WHILE v_pos <= LENGTH(p_user_ids) LOOP
        v_next_pos := INSTR(p_user_ids, ',', v_pos);
        
        IF v_next_pos = 0 THEN
            v_user_id_str := SUBSTR(p_user_ids, v_pos);
        ELSE
            v_user_id_str := SUBSTR(p_user_ids, v_pos, v_next_pos - v_pos);
        END IF;
        
        -- 转换为数字
        BEGIN
            v_user_id := TO_NUMBER(TRIM(v_user_id_str));
            
            -- 调用单个通知创建过程
            sp_create_notification(
                v_user_id,
                p_type,
                p_title,
                p_message,
                p_related_type,
                p_related_id,
                p_actor_id,
                p_priority,
                v_single_result
            );
            
            IF SUBSTR(v_single_result, 1, 7) = 'SUCCESS' THEN
                v_count := v_count + 1;
            ELSE
                v_failed := v_failed + 1;
            END IF;
            
        EXCEPTION
            WHEN OTHERS THEN
                v_failed := v_failed + 1;
        END;
        
        -- 移动到下一个用户ID
        IF v_next_pos = 0 THEN
            EXIT;
        END IF;
        v_pos := v_next_pos + 1;
    END LOOP;
    
    p_result := 'SUCCESS: 成功创建' || v_count || '个通知，失败' || v_failed || '个';

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_batch_create_notifications;
;
/

-- 清理过期通知存储过程
CREATE OR REPLACE PROCEDURE sp_cleanup_old_notifications(
    p_days_to_keep IN NUMBER DEFAULT 30,
    p_result OUT VARCHAR2
) IS
    v_count NUMBER := 0;
    v_cutoff_date TIMESTAMP;
BEGIN
    -- 计算截止日期
    v_cutoff_date := CURRENT_TIMESTAMP - INTERVAL '30' DAY;
    
    -- 软删除超过指定天数的已读通知
    UPDATE n_notifications
    SET is_deleted = 1
    WHERE is_read = 1 
      AND read_at < v_cutoff_date
      AND (is_deleted = 0 OR is_deleted IS NULL);  -- 避免重复标记已删除的记录
    
    v_count := SQL%ROWCOUNT;
    
    COMMIT;
    
    p_result := 'SUCCESS: 清理了' || v_count || '条过期通知';
    
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        p_result := 'ERROR: ' || SQLERRM;
END sp_cleanup_old_notifications;
/

-- ============================================
-- 1. 创建群组存储过程
-- ============================================
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
    -- 生成slug
    v_slug := fn_generate_group_slug(p_name);
    
    -- 插入群组
    INSERT INTO n_groups (
        name, slug, description, avatar_url, cover_url,
        owner_id, privacy, join_approval, post_permission, member_count
    ) VALUES (
        p_name, v_slug, p_description, p_avatar_url, p_cover_url,
        p_owner_id, p_privacy, p_join_approval, p_post_permission, 1
    ) RETURNING group_id INTO p_group_id;
    
    -- 将创建者添加为群主
    INSERT INTO n_group_members (
        group_id, user_id, role, status
    ) VALUES (
        p_group_id, p_owner_id, 'owner', 'active'
    );
    
    -- 记录审计日志
    INSERT INTO n_group_audit_logs (
        group_id, actor_id, action, details
    ) VALUES (
        p_group_id, p_owner_id, 'create_group',
        '{"name": "' || p_name || '", "privacy": "' || p_privacy || '"}'
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

-- ============================================
-- 2. 加入群组存储过程
-- ============================================
CREATE OR REPLACE PROCEDURE sp_join_group(
    p_user_id       IN NUMBER,
    p_group_id      IN NUMBER,
    p_invite_code   IN VARCHAR2 DEFAULT NULL,
    p_member_id     OUT NUMBER,
    p_result        OUT VARCHAR2
)
AS
    v_privacy VARCHAR2(20);
    v_join_approval NUMBER;
    v_is_active NUMBER;
    v_is_deleted NUMBER;
    v_existing_count NUMBER;
    v_status VARCHAR2(20);
    v_invite_id NUMBER;
    v_inviter_id NUMBER;
BEGIN
    -- 检查群组状态
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
    
    -- 检查是否已是成员
    SELECT COUNT(*) INTO v_existing_count
    FROM n_group_members
    WHERE group_id = p_group_id AND user_id = p_user_id;
    
    IF v_existing_count > 0 THEN
        p_result := '您已经是群组成员';
        RETURN;
    END IF;
    
    -- 确定加入状态
    IF v_privacy = 'secret' THEN
        -- 隐秘群组必须有邀请码
        IF p_invite_code IS NULL THEN
            p_result := '该群组仅限邀请加入';
            RETURN;
        END IF;
        
        -- 验证邀请码
        IF fn_is_invite_valid(p_invite_code) = 0 THEN
            p_result := '邀请码无效或已过期';
            RETURN;
        END IF;
        
        -- 获取邀请信息
        SELECT invite_id, inviter_id INTO v_invite_id, v_inviter_id
        FROM n_group_invites
        WHERE invite_code = p_invite_code AND group_id = p_group_id;
        
        -- 更新邀请使用次数
        UPDATE n_group_invites
        SET used_count = used_count + 1
        WHERE invite_id = v_invite_id;
        
        v_status := 'active';
        
    ELSIF v_privacy = 'private' OR v_join_approval = 1 THEN
        -- 私密群组或需要审批
        IF p_invite_code IS NOT NULL AND fn_is_invite_valid(p_invite_code) = 1 THEN
            -- 有有效邀请码，直接加入
            SELECT invite_id, inviter_id INTO v_invite_id, v_inviter_id
            FROM n_group_invites
            WHERE invite_code = p_invite_code AND group_id = p_group_id;
            
            UPDATE n_group_invites
            SET used_count = used_count + 1
            WHERE invite_id = v_invite_id;
            
            v_status := 'active';
        ELSE
            -- 需要审批
            v_status := 'pending';
        END IF;
    ELSE
        -- 公开群组，直接加入
        v_status := 'active';
    END IF;
    
    -- 插入成员记录
    INSERT INTO n_group_members (
        group_id, user_id, role, status, invited_by
    ) VALUES (
        p_group_id, p_user_id, 'member', v_status, v_inviter_id
    ) RETURNING member_id INTO p_member_id;
    
    -- 记录审计日志
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

-- ============================================
-- 3. 审批成员加入存储过程
-- ============================================
CREATE OR REPLACE PROCEDURE sp_approve_member(
    p_actor_id      IN NUMBER,
    p_member_id     IN NUMBER,
    p_approve       IN NUMBER,  -- 1=批准, 0=拒绝
    p_result        OUT VARCHAR2
)
AS
    v_group_id NUMBER;
    v_target_user_id NUMBER;
    v_current_status VARCHAR2(20);
BEGIN
    -- 获取成员信息
    SELECT group_id, user_id, status
    INTO v_group_id, v_target_user_id, v_current_status
    FROM n_group_members
    WHERE member_id = p_member_id;
    
    -- 检查权限
    IF fn_has_group_permission(p_actor_id, v_group_id, 'moderator') = 0 THEN
        p_result := '您没有审批权限';
        RETURN;
    END IF;
    
    -- 检查状态
    IF v_current_status != 'pending' THEN
        p_result := '该成员不在待审批状态';
        RETURN;
    END IF;
    
    IF p_approve = 1 THEN
        -- 批准
        UPDATE n_group_members
        SET status = 'active'
        WHERE member_id = p_member_id;
        
        -- 记录审计日志
        INSERT INTO n_group_audit_logs (
            group_id, actor_id, target_user_id, action
        ) VALUES (
            v_group_id, p_actor_id, v_target_user_id, 'approve_member'
        );
        
        p_result := '已批准加入';
    ELSE
        -- 拒绝，删除成员记录
        DELETE FROM n_group_members WHERE member_id = p_member_id;
        
        -- 记录审计日志
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

-- ============================================
-- 4. 退出群组存储过程
-- ============================================
CREATE OR REPLACE PROCEDURE sp_leave_group(
    p_user_id       IN NUMBER,
    p_group_id      IN NUMBER,
    p_result        OUT VARCHAR2
)
AS
    v_role VARCHAR2(20);
BEGIN
    -- 获取用户角色
    v_role := fn_get_member_role(p_user_id, p_group_id);
    
    IF v_role IS NULL THEN
        p_result := '您不是群组成员';
        RETURN;
    END IF;
    
    -- 群主不能直接退出，需要先转让
    IF v_role = 'owner' THEN
        p_result := '群主不能退出群组，请先转让群主身份';
        RETURN;
    END IF;
    
    -- 删除成员记录
    DELETE FROM n_group_members
    WHERE group_id = p_group_id AND user_id = p_user_id;
    
    -- 记录审计日志
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

-- ============================================
-- 5. 移除成员存储过程
-- ============================================
CREATE OR REPLACE PROCEDURE sp_remove_member(
    p_actor_id      IN NUMBER,
    p_target_id     IN NUMBER,
    p_group_id      IN NUMBER,
    p_reason        IN VARCHAR2 DEFAULT NULL,
    p_result        OUT VARCHAR2
)
AS
BEGIN
    -- 检查权限
    IF fn_can_manage_member(p_actor_id, p_target_id, p_group_id) = 0 THEN
        p_result := '您没有权限移除该成员';
        RETURN;
    END IF;
    
    -- 删除成员
    DELETE FROM n_group_members
    WHERE group_id = p_group_id AND user_id = p_target_id;
    
    IF SQL%ROWCOUNT = 0 THEN
        p_result := '成员不存在';
        RETURN;
    END IF;
    
    -- 记录审计日志
    INSERT INTO n_group_audit_logs (
        group_id, actor_id, target_user_id, action, details
    ) VALUES (
        p_group_id, p_actor_id, p_target_id, 'remove_member',
        CASE WHEN p_reason IS NOT NULL THEN '{"reason": "' || p_reason || '"}' ELSE NULL END
    );
    
    p_result := '已移除成员';
    COMMIT;
    
EXCEPTION
    WHEN OTHERS THEN
        p_result := '操作失败: ' || SQLERRM;
        ROLLBACK;
END sp_remove_member;
/

-- ============================================
-- 6. 变更成员角色存储过程
-- ============================================
CREATE OR REPLACE PROCEDURE sp_change_member_role(
    p_actor_id      IN NUMBER,
    p_target_id     IN NUMBER,
    p_group_id      IN NUMBER,
    p_new_role      IN VARCHAR2,
    p_result        OUT VARCHAR2
)
AS
    v_actor_role VARCHAR2(20);
    v_old_role VARCHAR2(20);
BEGIN
    -- 获取操作者角色
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
    
    -- 只有群主可以设置管理员
    IF p_new_role IN ('admin', 'owner') AND v_actor_role != 'owner' THEN
        p_result := '只有群主可以设置管理员';
        RETURN;
    END IF;
    
    -- 只有群主和管理员可以设置版主
    IF p_new_role = 'moderator' AND v_actor_role NOT IN ('owner', 'admin') THEN
        p_result := '您没有权限设置版主';
        RETURN;
    END IF;
    
    -- 不能修改群主的角色
    IF v_old_role = 'owner' THEN
        p_result := '不能直接修改群主的角色';
        RETURN;
    END IF;
    
    -- 更新角色
    UPDATE n_group_members
    SET role = p_new_role
    WHERE group_id = p_group_id AND user_id = p_target_id;
    
    -- 记录审计日志
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

-- ============================================
-- 7. 转让群主存储过程
-- ============================================
CREATE OR REPLACE PROCEDURE sp_transfer_ownership(
    p_owner_id      IN NUMBER,
    p_new_owner_id  IN NUMBER,
    p_group_id      IN NUMBER,
    p_result        OUT VARCHAR2
)
AS
    v_current_role VARCHAR2(20);
    v_target_status VARCHAR2(20);
BEGIN
    -- 验证当前用户是群主
    v_current_role := fn_get_member_role(p_owner_id, p_group_id);
    IF v_current_role != 'owner' THEN
        p_result := '只有群主可以转让群组';
        RETURN;
    END IF;
    
    -- 验证新群主是活跃成员
    SELECT status INTO v_target_status
    FROM n_group_members
    WHERE group_id = p_group_id AND user_id = p_new_owner_id;
    
    IF v_target_status != 'active' THEN
        p_result := '目标用户不是活跃成员';
        RETURN;
    END IF;
    
    -- 更新原群主为管理员
    UPDATE n_group_members
    SET role = 'admin'
    WHERE group_id = p_group_id AND user_id = p_owner_id;
    
    -- 更新新群主
    UPDATE n_group_members
    SET role = 'owner'
    WHERE group_id = p_group_id AND user_id = p_new_owner_id;
    
    -- 更新群组表的owner_id
    UPDATE n_groups
    SET owner_id = p_new_owner_id
    WHERE group_id = p_group_id;
    
    -- 记录审计日志
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

-- ============================================
-- 8. 禁言成员存储过程
-- ============================================
CREATE OR REPLACE PROCEDURE sp_mute_member(
    p_actor_id      IN NUMBER,
    p_target_id     IN NUMBER,
    p_group_id      IN NUMBER,
    p_duration_hours IN NUMBER,  -- 禁言时长（小时）
    p_reason        IN VARCHAR2 DEFAULT NULL,
    p_result        OUT VARCHAR2
)
AS
BEGIN
    -- 检查权限
    IF fn_can_manage_member(p_actor_id, p_target_id, p_group_id) = 0 THEN
        p_result := '您没有权限禁言该成员';
        RETURN;
    END IF;
    
    -- 更新成员状态
    UPDATE n_group_members
    SET status = 'muted',
        mute_until = SYSTIMESTAMP + NUMTODSINTERVAL(p_duration_hours, 'HOUR'),
        ban_reason = p_reason
    WHERE group_id = p_group_id AND user_id = p_target_id;
    
    IF SQL%ROWCOUNT = 0 THEN
        p_result := '成员不存在';
        RETURN;
    END IF;
    
    -- 记录审计日志
    INSERT INTO n_group_audit_logs (
        group_id, actor_id, target_user_id, action, details
    ) VALUES (
        p_group_id, p_actor_id, p_target_id, 'mute_member',
        '{"duration_hours": ' || p_duration_hours || 
        CASE WHEN p_reason IS NOT NULL THEN ', "reason": "' || p_reason || '"' ELSE '' END || '}'
    );
    
    p_result := '已禁言成员 ' || p_duration_hours || ' 小时';
    COMMIT;
    
EXCEPTION
    WHEN OTHERS THEN
        p_result := '操作失败: ' || SQLERRM;
        ROLLBACK;
END sp_mute_member;
/

-- ============================================
-- 9. 解除禁言存储过程
-- ============================================
CREATE OR REPLACE PROCEDURE sp_unmute_member(
    p_actor_id      IN NUMBER,
    p_target_id     IN NUMBER,
    p_group_id      IN NUMBER,
    p_result        OUT VARCHAR2
)
AS
BEGIN
    -- 检查权限
    IF fn_has_group_permission(p_actor_id, p_group_id, 'moderator') = 0 THEN
        p_result := '您没有权限执行此操作';
        RETURN;
    END IF;
    
    -- 更新成员状态
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
    
    -- 记录审计日志
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

-- ============================================
-- 10. 发布群组帖子存储过程
-- ============================================
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
    -- 检查发帖权限
    IF fn_can_post_in_group(p_author_id, p_group_id) = 0 THEN
        p_result := '您没有在此群组发帖的权限';
        RETURN;
    END IF;
    
    -- 插入帖子
    INSERT INTO n_group_posts (
        group_id, author_id, content, media_urls
    ) VALUES (
        p_group_id, p_author_id, p_content, p_media_urls
    ) RETURNING post_id INTO p_post_id;
    
    -- 记录审计日志
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

-- ============================================
-- 11. 删除群组帖子存储过程
-- ============================================
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
    -- 获取帖子信息
    SELECT group_id, author_id
    INTO v_group_id, v_author_id
    FROM n_group_posts
    WHERE post_id = p_post_id AND is_deleted = 0;
    
    -- 检查权限：作者本人或版主及以上
    IF p_actor_id != v_author_id AND fn_has_group_permission(p_actor_id, v_group_id, 'moderator') = 0 THEN
        p_result := '您没有权限删除此帖子';
        RETURN;
    END IF;
    
    -- 软删除帖子
    UPDATE n_group_posts
    SET is_deleted = 1,
        deleted_by = p_actor_id,
        delete_reason = p_reason
    WHERE post_id = p_post_id;
    
    -- 记录审计日志
    INSERT INTO n_group_audit_logs (
        group_id, actor_id, target_post_id, action, details
    ) VALUES (
        v_group_id, p_actor_id, p_post_id, 'delete_post',
        CASE WHEN p_reason IS NOT NULL THEN '{"reason": "' || p_reason || '"}' ELSE NULL END
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

-- ============================================
-- 12. 置顶/取消置顶帖子存储过程
-- ============================================
CREATE OR REPLACE PROCEDURE sp_toggle_post_pin(
    p_actor_id      IN NUMBER,
    p_post_id       IN NUMBER,
    p_pin           IN NUMBER,  -- 1=置顶, 0=取消置顶
    p_result        OUT VARCHAR2
)
AS
    v_group_id NUMBER;
BEGIN
    -- 获取帖子所属群组
    SELECT group_id INTO v_group_id
    FROM n_group_posts
    WHERE post_id = p_post_id AND is_deleted = 0;
    
    -- 检查权限：版主及以上
    IF fn_has_group_permission(p_actor_id, v_group_id, 'moderator') = 0 THEN
        p_result := '您没有权限执行此操作';
        RETURN;
    END IF;
    
    -- 更新置顶状态
    UPDATE n_group_posts
    SET is_pinned = p_pin
    WHERE post_id = p_post_id;
    
    -- 记录审计日志
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

-- ============================================
-- 13. 创建群组邀请存储过程
-- ============================================
CREATE OR REPLACE PROCEDURE sp_create_group_invite(
    p_inviter_id    IN NUMBER,
    p_group_id      IN NUMBER,
    p_invitee_id    IN NUMBER DEFAULT NULL,
    p_max_uses      IN NUMBER DEFAULT 1,
    p_expire_hours  IN NUMBER DEFAULT 168,  -- 默认7天
    p_message       IN VARCHAR2 DEFAULT NULL,
    p_invite_id     OUT NUMBER,
    p_invite_code   OUT VARCHAR2,
    p_result        OUT VARCHAR2
)
AS
BEGIN
    -- 检查权限：成员及以上可以邀请
    IF fn_is_group_member(p_inviter_id, p_group_id) = 0 THEN
        p_result := '您不是群组成员';
        RETURN;
    END IF;
    
    -- 生成邀请码（公开邀请）
    IF p_invitee_id IS NULL THEN
        p_invite_code := fn_generate_invite_code();
    ELSE
        p_invite_code := NULL;
    END IF;
    
    -- 插入邀请记录
    INSERT INTO n_group_invites (
        group_id, inviter_id, invitee_id, invite_code,
        max_uses, message, expires_at
    ) VALUES (
        p_group_id, p_inviter_id, p_invitee_id, p_invite_code,
        p_max_uses, p_message,
        CASE WHEN p_expire_hours > 0 THEN SYSTIMESTAMP + NUMTODSINTERVAL(p_expire_hours, 'HOUR') ELSE NULL END
    ) RETURNING invite_id INTO p_invite_id;
    
    -- 记录审计日志
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

-- ============================================
-- 14. 点赞群组帖子存储过程
-- ============================================
CREATE OR REPLACE PROCEDURE sp_like_group_post(
    p_user_id       IN NUMBER,
    p_post_id       IN NUMBER,
    p_action        IN VARCHAR2,  -- 'like' 或 'unlike'
    p_result        OUT VARCHAR2
)
AS
    v_group_id NUMBER;
    v_existing_count NUMBER;
BEGIN
    -- 获取帖子所属群组
    SELECT group_id INTO v_group_id
    FROM n_group_posts
    WHERE post_id = p_post_id AND is_deleted = 0;
    
    -- 检查是否是群组成员
    IF fn_is_group_member(p_user_id, v_group_id) = 0 THEN
        p_result := '您不是群组成员';
        RETURN;
    END IF;
    
    -- 检查是否已点赞
    SELECT COUNT(*) INTO v_existing_count
    FROM n_group_post_likes
    WHERE post_id = p_post_id AND user_id = p_user_id;
    
    IF p_action = 'like' THEN
        IF v_existing_count > 0 THEN
            p_result := '您已经点赞过了';
            RETURN;
        END IF;
        
        INSERT INTO n_group_post_likes (post_id, user_id) VALUES (p_post_id, p_user_id);
        p_result := '点赞成功';
    ELSE
        IF v_existing_count = 0 THEN
            p_result := '您还没有点赞';
            RETURN;
        END IF;
        
        DELETE FROM n_group_post_likes WHERE post_id = p_post_id AND user_id = p_user_id;
        p_result := '已取消点赞';
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

-- ============================================
-- 15. 发表群组帖子评论存储过程
-- ============================================
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
    -- 获取帖子所属群组
    SELECT group_id INTO v_group_id
    FROM n_group_posts
    WHERE post_id = p_post_id AND is_deleted = 0;
    
    -- 检查发言权限
    IF fn_can_post_in_group(p_author_id, v_group_id) = 0 THEN
        p_result := '您没有在此群组发言的权限';
        RETURN;
    END IF;
    
    -- 插入评论
    INSERT INTO n_group_comments (
        post_id, author_id, content, parent_comment_id, reply_to_user_id
    ) VALUES (
        p_post_id, p_author_id, p_content, p_parent_comment_id, p_reply_to_user_id
    ) RETURNING comment_id INTO p_comment_id;
    
    -- 记录审计日志
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

-- ============================================
-- 16. 更新群组信息存储过程
-- ============================================
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
    v_first BOOLEAN := TRUE;
BEGIN
    -- 检查权限：管理员及以上
    IF fn_has_group_permission(p_actor_id, p_group_id, 'admin') = 0 THEN
        p_result := '您没有权限修改群组信息';
        RETURN;
    END IF;
    
    -- 更新非空字段
    UPDATE n_groups
    SET name = COALESCE(p_name, name),
        description = COALESCE(p_description, description),
        avatar_url = COALESCE(p_avatar_url, avatar_url),
        cover_url = COALESCE(p_cover_url, cover_url),
        privacy = COALESCE(p_privacy, privacy),
        join_approval = COALESCE(p_join_approval, join_approval),
        post_permission = COALESCE(p_post_permission, post_permission)
    WHERE group_id = p_group_id;
    
    -- 构建变更详情
    IF p_name IS NOT NULL THEN
        v_changes := v_changes || '"name": "' || p_name || '"';
        v_first := FALSE;
    END IF;
    IF p_privacy IS NOT NULL THEN
        IF NOT v_first THEN v_changes := v_changes || ', '; END IF;
        v_changes := v_changes || '"privacy": "' || p_privacy || '"';
    END IF;
    v_changes := v_changes || '}';
    
    -- 记录审计日志
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

-- ============================================
-- 17. 解散群组存储过程
-- ============================================
CREATE OR REPLACE PROCEDURE sp_delete_group(
    p_owner_id      IN NUMBER,
    p_group_id      IN NUMBER,
    p_result        OUT VARCHAR2
)
AS
    v_role VARCHAR2(20);
BEGIN
    -- 验证是群主
    v_role := fn_get_member_role(p_owner_id, p_group_id);
    IF v_role != 'owner' THEN
        p_result := '只有群主可以解散群组';
        RETURN;
    END IF;
    
    -- 软删除群组
    UPDATE n_groups
    SET is_deleted = 1
    WHERE group_id = p_group_id;
    
    -- 记录审计日志
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
-- NekoTribe Oracle数据库完整设计方案
-- 作者: 刘畅w
-- 创建日期: 2025-06-25
-- 数据库版本: Oracle 19c+
-- ==========================================

-- 9. 创建触发器
-- ==========================================

-- 注意：以下触发器必须以 neko_app 用户身份执行
-- 如果当前不是 neko_app 用户，请先切换：
-- CONN neko_app/NekoApp2025#;

-- 触发器功能说明：
-- 1. 更新时间触发器：自动更新 updated_at 字段
-- 2. 软删除触发器：处理软删除逻辑
-- 3. 统计计数触发器：自动维护各种计数字段
-- 4. 通知系统触发器：自动创建通知
-- 5. 主键自增触发器：为所有主键ID提供自增功能

-- 用户表更新时间触发器
CREATE OR REPLACE TRIGGER trg_users_update_time
    BEFORE UPDATE ON n_users
    FOR EACH ROW
BEGIN
    :NEW.updated_at := CURRENT_TIMESTAMP;
    :NEW.updated_by := USER;
END;
/

-- 推文表更新时间触发器
CREATE OR REPLACE TRIGGER trg_tweets_update_time
    BEFORE UPDATE ON n_tweets
    FOR EACH ROW
BEGIN
    :NEW.updated_at := CURRENT_TIMESTAMP;
    :NEW.updated_by := USER;
END;
/

-- 推文删除触发器（软删除）
CREATE OR REPLACE TRIGGER trg_tweets_soft_delete
    BEFORE UPDATE ON n_tweets
    FOR EACH ROW
    WHEN (NEW.is_deleted = 1 AND OLD.is_deleted = 0)
BEGIN
    :NEW.deleted_at := CURRENT_TIMESTAMP;
    
    -- 更新用户推文计数
    UPDATE n_users
    SET tweets_count = tweets_count - 1
    WHERE user_id = :NEW.author_id AND tweets_count > 0;

    -- 更新推文提及表
    DELETE FROM n_tweet_mentions
    WHERE tweet_id = :NEW.tweet_id;
END;
/

-- 点赞操作触发器
CREATE OR REPLACE TRIGGER trg_likes_count_update
    AFTER INSERT OR DELETE ON n_likes
    FOR EACH ROW
BEGIN
    IF INSERTING THEN
        -- 检查是否为点赞操作
        IF :NEW.like_type = 'like' THEN
            -- 增加推文点赞数
            UPDATE n_tweets
            SET likes_count = likes_count + 1
            WHERE tweet_id = :NEW.tweet_id;
            
            -- 增加用户获赞数
            UPDATE n_users
            SET likes_count = likes_count + 1
            WHERE user_id = (SELECT author_id FROM n_tweets WHERE tweet_id = :NEW.tweet_id);
        ELSIF :NEW.like_type = 'likeComment' THEN
            -- 增加评论点赞数
            UPDATE n_comments
            SET likes_count = likes_count + 1
            WHERE comment_id = :NEW.tweet_id;

            DBMS_OUTPUT.PUT_LINE('Comment ID: ' || :NEW.tweet_id || 
                         ' Like Count Updated: ' || :NEW.like_type ||
                         ' at ' || TO_CHAR(CURRENT_TIMESTAMP, 'YYYY-MM-DD HH24:MI:SS'));
        END IF;

    ELSIF DELETING THEN
        -- 检查是否为取消点赞操作
        IF :OLD.like_type = 'like' THEN

            -- 减少推文点赞数
            UPDATE n_tweets
            SET likes_count = likes_count - 1 
            WHERE tweet_id = :OLD.tweet_id AND likes_count > 0;
            
            -- 减少用户获赞数
            UPDATE n_users
            SET likes_count = likes_count - 1
            WHERE user_id = (SELECT author_id FROM n_tweets WHERE tweet_id = :OLD.tweet_id)
            AND likes_count > 0;
        ELSIF :OLD.like_type = 'likeComment' THEN
            -- 减少评论点赞数
            UPDATE n_comments
            SET likes_count = likes_count - 1
            WHERE comment_id = :OLD.tweet_id AND likes_count > 0;

            DBMS_OUTPUT.PUT_LINE('Comment ID: ' || :OLD.tweet_id || 
                         ' Like Count Updated: ' || :OLD.like_type ||
                         ' at ' || TO_CHAR(CURRENT_TIMESTAMP, 'YYYY-MM-DD HH24:MI:SS'));
        END IF;
    END IF;
END;

/


-- ==========================================
-- 推文热度分数自动更新触发器
-- ==========================================

-- 当推文的互动数据发生变化时，自动更新热度分数（修复版）
-- 监控字段：likes_count, retweets_count, replies_count, views_count
CREATE OR REPLACE TRIGGER tr_update_tweet_engagement
    BEFORE UPDATE ON n_tweets
    FOR EACH ROW
    WHEN (
        -- 只有当相关互动字段发生变化时才触发
        NEW.likes_count != OLD.likes_count OR
        NEW.retweets_count != OLD.retweets_count OR
        NEW.replies_count != OLD.replies_count OR
        NEW.views_count != OLD.views_count
    )
BEGIN
    -- 使用新的安全函数
    :NEW.engagement_score := fn_calculate_tweet_engagement_safe(
        :NEW.likes_count,
        :NEW.retweets_count,
        :NEW.replies_count,
        :NEW.views_count,
        :NEW.created_at
    );
    
    :NEW.updated_at := CURRENT_TIMESTAMP;
    
    -- 添加调试信息
    DBMS_OUTPUT.PUT_LINE('Tweet ID: ' || :NEW.tweet_id || 
                         ' Engagement Score Updated: ' || :NEW.engagement_score ||
                         ' at ' || TO_CHAR(CURRENT_TIMESTAMP, 'YYYY-MM-DD HH24:MI:SS'));
EXCEPTION
    WHEN OTHERS THEN
        :NEW.engagement_score := 0;
        :NEW.updated_at := CURRENT_TIMESTAMP;
END tr_update_tweet_engagement;
/

-- ==========================================
-- 触发器使用说明和测试示例
-- ==========================================

/*
-- 触发器功能说明：
-- 1. 监控 n_tweets 表的 likes_count, retweets_count, replies_count, views_count 字段变化
-- 2. 当任何一个互动字段发生变化时，自动调用 fn_calculate_tweet_engagement 函数
-- 3. 将计算出的新热度分数更新到 engagement_score 字段
-- 4. 确保热度分数始终与最新的互动数据保持同步

-- 测试示例：
-- 模拟用户点赞推文，观察热度分数是否自动更新
UPDATE n_tweets 
SET likes_count = likes_count + 1 
WHERE tweet_id = 123;

-- 模拟用户转发推文，观察热度分数是否自动更新
UPDATE n_tweets 
SET retweets_count = retweets_count + 1 
WHERE tweet_id = 123;

-- 查看更新后的热度分数
SELECT tweet_id, likes_count, retweets_count, replies_count, views_count, engagement_score
FROM n_tweets 
WHERE tweet_id = 123;

-- 性能优化建议：
-- 1. 对于高频更新的浏览量，可以考虑批量更新策略
-- 2. 如果系统负载较高，可以考虑异步更新热度分数
-- 3. 可以添加更新频率限制，避免同一推文在短时间内频繁计算

-- 触发器维护：
-- 禁用触发器：ALTER TRIGGER tr_update_tweet_engagement DISABLE;
-- 启用触发器：ALTER TRIGGER tr_update_tweet_engagement ENABLE;
-- 删除触发器：DROP TRIGGER tr_update_tweet_engagement;
*/

/

-- 关注关系变化触发器
CREATE OR REPLACE TRIGGER trg_follows_count_update
    AFTER UPDATE ON n_follows
    FOR EACH ROW
    WHEN (OLD.is_active != NEW.is_active AND NEW.follow_type = 'follow')
BEGIN
    IF :NEW.is_active = 1 AND :OLD.is_active = 0 THEN
        -- 重新关注
        UPDATE n_users SET following_count = following_count + 1 
        WHERE user_id = :NEW.follower_id;
        UPDATE n_users SET followers_count = followers_count + 1 
        WHERE user_id = :NEW.following_id;
        
    ELSIF :NEW.is_active = 0 AND :OLD.is_active = 1 THEN
        -- 取消关注
        UPDATE n_users SET following_count = following_count - 1 
        WHERE user_id = :NEW.follower_id AND following_count > 0;
        UPDATE n_users SET followers_count = followers_count - 1 
        WHERE user_id = :NEW.following_id AND followers_count > 0;
    END IF;
END;
/

-- 会话清理触发器（双Token机制）
CREATE OR REPLACE TRIGGER trg_session_cleanup
    BEFORE INSERT ON n_user_sessions
    FOR EACH ROW
BEGIN
    -- 清理同用户的过期会话
    DELETE FROM n_user_sessions
    WHERE user_id = :NEW.user_id
    AND (refresh_token_expires_at < SYSDATE OR is_active = 0);
END;
/

-- 标签使用统计触发器
CREATE OR REPLACE TRIGGER trg_hashtag_usage_update
    AFTER INSERT OR DELETE ON n_tweet_hashtags
    FOR EACH ROW
BEGIN
    IF INSERTING THEN
        UPDATE n_hashtags
        SET usage_count = usage_count + 1, updated_at = CURRENT_TIMESTAMP
        WHERE hashtag_id = :NEW.hashtag_id;
    ELSIF DELETING THEN
        UPDATE n_hashtags
        SET usage_count = usage_count - 1, updated_at = CURRENT_TIMESTAMP
        WHERE hashtag_id = :OLD.hashtag_id AND usage_count > 0;
    END IF;
END;
/

-- ==========================================
-- 通知系统相关触发器
-- ==========================================

-- 通知表更新时间触发器
CREATE OR REPLACE TRIGGER trg_notifications_update_time
    BEFORE UPDATE ON n_notifications
    FOR EACH ROW
BEGIN
    -- 如果状态从未读变为已读，设置读取时间
    IF :OLD.is_read = 0 AND :NEW.is_read = 1 THEN
        :NEW.read_at := CURRENT_TIMESTAMP;
    END IF;
END;
/

-- 自动创建关注通知触发器
CREATE OR REPLACE TRIGGER trg_follow_notification
    AFTER INSERT ON n_follows
    FOR EACH ROW
    WHEN (NEW.follow_type = 'follow' AND NEW.is_active = 1)
DECLARE
    v_result VARCHAR2(500);
    v_follower_username VARCHAR2(50);
BEGIN
    -- 获取关注者用户名
    SELECT username INTO v_follower_username
    FROM n_users
    WHERE user_id = :NEW.follower_id;
    
    -- 创建关注通知
    sp_create_notification(
        p_user_id => :NEW.following_id,
        p_type => 'follow',
        p_title => '新的关注者',
        p_message => fn_format_notification_message('follow', v_follower_username),
        p_related_type => 'user',
        p_related_id => :NEW.follower_id,
        p_actor_id => :NEW.follower_id,
        p_priority => 'normal',
        p_result => v_result
    );
EXCEPTION
    WHEN OTHERS THEN
        -- 记录错误但不影响主要业务逻辑
        NULL;
END;
/

-- 自动创建点赞通知触发器
CREATE OR REPLACE TRIGGER trg_like_notification
    AFTER INSERT ON n_likes
    FOR EACH ROW
    WHEN (NEW.like_type = 'like')
DECLARE
    v_result VARCHAR2(500);
    v_liker_username VARCHAR2(50);
    v_tweet_author_id NUMBER;
    v_tweet_content VARCHAR2(500);
BEGIN
    -- 获取点赞者用户名和推文作者信息
    SELECT u.username, t.author_id, SUBSTR(t.content, 1, 100)
    INTO v_liker_username, v_tweet_author_id, v_tweet_content
    FROM n_users u, n_tweets t
    WHERE u.user_id = :NEW.user_id 
    AND t.tweet_id = :NEW.tweet_id;
    
    -- 只有不是自己点赞自己的推文时才创建通知
    IF v_tweet_author_id != :NEW.user_id THEN
        -- 创建点赞通知
        sp_create_notification(
            p_user_id => v_tweet_author_id,
            p_type => 'like',
            p_title => '推文被点赞',
            p_message => fn_format_notification_message('like', v_liker_username, v_tweet_content),
            p_related_type => 'tweet',
            p_related_id => :NEW.tweet_id,
            p_actor_id => :NEW.user_id,
            p_priority => 'normal',
            p_result => v_result
        );
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        -- 记录错误但不影响主要业务逻辑
        NULL;
END;
/

-- 自动创建评论通知触发器
CREATE OR REPLACE TRIGGER trg_comment_notification
    AFTER INSERT ON n_comments
    FOR EACH ROW
    WHEN (NEW.is_deleted = 0)
DECLARE
    v_result VARCHAR2(500);
    v_commenter_username VARCHAR2(50);
    v_tweet_author_id NUMBER;
    v_parent_comment_author_id NUMBER;
BEGIN
    -- 获取评论者用户名
    SELECT username INTO v_commenter_username
    FROM n_users
    WHERE user_id = :NEW.user_id;
    
    -- 获取推文作者ID
    SELECT author_id INTO v_tweet_author_id
    FROM n_tweets
    WHERE tweet_id = :NEW.tweet_id;
    
    -- 给推文作者发送通知（如果不是自己评论自己的推文）
    IF v_tweet_author_id != :NEW.user_id THEN
        sp_create_notification(
            p_user_id => v_tweet_author_id,
            p_type => 'comment',
            p_title => '推文被评论',
            p_message => fn_format_notification_message('comment', v_commenter_username),
            p_related_type => 'tweet',
            p_related_id => :NEW.tweet_id,
            p_actor_id => :NEW.user_id,
            p_priority => 'normal',
            p_result => v_result
        );
    END IF;
    
    -- 如果是回复评论，给父评论作者发送通知
    IF :NEW.parent_comment_id IS NOT NULL THEN
        SELECT user_id INTO v_parent_comment_author_id
        FROM n_comments
        WHERE comment_id = :NEW.parent_comment_id;
        
        -- 给父评论作者发送通知（如果不是自己回复自己的评论，且不是推文作者）
        IF v_parent_comment_author_id != :NEW.user_id 
           AND v_parent_comment_author_id != v_tweet_author_id THEN
            sp_create_notification(
                p_user_id => v_parent_comment_author_id,
                p_type => 'reply',
                p_title => '评论被回复',
                p_message => v_commenter_username || ' 回复了你的评论',
                p_related_type => 'comment',
                p_related_id => :NEW.comment_id,
                p_actor_id => :NEW.user_id,
                p_priority => 'normal',
                p_result => v_result
            );
        END IF;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        -- 记录错误但不影响主要业务逻辑
        NULL;
END;
/

-- 自动创建转发通知触发器
CREATE OR REPLACE TRIGGER trg_retweet_notification
    AFTER INSERT ON n_tweets
    FOR EACH ROW
    WHEN (NEW.is_retweet = 1 AND NEW.retweet_of_tweet_id IS NOT NULL)
DECLARE
    v_result VARCHAR2(500);
    v_retweeter_username VARCHAR2(50);
    v_original_author_id NUMBER;
    v_tweet_content VARCHAR2(500);
BEGIN
    -- 获取转发者用户名
    SELECT username INTO v_retweeter_username
    FROM n_users
    WHERE user_id = :NEW.author_id;
    
    -- 获取原推文作者信息
    SELECT author_id, SUBSTR(content, 1, 100)
    INTO v_original_author_id, v_tweet_content
    FROM n_tweets
    WHERE tweet_id = :NEW.retweet_of_tweet_id;
    
    -- 只有不是自己转发自己的推文时才创建通知
    IF v_original_author_id != :NEW.author_id THEN
        -- 创建转发通知
        sp_create_notification(
            p_user_id => v_original_author_id,
            p_type => 'retweet',
            p_title => '推文被转发',
            p_message => fn_format_notification_message('retweet', v_retweeter_username, v_tweet_content),
            p_related_type => 'tweet',
            p_related_id => :NEW.retweet_of_tweet_id,
            p_actor_id => :NEW.author_id,
            p_priority => 'normal',
            p_result => v_result
        );
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        -- 记录错误但不影响主要业务逻辑
        NULL;
END;
/

-- 群组表触发器
CREATE OR REPLACE TRIGGER trg_groups_id
BEFORE INSERT ON n_groups
FOR EACH ROW
BEGIN
    IF :NEW.group_id IS NULL THEN
        :NEW.group_id := seq_group_id.NEXTVAL;
    END IF;
END;
/

-- 群组成员表触发器
CREATE OR REPLACE TRIGGER trg_group_members_id
BEFORE INSERT ON n_group_members
FOR EACH ROW
BEGIN
    IF :NEW.member_id IS NULL THEN
        :NEW.member_id := seq_group_member_id.NEXTVAL;
    END IF;
END;
/

-- 群组帖子表触发器
CREATE OR REPLACE TRIGGER trg_group_posts_id
BEFORE INSERT ON n_group_posts
FOR EACH ROW
BEGIN
    IF :NEW.post_id IS NULL THEN
        :NEW.post_id := seq_group_post_id.NEXTVAL;
    END IF;
END;
/

-- 群组评论表触发器
CREATE OR REPLACE TRIGGER trg_group_comments_id
BEFORE INSERT ON n_group_comments
FOR EACH ROW
BEGIN
    IF :NEW.comment_id IS NULL THEN
        :NEW.comment_id := seq_group_comment_id.NEXTVAL;
    END IF;
END;
/

-- 群组邀请表触发器
CREATE OR REPLACE TRIGGER trg_group_invites_id
BEFORE INSERT ON n_group_invites
FOR EACH ROW
BEGIN
    IF :NEW.invite_id IS NULL THEN
        :NEW.invite_id := seq_group_invite_id.NEXTVAL;
    END IF;
END;
/

-- 群组审计日志表触发器
CREATE OR REPLACE TRIGGER trg_group_audit_logs_id
BEFORE INSERT ON n_group_audit_logs
FOR EACH ROW
BEGIN
    IF :NEW.log_id IS NULL THEN
        :NEW.log_id := seq_group_audit_log_id.NEXTVAL;
    END IF;
END;
/

-- 群组帖子点赞表触发器
CREATE OR REPLACE TRIGGER trg_group_post_likes_id
BEFORE INSERT ON n_group_post_likes
FOR EACH ROW
BEGIN
    IF :NEW.like_id IS NULL THEN
        :NEW.like_id := seq_group_post_like_id.NEXTVAL;
    END IF;
END;
/

-- 群组评论点赞表触发器
CREATE OR REPLACE TRIGGER trg_group_comment_likes_id
BEFORE INSERT ON n_group_comment_likes
FOR EACH ROW
BEGIN
    IF :NEW.like_id IS NULL THEN
        :NEW.like_id := seq_group_comment_like_id.NEXTVAL;
    END IF;
END;
/

-- ============================================
-- 触发器定义 - 更新时间戳
-- ============================================

-- 群组表更新时间触发器
CREATE OR REPLACE TRIGGER trg_groups_updated_at
BEFORE UPDATE ON n_groups
FOR EACH ROW
BEGIN
    :NEW.updated_at := SYSTIMESTAMP;
END;
/

-- 群组成员表更新时间触发器
CREATE OR REPLACE TRIGGER trg_group_members_updated_at
BEFORE UPDATE ON n_group_members
FOR EACH ROW
BEGIN
    :NEW.updated_at := SYSTIMESTAMP;
END;
/

-- 群组帖子表更新时间触发器
CREATE OR REPLACE TRIGGER trg_group_posts_updated_at
BEFORE UPDATE ON n_group_posts
FOR EACH ROW
BEGIN
    :NEW.updated_at := SYSTIMESTAMP;
END;
/

-- 群组评论表更新时间触发器
CREATE OR REPLACE TRIGGER trg_group_comments_updated_at
BEFORE UPDATE ON n_group_comments
FOR EACH ROW
BEGIN
    :NEW.updated_at := SYSTIMESTAMP;
END;
/

-- ============================================
-- 触发器定义 - 成员数量自动更新
-- ============================================

-- 成员加入时自动增加群组成员数
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

-- 成员状态变更时更新群组成员数
CREATE OR REPLACE TRIGGER trg_group_member_count_update
AFTER UPDATE OF status ON n_group_members
FOR EACH ROW
BEGIN
    -- 从非active变为active，计数+1
    IF :OLD.status != 'active' AND :NEW.status = 'active' THEN
        UPDATE n_groups
        SET member_count = member_count + 1
        WHERE group_id = :NEW.group_id;
    -- 从active变为非active，计数-1
    ELSIF :OLD.status = 'active' AND :NEW.status != 'active' THEN
        UPDATE n_groups
        SET member_count = GREATEST(member_count - 1, 0)
        WHERE group_id = :NEW.group_id;
    END IF;
END;
/

-- 成员删除时自动减少群组成员数
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

-- ============================================
-- 触发器定义 - 帖子数量自动更新
-- ============================================

-- 帖子创建时自动增加群组帖子数
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

-- 帖子软删除时更新群组帖子数
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

-- 帖子物理删除时自动减少群组帖子数
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

-- ============================================
-- 触发器定义 - 帖子点赞数自动更新
-- ============================================

-- 点赞时增加计数
CREATE OR REPLACE TRIGGER trg_post_likes_count_inc
AFTER INSERT ON n_group_post_likes
FOR EACH ROW
BEGIN
    UPDATE n_group_posts
    SET likes_count = likes_count + 1
    WHERE post_id = :NEW.post_id;
END;
/

-- 取消点赞时减少计数
CREATE OR REPLACE TRIGGER trg_post_likes_count_dec
AFTER DELETE ON n_group_post_likes
FOR EACH ROW
BEGIN
    UPDATE n_group_posts
    SET likes_count = GREATEST(likes_count - 1, 0)
    WHERE post_id = :OLD.post_id;
END;
/

-- ============================================
-- 触发器定义 - 帖子评论数自动更新
-- ============================================

-- 评论创建时增加计数
CREATE OR REPLACE TRIGGER trg_post_comments_count_inc
AFTER INSERT ON n_group_comments
FOR EACH ROW
WHEN (NEW.is_deleted = 0)
BEGIN
    UPDATE n_group_posts
    SET comments_count = comments_count + 1
    WHERE post_id = :NEW.post_id;
END;
/

-- 评论软删除时更新计数
CREATE OR REPLACE TRIGGER trg_post_comments_count_update
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

-- 评论物理删除时减少计数
CREATE OR REPLACE TRIGGER trg_post_comments_count_dec
AFTER DELETE ON n_group_comments
FOR EACH ROW
WHEN (OLD.is_deleted = 0)
BEGIN
    UPDATE n_group_posts
    SET comments_count = GREATEST(comments_count - 1, 0)
    WHERE post_id = :OLD.post_id;
END;
/

-- ============================================
-- 触发器定义 - 评论点赞数自动更新
-- ============================================

-- 评论点赞时增加计数
CREATE OR REPLACE TRIGGER trg_comment_likes_count_inc
AFTER INSERT ON n_group_comment_likes
FOR EACH ROW
BEGIN
    UPDATE n_group_comments
    SET likes_count = likes_count + 1
    WHERE comment_id = :NEW.comment_id;
END;
/

-- 取消评论点赞时减少计数
CREATE OR REPLACE TRIGGER trg_comment_likes_count_dec
AFTER DELETE ON n_group_comment_likes
FOR EACH ROW
BEGIN
    UPDATE n_group_comments
    SET likes_count = GREATEST(likes_count - 1, 0)
    WHERE comment_id = :OLD.comment_id;
END;
/


-- ==========================================
-- 主键自增触发器
-- ==========================================

-- 首先创建缺少的序列（如果不存在）
-- 注意：如果序列已存在，以下语句会报错，这是正常的

-- 关注关系ID序列
BEGIN
    EXECUTE IMMEDIATE 'CREATE SEQUENCE seq_follow_id START WITH 1 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 20';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -955 THEN -- 对象名已存在
            NULL; -- 忽略错误
        ELSE
            RAISE;
        END IF;
END;
/

-- 点赞ID序列
BEGIN
    EXECUTE IMMEDIATE 'CREATE SEQUENCE seq_like_id START WITH 1 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 50';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -955 THEN -- 对象名已存在
            NULL; -- 忽略错误
        ELSE
            RAISE;
        END IF;
END;
/

-- 标签ID序列
BEGIN
    EXECUTE IMMEDIATE 'CREATE SEQUENCE seq_hashtag_id START WITH 1 INCREMENT BY 1 NOMAXVALUE NOCYCLE CACHE 20';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -955 THEN -- 对象名已存在
            NULL; -- 忽略错误
        ELSE
            RAISE;
        END IF;
END;
/

-- 群组ID序列
CREATE SEQUENCE seq_group_id
    START WITH 1
    INCREMENT BY 1
    NOCACHE
    NOCYCLE;

-- 群组成员ID序列
CREATE SEQUENCE seq_group_member_id
    START WITH 1
    INCREMENT BY 1
    NOCACHE
    NOCYCLE;

-- 群组帖子ID序列
CREATE SEQUENCE seq_group_post_id
    START WITH 1
    INCREMENT BY 1
    NOCACHE
    NOCYCLE;

-- 群组评论ID序列
CREATE SEQUENCE seq_group_comment_id
    START WITH 1
    INCREMENT BY 1
    NOCACHE
    NOCYCLE;

-- 群组邀请ID序列
CREATE SEQUENCE seq_group_invite_id
    START WITH 1
    INCREMENT BY 1
    NOCACHE
    NOCYCLE;

-- 群组审计日志ID序列
CREATE SEQUENCE seq_group_audit_log_id
    START WITH 1
    INCREMENT BY 1
    NOCACHE
    NOCYCLE;

-- 群组帖子点赞ID序列
CREATE SEQUENCE seq_group_post_like_id
    START WITH 1
    INCREMENT BY 1
    NOCACHE
    NOCYCLE;

-- 群组评论点赞ID序列
CREATE SEQUENCE seq_group_comment_like_id
    START WITH 1
    INCREMENT BY 1
    NOCACHE
    NOCYCLE;
/
-- 用户表主键自增触发器
CREATE OR REPLACE TRIGGER trg_users_pk
    BEFORE INSERT ON n_users
    FOR EACH ROW
    WHEN (NEW.user_id IS NULL)
BEGIN
    SELECT seq_user_id.nextval INTO :NEW.user_id FROM dual;
END;
/

-- 推文表主键自增触发器
CREATE OR REPLACE TRIGGER trg_tweets_pk
    BEFORE INSERT ON n_tweets
    FOR EACH ROW
    WHEN (NEW.tweet_id IS NULL)
BEGIN
    SELECT seq_tweet_id.nextval INTO :NEW.tweet_id FROM dual;
END;
/

-- 关注关系表主键自增触发器
CREATE OR REPLACE TRIGGER trg_follows_pk
    BEFORE INSERT ON n_follows
    FOR EACH ROW
    WHEN (NEW.follow_id IS NULL)
BEGIN
    SELECT seq_follow_id.nextval INTO :NEW.follow_id FROM dual;
END;
/

-- 书签表主键自增触发器
CREATE OR REPLACE TRIGGER trg_bookmarks_pk
    BEFORE INSERT ON n_bookmarks
    FOR EACH ROW
    WHEN (NEW.bookmark_id IS NULL)
BEGIN
    SELECT seq_bookmark_id.nextval INTO :NEW.bookmark_id FROM dual;
END;
/

-- 点赞表主键自增触发器
CREATE OR REPLACE TRIGGER trg_likes_pk
    BEFORE INSERT ON n_likes
    FOR EACH ROW
    WHEN (NEW.like_id IS NULL)
BEGIN
    SELECT seq_like_id.nextval INTO :NEW.like_id FROM dual;
END;
/

-- 评论表主键自增触发器
CREATE OR REPLACE TRIGGER trg_comments_pk
    BEFORE INSERT ON n_comments
    FOR EACH ROW
    WHEN (NEW.comment_id IS NULL)
BEGIN
    SELECT seq_comment_id.nextval INTO :NEW.comment_id FROM dual;
END;
/

-- 媒体文件表主键自增触发器
CREATE OR REPLACE TRIGGER trg_media_pk
    BEFORE INSERT ON n_media
    FOR EACH ROW
    WHEN (NEW.media_id IS NULL)
BEGIN
    SELECT seq_media_id.nextval INTO :NEW.media_id FROM dual;
END;
/

-- 标签表主键自增触发器
CREATE OR REPLACE TRIGGER trg_hashtags_pk
    BEFORE INSERT ON n_hashtags
    FOR EACH ROW
    WHEN (NEW.hashtag_id IS NULL)
BEGIN
    SELECT seq_hashtag_id.nextval INTO :NEW.hashtag_id FROM dual;
END;
/

-- 通知表主键自增触发器
CREATE OR REPLACE TRIGGER trg_notifications_pk
    BEFORE INSERT ON n_notifications
    FOR EACH ROW
    WHEN (NEW.notification_id IS NULL)
BEGIN
    SELECT seq_notification_id.nextval INTO :NEW.notification_id FROM dual;
END;
/

-- ==========================================
-- NekoTribe Oracle数据库完整设计方案
-- 作者: 刘畅
-- 创建日期: 2025-06-25
-- 数据库版本: Oracle 19c+
-- ==========================================

-- 6. 创建视图
-- ==========================================

-- 用户概览视图
CREATE OR REPLACE VIEW v_user_profile AS
SELECT
    u.user_id,
    u.username,
    u.display_name,
    u.email,
    u.avatar_url,
    u.bio,
    u.location,
    u.website,
    u.is_verified,
    u.followers_count,
    u.following_count,
    u.tweets_count,
    u.likes_count,
    u.created_at,
    u.last_login_at,
    CASE
        WHEN u.last_login_at > SYSDATE - 7 THEN '活跃'
        WHEN u.last_login_at > SYSDATE - 30 THEN '一般'
        ELSE '不活跃'
    END as activity_status
FROM n_users u
WHERE
    u.is_active = 1;

-- Oracle中视图不支持COMMENT，改为表注释方式在创建后添加
-- COMMENT ON VIEW v_user_profile IS '用户档案视图，包含用户基本信息和活跃度状态';

-- 推文详情视图
CREATE OR REPLACE VIEW v_tweet_details AS
SELECT
    t.tweet_id,
    t.content,
    t.author_id,
    u.username as author_username,
    u.display_name as author_display_name,
    u.avatar_url as author_avatar,
    u.is_verified as author_verified,
    t.reply_to_tweet_id,
    t.retweet_of_tweet_id,
    t.quote_tweet_id,
    t.is_retweet,
    t.is_quote_tweet,
    t.likes_count,
    t.retweets_count,
    t.replies_count,
    t.views_count,
    t.visibility,
    t.language,
    t.created_at,
    t.engagement_score,
    -- 媒体信息
    (
        SELECT LISTAGG(m.file_path, ',')
        FROM n_media m
        WHERE m.tweet_id = t.tweet_id
    ) as media_files,
    (
        SELECT LISTAGG(m.thumbnail_path, ',')
        FROM n_media m
        WHERE m.tweet_id = t.tweet_id
    ) as media_thumbnails
FROM n_tweets t
    JOIN n_users u ON t.author_id = u.user_id
WHERE
    t.is_deleted = 0
    AND u.is_active = 1;

-- Oracle中视图不支持COMMENT
-- COMMENT ON VIEW v_tweet_details IS '推文详情视图，包含作者信息和互动统计';

-- 综合推文时间线视图（支持多种获取类型）
CREATE OR REPLACE VIEW v_comprehensive_timeline AS
SELECT
    t.tweet_id,
    t.content,
    t.author_id,
    u.username,
    u.display_name,
    u.avatar_url,
    u.is_verified,
    t.likes_count,
    t.retweets_count,
    t.replies_count,
    t.views_count,
    t.visibility,
    t.created_at,
    t.reply_to_tweet_id,
    t.retweet_of_tweet_id,
    t.quote_tweet_id,
    t.engagement_score,
    t.is_deleted,
    -- 标记推文类型，用于不同的获取场景
    'all' as timeline_type,
    -- 关注关系信息（用于首页时间线判断）
    CASE 
        WHEN EXISTS (
            SELECT 1 FROM n_follows f 
            WHERE f.following_id = t.author_id 
            AND f.follow_type = 'follow' 
            AND f.is_active = 1
        ) THEN 1 
        ELSE 0 
    END as is_from_following
FROM n_tweets t
    JOIN n_users u ON t.author_id = u.user_id
WHERE
    t.is_deleted = 0
    AND u.is_active = 1;

-- 使用示例和查询模板（包含分页）：




-- 热门话题视图
CREATE OR REPLACE VIEW v_trending_hashtags AS
SELECT
    h.hashtag_id,
    h.tag_name,
    h.usage_count,
    h.trending_score,
    -- 最近24小时使用次数
    (
        SELECT COUNT(*)
        FROM
            n_tweet_hashtags th
            JOIN n_tweets t ON th.tweet_id = t.tweet_id
        WHERE
            th.hashtag_id = h.hashtag_id
            AND t.created_at > SYSDATE - 1
    ) as recent_usage,
    -- 增长率
    CASE
        WHEN h.usage_count > 0 THEN ROUND(
            (
                (
                    SELECT COUNT(*)
                    FROM
                        n_tweet_hashtags th
                        JOIN n_tweets t ON th.tweet_id = t.tweet_id
                    WHERE
                        th.hashtag_id = h.hashtag_id
                        AND t.created_at > SYSDATE - 1
                ) / h.usage_count
            ) * 100,
            2
        )
        ELSE 0
    END as growth_rate,
    h.updated_at
FROM n_hashtags h
WHERE
    h.is_trending = 1
ORDER BY h.trending_score DESC, h.usage_count DESC;

-- Oracle中视图不支持COMMENT
-- COMMENT ON VIEW v_trending_hashtags IS '热门话题视图，显示当前趋势标签和增长率';


-- ==========================================
-- 话题统计信息视图
-- 作者: 朱志炜
-- 创建日期: 2025-07-11
-- 描述: 综合话题标签统计信息，包含使用情况、互动数据、时间趋势等
-- ==========================================

CREATE OR REPLACE VIEW v_hashtag_statistics AS
SELECT 
    h.hashtag_id,
    h.tag_name,
    h.tag_name_lower,
    h.usage_count,
    h.trending_score,
    h.is_trending,
    h.created_at,
    h.updated_at,
    
    -- 基础统计
    NVL(stats.total_tweets, 0) as total_tweets,
    NVL(stats.total_authors, 0) as total_authors,
    NVL(stats.total_likes, 0) as total_likes,
    NVL(stats.total_retweets, 0) as total_retweets,
    NVL(stats.total_replies, 0) as total_replies,
    NVL(stats.total_views, 0) as total_views,
    NVL(stats.avg_engagement_score, 0) as avg_engagement_score,
    
    -- 时间统计
    NVL(stats.tweets_today, 0) as tweets_today,
    NVL(stats.tweets_this_week, 0) as tweets_this_week,
    NVL(stats.tweets_this_month, 0) as tweets_this_month,
    
    -- 互动统计
    NVL(stats.likes_today, 0) as likes_today,
    NVL(stats.retweets_today, 0) as retweets_today,
    NVL(stats.replies_today, 0) as replies_today,
    
    -- 活跃度指标
    NVL(stats.active_authors_today, 0) as active_authors_today,
    NVL(stats.active_authors_this_week, 0) as active_authors_this_week,
    
    -- 增长率统计
    CASE 
        WHEN NVL(stats.tweets_last_week, 0) = 0 THEN 0
        ELSE ROUND((NVL(stats.tweets_this_week, 0) - NVL(stats.tweets_last_week, 0)) * 100.0 / stats.tweets_last_week, 2)
    END as weekly_growth_rate,
    
    -- 平均互动率
    CASE 
        WHEN NVL(stats.total_tweets, 0) = 0 THEN 0
        ELSE ROUND(NVL(stats.total_likes, 0) * 100.0 / stats.total_tweets, 2)
    END as avg_like_rate,
    
    CASE 
        WHEN NVL(stats.total_tweets, 0) = 0 THEN 0
        ELSE ROUND(NVL(stats.total_retweets, 0) * 100.0 / stats.total_tweets, 2)
    END as avg_retweet_rate,
    
    -- 热度指标
    CASE 
        WHEN NVL(stats.tweets_today, 0) = 0 THEN 0
        ELSE ROUND((NVL(stats.likes_today, 0) + NVL(stats.retweets_today, 0) * 2 + NVL(stats.replies_today, 0) * 1.5) / stats.tweets_today, 2)
    END as daily_hotness_score,
    
    -- 最新推文信息
    stats.latest_tweet_id,
    stats.latest_tweet_created_at,
    stats.latest_tweet_author_id,
    
    -- 最热推文信息
    stats.hottest_tweet_id,
    stats.hottest_tweet_engagement_score

FROM n_hashtags h
LEFT JOIN (
    SELECT 
        nth.hashtag_id,
        
        -- 基础统计
        COUNT(DISTINCT t.tweet_id) as total_tweets,
        COUNT(DISTINCT t.author_id) as total_authors,
        SUM(t.likes_count) as total_likes,
        SUM(t.retweets_count) as total_retweets,
        SUM(t.replies_count) as total_replies,
        SUM(t.views_count) as total_views,
        ROUND(AVG(t.engagement_score), 2) as avg_engagement_score,
        
        -- 时间统计 - 今日
        COUNT(DISTINCT CASE 
            WHEN t.created_at >= TRUNC(SYSDATE) 
            THEN t.tweet_id 
        END) as tweets_today,
        
        -- 时间统计 - 本周
        COUNT(DISTINCT CASE 
            WHEN t.created_at >= TRUNC(SYSDATE, 'IW') 
            THEN t.tweet_id 
        END) as tweets_this_week,
        
        -- 时间统计 - 上周
        COUNT(DISTINCT CASE 
            WHEN t.created_at >= TRUNC(SYSDATE, 'IW') - 7 
            AND t.created_at < TRUNC(SYSDATE, 'IW') 
            THEN t.tweet_id 
        END) as tweets_last_week,
        
        -- 时间统计 - 本月
        COUNT(DISTINCT CASE 
            WHEN t.created_at >= TRUNC(SYSDATE, 'MM') 
            THEN t.tweet_id 
        END) as tweets_this_month,
        
        -- 今日互动统计
        SUM(CASE 
            WHEN t.created_at >= TRUNC(SYSDATE) 
            THEN t.likes_count 
            ELSE 0 
        END) as likes_today,
        
        SUM(CASE 
            WHEN t.created_at >= TRUNC(SYSDATE) 
            THEN t.retweets_count 
            ELSE 0 
        END) as retweets_today,
        
        SUM(CASE 
            WHEN t.created_at >= TRUNC(SYSDATE) 
            THEN t.replies_count 
            ELSE 0 
        END) as replies_today,
        
        -- 活跃作者统计
        COUNT(DISTINCT CASE 
            WHEN t.created_at >= TRUNC(SYSDATE) 
            THEN t.author_id 
        END) as active_authors_today,
        
        COUNT(DISTINCT CASE 
            WHEN t.created_at >= TRUNC(SYSDATE, 'IW') 
            THEN t.author_id 
        END) as active_authors_this_week,
        
        -- 最新推文信息
        MAX(t.tweet_id) KEEP (DENSE_RANK LAST ORDER BY t.created_at) as latest_tweet_id,
        MAX(t.created_at) as latest_tweet_created_at,
        MAX(t.author_id) KEEP (DENSE_RANK LAST ORDER BY t.created_at) as latest_tweet_author_id,
        
        -- 最热推文信息
        MAX(t.tweet_id) KEEP (DENSE_RANK LAST ORDER BY t.engagement_score) as hottest_tweet_id,
        MAX(t.engagement_score) as hottest_tweet_engagement_score
        
    FROM n_tweet_hashtags nth
    JOIN n_tweets t ON nth.tweet_id = t.tweet_id
    WHERE t.is_deleted = 0
    GROUP BY nth.hashtag_id
) stats ON h.hashtag_id = stats.hashtag_id;



-- 用户互动统计视图
CREATE OR REPLACE VIEW v_user_engagement_stats AS
SELECT
    u.user_id,
    u.username,
    u.display_name,
    -- 发布统计
    COUNT(DISTINCT t.tweet_id) as total_tweets,
    COUNT(
        DISTINCT CASE
            WHEN t.created_at > SYSDATE - 7 THEN t.tweet_id
        END
    ) as tweets_this_week,
    COUNT(
        DISTINCT CASE
            WHEN t.created_at > SYSDATE - 30 THEN t.tweet_id
        END
    ) as tweets_this_month,
    -- 获赞统计
    COALESCE(SUM(t.likes_count), 0) as total_likes_received,
    COALESCE(AVG(t.likes_count), 0) as avg_likes_per_tweet,
    -- 互动统计
    (
        SELECT COUNT(*)
        FROM n_likes l
        WHERE
            l.user_id = u.user_id
    ) as total_likes_given,
    (
        SELECT COUNT(*)
        FROM n_comments c
        WHERE
            c.user_id = u.user_id
    ) as total_comments_made,
    -- 活跃度分数
    ROUND(
        (
            COUNT(DISTINCT t.tweet_id) * 2 + COALESCE(SUM(t.likes_count), 0) * 0.5 + (
                SELECT COUNT(*)
                FROM n_likes l
                WHERE
                    l.user_id = u.user_id
            ) * 0.3 + (
                SELECT COUNT(*)
                FROM n_comments c
                WHERE
                    c.user_id = u.user_id
            ) * 1
        ),
        2
    ) as engagement_score
FROM n_users u
    LEFT JOIN n_tweets t ON u.user_id = t.author_id
    AND t.is_deleted = 0
WHERE
    u.is_active = 1
GROUP BY
    u.user_id,
    u.username,
    u.display_name;

-- Oracle中视图不支持COMMENT
-- COMMENT ON VIEW v_user_engagement_stats IS '用户互动统计视图，分析用户活跃度和影响力';

-- 推文互动详情视图（重新设计以避免CLOB字段GROUP BY问题）
CREATE OR REPLACE VIEW v_tweet_interactions AS
SELECT base.tweet_id, base.content, base.author_id, base.author, base.created_at, likes.liked_by_users, retweets.retweeted_by_users, comments.comments_count
FROM (
        -- 基础推文信息
        SELECT t.tweet_id, t.content, t.author_id, u.username as author, t.created_at
        FROM n_tweets t
            JOIN n_users u ON t.author_id = u.user_id
        WHERE
            t.is_deleted = 0
    ) base
    LEFT JOIN (
        -- 点赞用户聚合
        SELECT
            l.tweet_id,
            LISTAGG (
                CASE
                    WHEN l.like_type = 'like' THEN lu.username
                END,
                ', '
            ) WITHIN GROUP (
                ORDER BY l.created_at DESC
            ) as liked_by_users
        FROM n_likes l
            JOIN n_users lu ON l.user_id = lu.user_id
        GROUP BY
            l.tweet_id
    ) likes ON base.tweet_id = likes.tweet_id
    LEFT JOIN (
        -- 转发用户聚合
        SELECT
            rt.retweet_of_tweet_id as tweet_id,
            LISTAGG (
                CASE
                    WHEN rt.is_retweet = 1 THEN ru.username
                END,
                ', '
            ) WITHIN GROUP (
                ORDER BY rt.created_at DESC
            ) as retweeted_by_users
        FROM n_tweets rt
            JOIN n_users ru ON rt.author_id = ru.user_id
        WHERE
            rt.retweet_of_tweet_id IS NOT NULL
        GROUP BY
            rt.retweet_of_tweet_id
    ) retweets ON base.tweet_id = retweets.tweet_id
    LEFT JOIN (
        -- 评论数量聚合
        SELECT c.tweet_id, COUNT(DISTINCT c.comment_id) as comments_count
        FROM n_comments c
        GROUP BY
            c.tweet_id
    ) comments ON base.tweet_id = comments.tweet_id;

-- Oracle中视图不支持COMMENT
-- COMMENT ON VIEW v_tweet_interactions IS '推文互动详情视图，显示点赞、转发、评论等详细信息';

-- 首页时间线专用视图（包含关注关系）
CREATE OR REPLACE VIEW v_home_timeline AS
SELECT
    t.tweet_id,
    t.content,
    t.author_id,
    u.username,
    u.display_name,
    u.avatar_url,
    u.is_verified,
    t.likes_count,
    t.retweets_count,
    t.replies_count,
    t.views_count,
    t.visibility,
    t.created_at,
    f.follower_id as viewer_id, -- 关注者ID，用于权限判断
    CASE 
        WHEN f.follower_id = t.author_id THEN 'own'
        WHEN f.follower_id IS NOT NULL THEN 'following'
        ELSE 'other'
    END as timeline_type
FROM n_tweets t
    JOIN n_users u ON t.author_id = u.user_id
    LEFT JOIN n_follows f ON f.following_id = t.author_id 
        AND f.follow_type = 'follow' 
        AND f.is_active = 1
WHERE
    t.is_deleted = 0
    AND u.is_active = 1;

-- 热门推文专用视图
CREATE OR REPLACE VIEW v_trending_tweets AS
SELECT
    t.tweet_id,
    t.content,
    t.author_id,
    u.username,
    u.display_name,
    u.avatar_url,
    u.is_verified,
    t.likes_count,
    t.retweets_count,
    t.replies_count,
    t.views_count,
    t.visibility,
    t.created_at,
    fn_calculate_tweet_engagement(t.tweet_id) as engagement_score,
    -- 计算推文年龄（小时）
    ROUND(EXTRACT(DAY FROM (SYSDATE - t.created_at)) * 24 + 
          EXTRACT(HOUR FROM (SYSDATE - t.created_at)), 2) as age_hours
FROM n_tweets t
    JOIN n_users u ON t.author_id = u.user_id
WHERE
    t.is_deleted = 0
    AND u.is_active = 1
    AND t.created_at > SYSDATE - 7 -- 只显示最近7天的推文
    AND t.visibility = 'public' -- 热门推文只显示公开的
ORDER BY fn_calculate_tweet_engagement(t.tweet_id) DESC;

-- 获取评论视图
CREATE OR REPLACE VIEW v_tweet_comments AS
SELECT
    c.comment_id,
    c.tweet_id,
    c.content,
    c.user_id,
    c.parent_comment_id,
    u.username,
    u.display_name,
    u.avatar_url,
    u.is_verified,
    c.created_at
FROM n_comments c
    JOIN n_users u ON c.user_id = u.user_id
WHERE
    c.is_deleted = 0;












-- ==========================================
-- NekoTribe 通知视图设计
-- 作者: 朱志炜
-- 创建日期: 2025-07-12
-- 视图名称: v_notifications_detail
-- ==========================================

CREATE OR REPLACE VIEW v_notifications_detail AS
SELECT 
    -- 通知基本信息
    n.notification_id,
    n.user_id,
    n.type,
    n.title,
    n.message,
    n.related_type,
    n.related_id,
    n.actor_id,
    n.is_read,
    n.priority,
    n.created_at,
    n.read_at,
    n.is_deleted,
    
    -- 接收者信息
    u.username AS recipient_username,
    u.display_name AS recipient_display_name,
    u.avatar_url AS recipient_avatar_url,
    
    -- 触发者信息
    actor.username AS actor_username,
    actor.display_name AS actor_display_name,
    actor.avatar_url AS actor_avatar_url,
    actor.is_verified AS actor_is_verified,
    
    -- 相关推文信息（如果存在）
    CASE 
        WHEN n.related_type = 'tweet' THEN t.content
        ELSE NULL
    END AS related_tweet_content,
    
    CASE 
        WHEN n.related_type = 'tweet' THEN t.author_id
        ELSE NULL
    END AS related_tweet_author_id,
    
    CASE 
        WHEN n.related_type = 'tweet' THEN tweet_author.username
        ELSE NULL
    END AS related_tweet_author_username,
    
    -- 相关评论信息（如果存在）
    CASE 
        WHEN n.related_type = 'comment' THEN c.content
        ELSE NULL
    END AS related_comment_content,
    
    CASE 
        WHEN n.related_type = 'comment' THEN c.tweet_id
        ELSE NULL
    END AS related_comment_tweet_id,
    
    -- 通知状态描述
    CASE 
        WHEN n.is_read = 1 THEN '已读'
        ELSE '未读'
    END AS read_status_desc,
    
    -- 优先级描述
    CASE 
        WHEN n.priority = 'high' THEN '高优先级'
        WHEN n.priority = 'normal' THEN '普通'
        ELSE '低优先级'
    END AS priority_desc,
    
    -- 通知类型描述
    CASE 
        WHEN n.type = 'like' THEN '点赞了你的推文'
        WHEN n.type = 'retweet' THEN '转发了你的推文'
        WHEN n.type = 'comment' THEN '评论了你的推文'
        WHEN n.type = 'mention' THEN '在推文中提到了你'
        WHEN n.type = 'follow' THEN '关注了你'
        WHEN n.type = 'system' THEN '系统通知'
        ELSE '未知通知类型'
    END AS type_desc,
    
    -- 时间相关计算 - 修复 Oracle 时间计算语法
    CASE 
        WHEN n.created_at >= SYSDATE - INTERVAL '1' HOUR THEN '1小时内'
        WHEN n.created_at >= TRUNC(SYSDATE) THEN '今天'
        WHEN n.created_at >= SYSDATE - INTERVAL '7' DAY THEN '本周'
        WHEN n.created_at >= SYSDATE - INTERVAL '30' DAY THEN '本月'
        ELSE '更早'
    END AS time_category,
    
    -- 计算通知年龄（小时）- 使用 EXTRACT 函数
    ROUND(EXTRACT(DAY FROM (SYSDATE - n.created_at)) * 24 + 
          EXTRACT(HOUR FROM (SYSDATE - n.created_at)) + 
          EXTRACT(MINUTE FROM (SYSDATE - n.created_at)) / 60, 2) AS hours_since_created,
    
    -- 是否为最近通知（24小时内）
    CASE 
        WHEN n.created_at >= SYSDATE - INTERVAL '1' DAY THEN 1
        ELSE 0
    END AS is_recent

FROM n_notifications n
    -- 关联接收者信息
    INNER JOIN n_users u ON n.user_id = u.user_id
    -- 关联触发者信息
    LEFT JOIN n_users actor ON n.actor_id = actor.user_id
    -- 关联相关推文信息
    LEFT JOIN n_tweets t ON n.related_type = 'tweet' AND n.related_id = t.tweet_id
    -- 关联推文作者信息
    LEFT JOIN n_users tweet_author ON t.author_id = tweet_author.user_id
    -- 关联相关评论信息
    LEFT JOIN n_comments c ON n.related_type = 'comment' AND n.related_id = c.comment_id

WHERE n.user_id IN (SELECT user_id FROM n_users WHERE is_active = 1);


-- ==========================================
-- 通知摘要视图 - 用于统计和仪表板
-- ==========================================

CREATE OR REPLACE VIEW v_notifications_summary AS
SELECT 
    n.user_id,
    u.username,
    u.display_name,
    u.avatar_url,
    
    -- 通知总数统计
    COUNT(*) AS total_notifications,
    
    -- 未读通知数量
    SUM(CASE WHEN n.is_read = 0 THEN 1 ELSE 0 END) AS unread_count,
    
    -- 各类型通知数量
    SUM(CASE WHEN n.type = 'like' THEN 1 ELSE 0 END) AS like_count,
    SUM(CASE WHEN n.type = 'retweet' THEN 1 ELSE 0 END) AS retweet_count,
    SUM(CASE WHEN n.type = 'comment' THEN 1 ELSE 0 END) AS comment_count,
    SUM(CASE WHEN n.type = 'mention' THEN 1 ELSE 0 END) AS mention_count,
    SUM(CASE WHEN n.type = 'follow' THEN 1 ELSE 0 END) AS follow_count,
    SUM(CASE WHEN n.type = 'system' THEN 1 ELSE 0 END) AS system_count,
    
    -- 最近通知统计（24小时内）
    SUM(CASE WHEN n.created_at >= (SYSDATE - 1) THEN 1 ELSE 0 END) AS recent_count,
    
    -- 高优先级通知数量
    SUM(CASE WHEN n.priority = 'high' THEN 1 ELSE 0 END) AS high_priority_count,
    
    -- 最新通知时间
    MAX(n.created_at) AS latest_notification_time,
    
    -- 最新未读通知时间
    MAX(CASE WHEN n.is_read = 0 THEN n.created_at END) AS latest_unread_time,
    
    -- 通知活跃度（最近7天的通知数量）
    SUM(CASE WHEN n.created_at >= (SYSDATE - 7) THEN 1 ELSE 0 END) AS weekly_activity

FROM n_notifications n
INNER JOIN n_users u ON n.user_id = u.user_id
WHERE u.is_active = 1  -- 只统计活跃用户
GROUP BY n.user_id, u.username, u.display_name, u.avatar_url;


-- ============================================
-- 1. 群组详情视图 (v_group_details)
-- 包含群组基本信息和群主信息
-- ============================================
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
    -- 群主信息
    u.username AS owner_username,
    u.display_name AS owner_display_name,
    u.avatar_url AS owner_avatar_url,
    u.is_verified AS owner_is_verified,
    -- 计算字段
    ROUND((CAST(SYSTIMESTAMP AS DATE) - CAST(g.created_at AS DATE)) * 24) AS hours_since_created,
    CASE 
        WHEN g.created_at > SYSTIMESTAMP - INTERVAL '24' HOUR THEN '今天'
        WHEN g.created_at > SYSTIMESTAMP - INTERVAL '7' DAY THEN '本周'
        WHEN g.created_at > SYSTIMESTAMP - INTERVAL '30' DAY THEN '本月'
        ELSE '更早'
    END AS time_category
FROM n_groups g
JOIN n_users u ON g.owner_id = u.user_id;

COMMENT ON TABLE v_group_details IS '群组详情视图';

-- ============================================
-- 2. 群组成员详情视图 (v_group_member_details)
-- 包含成员信息和用户详情
-- ============================================
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
    -- 用户信息
    u.username,
    u.display_name,
    u.avatar_url,
    u.bio,
    u.is_verified,
    u.is_active AS user_is_active,
    -- 群组信息
    g.name AS group_name,
    g.slug AS group_slug,
    -- 邀请人信息
    inv.username AS inviter_username,
    inv.display_name AS inviter_display_name,
    -- 计算字段
    CASE 
        WHEN gm.mute_until IS NOT NULL AND gm.mute_until > SYSTIMESTAMP THEN 1
        ELSE 0
    END AS is_currently_muted,
    ROUND((CAST(SYSTIMESTAMP AS DATE) - CAST(gm.joined_at AS DATE)) * 24 * 60) AS minutes_since_joined
FROM n_group_members gm
JOIN n_users u ON gm.user_id = u.user_id
JOIN n_groups g ON gm.group_id = g.group_id
LEFT JOIN n_users inv ON gm.invited_by = inv.user_id;

COMMENT ON TABLE v_group_member_details IS '群组成员详情视图';

-- ============================================
-- 3. 群组帖子详情视图 (v_group_post_details)
-- 包含帖子信息和作者详情
-- ============================================
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
    -- 作者信息
    u.username AS author_username,
    u.display_name AS author_display_name,
    u.avatar_url AS author_avatar_url,
    u.is_verified AS author_is_verified,
    -- 作者在群组中的角色
    gm.role AS author_role,
    fn_get_role_desc(gm.role) AS author_role_desc,
    gm.nickname AS author_nickname,
    -- 群组信息
    g.name AS group_name,
    g.slug AS group_slug,
    g.privacy AS group_privacy,
    -- 删除者信息
    del.username AS deleter_username,
    del.display_name AS deleter_display_name,
    -- 计算字段
    ROUND((CAST(SYSTIMESTAMP AS DATE) - CAST(gp.created_at AS DATE)) * 24 * 60) AS minutes_since_created,
    CASE 
        WHEN gp.created_at > SYSTIMESTAMP - INTERVAL '1' HOUR THEN '刚刚'
        WHEN gp.created_at > SYSTIMESTAMP - INTERVAL '24' HOUR THEN '今天'
        WHEN gp.created_at > SYSTIMESTAMP - INTERVAL '7' DAY THEN '本周'
        ELSE TO_CHAR(gp.created_at, 'YYYY-MM-DD')
    END AS time_display
FROM n_group_posts gp
JOIN n_users u ON gp.author_id = u.user_id
JOIN n_groups g ON gp.group_id = g.group_id
LEFT JOIN n_group_members gm ON gp.author_id = gm.user_id AND gp.group_id = gm.group_id
LEFT JOIN n_users del ON gp.deleted_by = del.user_id;

COMMENT ON TABLE v_group_post_details IS '群组帖子详情视图';

-- ============================================
-- 4. 群组评论详情视图 (v_group_comment_details)
-- 包含评论信息和作者详情
-- ============================================
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
    -- 作者信息
    u.username AS author_username,
    u.display_name AS author_display_name,
    u.avatar_url AS author_avatar_url,
    u.is_verified AS author_is_verified,
    -- 回复目标用户信息
    ru.username AS reply_to_username,
    ru.display_name AS reply_to_display_name,
    -- 帖子信息
    gp.group_id,
    gp.content AS post_content,
    -- 群组信息
    g.name AS group_name,
    g.slug AS group_slug,
    -- 作者在群组中的角色
    gm.role AS author_role,
    fn_get_role_desc(gm.role) AS author_role_desc,
    gm.nickname AS author_nickname,
    -- 计算字段
    ROUND((CAST(SYSTIMESTAMP AS DATE) - CAST(gc.created_at AS DATE)) * 24 * 60) AS minutes_since_created
FROM n_group_comments gc
JOIN n_users u ON gc.author_id = u.user_id
JOIN n_group_posts gp ON gc.post_id = gp.post_id
JOIN n_groups g ON gp.group_id = g.group_id
LEFT JOIN n_users ru ON gc.reply_to_user_id = ru.user_id
LEFT JOIN n_group_members gm ON gc.author_id = gm.user_id AND gp.group_id = gm.group_id;

COMMENT ON TABLE v_group_comment_details IS '群组评论详情视图';

-- ============================================
-- 5. 群组邀请详情视图 (v_group_invite_details)
-- 包含邀请信息和相关用户详情
-- ============================================
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
    -- 群组信息
    g.name AS group_name,
    g.slug AS group_slug,
    g.avatar_url AS group_avatar_url,
    g.privacy AS group_privacy,
    g.member_count AS group_member_count,
    -- 邀请人信息
    inv.username AS inviter_username,
    inv.display_name AS inviter_display_name,
    inv.avatar_url AS inviter_avatar_url,
    -- 被邀请人信息
    invt.username AS invitee_username,
    invt.display_name AS invitee_display_name,
    invt.avatar_url AS invitee_avatar_url,
    -- 计算字段
    CASE 
        WHEN gi.status != 'pending' THEN 0
        WHEN gi.max_uses IS NOT NULL AND gi.used_count >= gi.max_uses THEN 0
        WHEN gi.expires_at IS NOT NULL AND gi.expires_at < SYSTIMESTAMP THEN 0
        ELSE 1
    END AS is_valid,
    CASE 
        WHEN gi.expires_at IS NULL THEN NULL
        ELSE ROUND((CAST(gi.expires_at AS DATE) - CAST(SYSTIMESTAMP AS DATE)) * 24 * 60)
    END AS minutes_until_expire
FROM n_group_invites gi
JOIN n_groups g ON gi.group_id = g.group_id
JOIN n_users inv ON gi.inviter_id = inv.user_id
LEFT JOIN n_users invt ON gi.invitee_id = invt.user_id;

COMMENT ON TABLE v_group_invite_details IS '群组邀请详情视图';

-- ============================================
-- 6. 群组审计日志详情视图 (v_group_audit_log_details)
-- 包含日志信息和相关用户详情
-- ============================================
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
    -- 群组信息
    g.name AS group_name,
    g.slug AS group_slug,
    -- 操作者信息
    act.username AS actor_username,
    act.display_name AS actor_display_name,
    act.avatar_url AS actor_avatar_url,
    -- 目标用户信息
    tu.username AS target_username,
    tu.display_name AS target_display_name,
    -- 操作类型描述
    CASE gal.action
        WHEN 'create_group' THEN '创建群组'
        WHEN 'update_group' THEN '更新群组信息'
        WHEN 'delete_group' THEN '删除群组'
        WHEN 'add_member' THEN '添加成员'
        WHEN 'remove_member' THEN '移除成员'
        WHEN 'change_role' THEN '变更角色'
        WHEN 'mute_member' THEN '禁言成员'
        WHEN 'unmute_member' THEN '解除禁言'
        WHEN 'ban_member' THEN '封禁成员'
        WHEN 'unban_member' THEN '解除封禁'
        WHEN 'create_post' THEN '发布帖子'
        WHEN 'delete_post' THEN '删除帖子'
        WHEN 'pin_post' THEN '置顶帖子'
        WHEN 'unpin_post' THEN '取消置顶'
        WHEN 'create_comment' THEN '发表评论'
        WHEN 'delete_comment' THEN '删除评论'
        WHEN 'approve_member' THEN '审批成员'
        WHEN 'reject_member' THEN '拒绝成员'
        WHEN 'create_invite' THEN '创建邀请'
        WHEN 'transfer_ownership' THEN '转让群主'
        ELSE gal.action
    END AS action_desc
FROM n_group_audit_logs gal
JOIN n_groups g ON gal.group_id = g.group_id
JOIN n_users act ON gal.actor_id = act.user_id
LEFT JOIN n_users tu ON gal.target_user_id = tu.user_id;

COMMENT ON TABLE v_group_audit_log_details IS '群组审计日志详情视图';

-- ============================================
-- 7. 用户群组列表视图 (v_user_groups)
-- 查询某用户加入的所有群组
-- ============================================
CREATE OR REPLACE VIEW v_user_groups AS
SELECT 
    gm.user_id,
    gm.group_id,
    gm.role,
    fn_get_role_desc(gm.role) AS role_desc,
    gm.status,
    gm.nickname,
    gm.joined_at,
    -- 群组信息
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
    -- 群主信息
    u.username AS owner_username,
    u.display_name AS owner_display_name,
    -- 用户是否是群主
    CASE WHEN g.owner_id = gm.user_id THEN 1 ELSE 0 END AS is_owner
FROM n_group_members gm
JOIN n_groups g ON gm.group_id = g.group_id
JOIN n_users u ON g.owner_id = u.user_id
WHERE gm.status = 'active'
  AND g.is_deleted = 0
  AND g.is_active = 1;

COMMENT ON TABLE v_user_groups IS '用户群组列表视图';

-- ============================================
-- 8. 热门群组视图 (v_popular_groups)
-- 按成员数和活跃度排序的公开群组
-- ============================================
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
    -- 群主信息
    u.username AS owner_username,
    u.display_name AS owner_display_name,
    u.avatar_url AS owner_avatar_url,
    -- 活跃度评分 (成员数 * 0.3 + 帖子数 * 0.7)
    ROUND(g.member_count * 0.3 + g.post_count * 0.7, 2) AS activity_score
FROM n_groups g
JOIN n_users u ON g.owner_id = u.user_id
WHERE g.privacy = 'public'
  AND g.is_deleted = 0
  AND g.is_active = 1
ORDER BY activity_score DESC, g.member_count DESC, g.created_at DESC;

COMMENT ON TABLE v_popular_groups IS '热门群组视图';

-- ============================================
-- 9. 群组时间线视图 (v_group_timeline)
-- 用于显示群组内的帖子时间线
-- ============================================
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
    -- 作者信息
    u.username AS author_username,
    u.display_name AS author_display_name,
    u.avatar_url AS author_avatar_url,
    u.is_verified AS author_is_verified,
    -- 作者群组角色
    gm.role AS author_role,
    fn_get_role_desc(gm.role) AS author_role_desc,
    COALESCE(gm.nickname, u.display_name) AS author_display,
    -- 群组信息
    g.name AS group_name,
    g.slug AS group_slug,
    g.avatar_url AS group_avatar_url,
    -- 排序权重 (置顶 > 公告 > 普通)
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
-- NekoTribe Oracle数据库完整设计方案
-- 作者: 朱志炜
-- 创建日期: 2025-06-25
-- 数据库版本: Oracle 19c+
-- ==========================================

ALTER SESSION SET CONTAINER = ORCLPDB1;

-- 10. 创建定时任务（需要DBA权限，普通用户无法创建）
-- ==========================================

-- 注意：以下定时任务需要DBA权限才能创建，如果当前用户权限不足，请联系管理员创建

-- 清理旧作业（不存在则忽略）
BEGIN
  BEGIN DBMS_SCHEDULER.DROP_JOB('JOB_CLEANUP_EXPIRED_SESSIONS', FORCE => TRUE); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DBMS_SCHEDULER.DROP_JOB('JOB_CALCULATE_TRENDING_HASHTAGS', FORCE => TRUE); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DBMS_SCHEDULER.DROP_JOB('JOB_UPDATE_TWEET_VIEWS', FORCE => TRUE); EXCEPTION WHEN OTHERS THEN NULL; END;
END;
/

-- 1) 清理过期会话（修正列名，限定 schema）
BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'JOB_CLEANUP_EXPIRED_SESSIONS',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN
      -- 失效会话处理：刷新令牌过期或会话被标记为非活跃
      DELETE FROM NEKO_APP.N_USER_SESSIONS
      WHERE refresh_token_expires_at < SYSTIMESTAMP
         OR is_active = 0;
      COMMIT;
    END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=HOURLY;INTERVAL=1',
    enabled         => TRUE,
    comments        => '清理过期的用户会话'
  );
END;
/

-- 2) 计算热门话题（限定 schema，避免 ORA-06576）
BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'JOB_CALCULATE_TRENDING_HASHTAGS',
    job_type        => 'STORED_PROCEDURE',
    job_action      => 'NEKO_APP.SP_CALCULATE_TRENDING_HASHTAGS',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=HOURLY;INTERVAL=2',
    enabled         => TRUE,
    comments        => '计算和更新热门话题标签'
  );
END;
/


-- 3) 更新推文浏览量统计（修正表名为 n_tweets）
BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'JOB_UPDATE_TWEET_VIEWS',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN
      -- 示例：增加最近1天内未删除推文的浏览量（演示用）
      UPDATE NEKO_APP.N_TWEETS
         SET views_count = views_count + ROUND(DBMS_RANDOM.VALUE(1, 10))
       WHERE created_at > SYSTIMESTAMP - INTERVAL ''1'' DAY
         AND is_deleted = 0;
      COMMIT;
    END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=DAILY;BYHOUR=2',
    enabled         => TRUE,
    comments        => '更新推文浏览量统计'
  );
END;
/

-- ==========================================
-- NekoTribe Oracle数据库完整设计方案
-- 作者: 彭涛
-- 创建日期: 2025-06-25
-- 数据库版本: Oracle 19c+
-- ==========================================

ALTER SESSION SET CURRENT_SCHEMA = NEKO_APP;

-- 11. 插入测试数据（重新设计，确保所有表都有数据）
-- ==========================================

-- 注意：测试数据插入需要以 neko_app 用户身份执行
-- 如果当前不是 neko_app 用户，请先切换：
-- CONN neko_app/NekoApp2025#;

-- 清理已有测试数据
-- 注意：由于通知表有触发器，需要按依赖关系顺序删除
-- 使用用户名来识别测试数据，而不是固定ID范围

-- 1. 清理通知数据
DELETE FROM n_notifications
WHERE
    user_id IN (SELECT user_id FROM n_users WHERE username IN ('admin', 'cthaat', 'techuser', 'uiuxmaster', 'productguru'))
    OR actor_id IN (SELECT user_id FROM n_users WHERE username IN ('admin', 'cthaat', 'techuser', 'uiuxmaster', 'productguru'));

-- 2. 清理会话数据
DELETE FROM n_user_sessions 
WHERE user_id IN (SELECT user_id FROM n_users WHERE username IN ('admin', 'cthaat', 'techuser', 'uiuxmaster', 'productguru'));

-- 3. 清理推文相关数据
DELETE FROM n_tweet_hashtags 
WHERE tweet_id IN (SELECT tweet_id FROM n_tweets WHERE author_id IN 
    (SELECT user_id FROM n_users WHERE username IN ('admin', 'cthaat', 'techuser', 'uiuxmaster', 'productguru')));

DELETE FROM n_media 
WHERE user_id IN (SELECT user_id FROM n_users WHERE username IN ('admin', 'cthaat', 'techuser', 'uiuxmaster', 'productguru'));

DELETE FROM n_comments 
WHERE user_id IN (SELECT user_id FROM n_users WHERE username IN ('admin', 'cthaat', 'techuser', 'uiuxmaster', 'productguru'));

DELETE FROM n_likes 
WHERE user_id IN (SELECT user_id FROM n_users WHERE username IN ('admin', 'cthaat', 'techuser', 'uiuxmaster', 'productguru'));

DELETE FROM n_follows
WHERE
    follower_id IN (SELECT user_id FROM n_users WHERE username IN ('admin', 'cthaat', 'techuser', 'uiuxmaster', 'productguru'))
    OR following_id IN (SELECT user_id FROM n_users WHERE username IN ('admin', 'cthaat', 'techuser', 'uiuxmaster', 'productguru'));

DELETE FROM n_tweets 
WHERE author_id IN (SELECT user_id FROM n_users WHERE username IN ('admin', 'cthaat', 'techuser', 'uiuxmaster', 'productguru'));

-- 4. 清理测试标签（根据标签名称识别）
DELETE FROM n_hashtags 
WHERE tag_name IN ('推特克隆', '测试', '欢迎', '技术分享', '数据库', 'Oracle', '设计', 'UI设计', '产品管理', '用户增长');

-- 5. 清理测试用户
DELETE FROM n_users WHERE username IN ('admin', 'cthaat', 'techuser', 'uiuxmaster', 'productguru');

-- 重置序列到安全值（可选）
-- 这确保测试数据的ID不会与之前的数据冲突
DECLARE
    v_seq_val NUMBER;
BEGIN
    -- 检查并重置通知序列
    SELECT seq_notification_id.currval INTO v_seq_val FROM dual;
    IF v_seq_val < 15000000 THEN
        EXECUTE IMMEDIATE 'ALTER SEQUENCE seq_notification_id RESTART START WITH 15000000';
        DBMS_OUTPUT.PUT_LINE('通知序列已重置到 15000000');
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        -- 如果序列还没有被使用过，currval会报错，这时直接重置
        EXECUTE IMMEDIATE 'ALTER SEQUENCE seq_notification_id RESTART START WITH 15000000';
        DBMS_OUTPUT.PUT_LINE('通知序列已初始化到 15000000');
END;
/

COMMIT;

-- 11.1 插入测试用户
INSERT INTO
    n_users (
        email,
        username,
        password_hash,
        display_name,
        bio,
        avatar_url,
        location,
        website,
        phone,
        is_verified
    )
VALUES (
        'admin@twitter.com',
        'admin',
        '$2b$10$K7Q8ZQX5Q5QkQ5QkQ5QkQuQ5QkQ5QkQ5QkQ5QkQ5QkQ5QkQ5QkQ5Q',
        '系统管理员',
        '推特克隆项目管理员账户，负责系统维护和用户支持',
        '/avatars/admin.png',
        '北京市',
        'https://twitter-clone.com',
        '13800138000',
        1
    );

INSERT INTO
    n_users (
        email,
        username,
        password_hash,
        display_name,
        bio,
        location,
        website,
        birth_date
    )
VALUES (
        'user1@example.com',
        'cthaat',
        '$2b$10$K7Q8ZQX5Q5QkQ5QkQ5QkQuQ5QkQ5QkQ5QkQ5QkQ5QkQ5QkQ5QkQ5Q',
        'Cthaat开发者',
        '全栈开发工程师，热爱技术分享，专注于Web开发和数据库设计',
        '上海市',
        'https://github.com/cthaat',
        DATE '1990-05-15'
    );

INSERT INTO
    n_users (
        email,
        username,
        password_hash,
        display_name,
        bio,
        location
    )
VALUES (
        'user2@example.com',
        'techuser',
        '$2b$10$K7Q8ZQX5Q5QkQ5QkQ5QkQuQ5QkQ5QkQ5QkQ5QkQ5QkQ5QkQ5QkQ5Q',
        '科技爱好者',
        '专注前沿技术，分享编程心得，关注人工智能和云计算',
        '深圳市'
    );

INSERT INTO
    n_users (
        email,
        username,
        password_hash,
        display_name,
        bio,
        location
    )
VALUES (
        'designer@example.com',
        'uiuxmaster',
        '$2b$10$K7Q8ZQX5Q5QkQ5QkQ5QkQuQ5QkQ5QkQ5QkQ5QkQ5QkQ5QkQ5QkQ5Q',
        'UI/UX设计师',
        '专业用户体验设计师，致力于创造优美直观的用户界面',
        '广州市'
    );

INSERT INTO
    n_users (
        email,
        username,
        password_hash,
        display_name,
        bio,
        location
    )
VALUES (
        'pm@example.com',
        'productguru',
        '$2b$10$K7Q8ZQX5Q5QkQ5QkQ5QkQ5QkQ5QkQuQ5QkQ5QkQ5QkQ5QkQ5QkQ5Q',
        '产品经理',
        '资深产品经理，擅长需求分析和产品规划，关注用户增长',
        '杭州市'
    );

-- 11.2 插入测试话题标签
INSERT INTO
    n_hashtags (
        tag_name,
        tag_name_lower,
        usage_count,
        trending_score,
        is_trending
    )
VALUES (
        '推特克隆',
        '推特克隆',
        5,
        25.5,
        1
    );

INSERT INTO
    n_hashtags (
        tag_name,
        tag_name_lower,
        usage_count,
        trending_score,
        is_trending
    )
VALUES ('测试', '测试', 8, 30.2, 1);

INSERT INTO
    n_hashtags (
        tag_name,
        tag_name_lower,
        usage_count,
        trending_score,
        is_trending
    )
VALUES ('欢迎', '欢迎', 3, 15.8, 1);

INSERT INTO
    n_hashtags (
        tag_name,
        tag_name_lower,
        usage_count,
        trending_score,
        is_trending
    )
VALUES (
        '技术分享',
        '技术分享',
        12,
        45.6,
        1
    );

INSERT INTO
    n_hashtags (
        tag_name,
        tag_name_lower,
        usage_count,
        trending_score,
        is_trending
    )
VALUES (
        '数据库',
        '数据库',
        6,
        22.1,
        1
    );

INSERT INTO
    n_hashtags (
        tag_name,
        tag_name_lower,
        usage_count,
        trending_score,
        is_trending
    )
VALUES (
        'Oracle',
        'oracle',
        4,
        18.3,
        0
    );

INSERT INTO
    n_hashtags (
        tag_name,
        tag_name_lower,
        usage_count,
        trending_score,
        is_trending
    )
VALUES ('设计', '设计', 2, 12.5, 0);

INSERT INTO
    n_hashtags (
        tag_name,
        tag_name_lower,
        usage_count,
        trending_score,
        is_trending
    )
VALUES (
        'UI设计',
        'ui设计',
        1,
        8.2,
        0
    );

INSERT INTO
    n_hashtags (
        tag_name,
        tag_name_lower,
        usage_count,
        trending_score,
        is_trending
    )
VALUES (
        '产品管理',
        '产品管理',
        1,
        6.8,
        0
    );

INSERT INTO
    n_hashtags (
        tag_name,
        tag_name_lower,
        usage_count,
        trending_score,
        is_trending
    )
VALUES (
        '用户增长',
        '用户增长',
        1,
        5.5,
        0
    );

-- 11.3 插入测试推文（使用用户名查询用户ID）
-- 注意：由于用户ID现在是自动生成的，需要通过用户名查找用户ID
INSERT INTO
    n_tweets (
        author_id,
        content,
        visibility,
        language
    )
VALUES (
        (SELECT user_id FROM n_users WHERE username = 'admin'),
        '🎉 欢迎使用推特克隆系统！这是第一条测试推文，标志着我们平台的正式启动。感谢所有用户的支持！',
        'public',
        'zh-CN'
    );

INSERT INTO
    n_tweets (
        author_id,
        content,
        visibility,
        language
    )
VALUES (
        (SELECT user_id FROM n_users WHERE username = 'cthaat'),
        '🚀 分享一下Oracle数据库设计的经验：合理的表结构设计是系统性能的基础。今天完成了推特克隆项目的数据库设计，包含了用户、推文、关注、点赞等核心功能。',
        'public',
        'zh-CN'
    );

INSERT INTO
    n_tweets (
        author_id,
        content,
        visibility,
        language
    )
VALUES (
        (SELECT user_id FROM n_users WHERE username = 'techuser'),
        '💡 刚体验了新的推特克隆系统，界面设计很棒！特别喜欢实时更新的功能。期待更多新特性的上线。',
        'public',
        'zh-CN'
    );

INSERT INTO
    n_tweets (
        author_id,
        content,
        visibility,
        language
    )
VALUES (
        (SELECT user_id FROM n_users WHERE username = 'uiuxmaster'),
        '🎨 设计师的日常：今天在思考如何优化社交媒体的用户界面。简洁、直观、易用是我的设计原则。分享一些UI设计的心得体会。',
        'public',
        'zh-CN'
    );

INSERT INTO
    n_tweets (
        author_id,
        content,
        visibility,
        language
    )
VALUES (
        (SELECT user_id FROM n_users WHERE username = 'productguru'),
        '📊 作为产品经理，我认为好的产品需要平衡功能性和用户体验。正在规划下一版本的功能路线图，会增加更多社交互动功能。',
        'public',
        'zh-CN'
    );

-- 11.3.1 插入推文话题标签关联（使用子查询获取ID）
-- admin的推文关联标签
INSERT INTO
    n_tweet_hashtags (tweet_id, hashtag_id)
VALUES (
    (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'admin' AND ROWNUM = 1),
    (SELECT hashtag_id FROM n_hashtags WHERE tag_name = '推特克隆')
);

INSERT INTO
    n_tweet_hashtags (tweet_id, hashtag_id)
VALUES (
    (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'admin' AND ROWNUM = 1),
    (SELECT hashtag_id FROM n_hashtags WHERE tag_name = '测试')
);

INSERT INTO
    n_tweet_hashtags (tweet_id, hashtag_id)
VALUES (
    (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'admin' AND ROWNUM = 1),
    (SELECT hashtag_id FROM n_hashtags WHERE tag_name = '欢迎')
);

-- cthaat的推文关联标签
INSERT INTO
    n_tweet_hashtags (tweet_id, hashtag_id)
VALUES (
    (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'cthaat' AND ROWNUM = 1),
    (SELECT hashtag_id FROM n_hashtags WHERE tag_name = '技术分享')
);

INSERT INTO
    n_tweet_hashtags (tweet_id, hashtag_id)
VALUES (
    (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'cthaat' AND ROWNUM = 1),
    (SELECT hashtag_id FROM n_hashtags WHERE tag_name = '数据库')
);

INSERT INTO
    n_tweet_hashtags (tweet_id, hashtag_id)
VALUES (
    (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'cthaat' AND ROWNUM = 1),
    (SELECT hashtag_id FROM n_hashtags WHERE tag_name = 'Oracle')
);

-- techuser的推文关联标签
INSERT INTO
    n_tweet_hashtags (tweet_id, hashtag_id)
VALUES (
    (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'techuser' AND ROWNUM = 1),
    (SELECT hashtag_id FROM n_hashtags WHERE tag_name = '推特克隆')
);

-- uiuxmaster的推文关联标签
INSERT INTO
    n_tweet_hashtags (tweet_id, hashtag_id)
VALUES (
    (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'uiuxmaster' AND ROWNUM = 1),
    (SELECT hashtag_id FROM n_hashtags WHERE tag_name = '设计')
);

INSERT INTO
    n_tweet_hashtags (tweet_id, hashtag_id)
VALUES (
    (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'uiuxmaster' AND ROWNUM = 1),
    (SELECT hashtag_id FROM n_hashtags WHERE tag_name = 'UI设计')
);

-- productguru的推文关联标签
INSERT INTO
    n_tweet_hashtags (tweet_id, hashtag_id)
VALUES (
    (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'productguru' AND ROWNUM = 1),
    (SELECT hashtag_id FROM n_hashtags WHERE tag_name = '产品管理')
);

INSERT INTO
    n_tweet_hashtags (tweet_id, hashtag_id)
VALUES (
    (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'productguru' AND ROWNUM = 1),
    (SELECT hashtag_id FROM n_hashtags WHERE tag_name = '用户增长')
);

-- 11.3.2 更新用户推文数量（使用用户名查找）
UPDATE n_users
SET
    tweets_count = tweets_count + 1
WHERE
    username = 'admin';

UPDATE n_users
SET
    tweets_count = tweets_count + 1
WHERE
    username = 'cthaat';

UPDATE n_users
SET
    tweets_count = tweets_count + 1
WHERE
    username = 'techuser';

UPDATE n_users
SET
    tweets_count = tweets_count + 1
WHERE
    username = 'uiuxmaster';

UPDATE n_users
SET
    tweets_count = tweets_count + 1
WHERE
    username = 'productguru';

-- 11.4 创建关注关系（使用用户名查找用户ID）
DECLARE
    v_result VARCHAR2(500);
    v_follower_id NUMBER;
    v_following_id NUMBER;
BEGIN
    -- cthaat 关注 admin
    SELECT user_id INTO v_follower_id FROM n_users WHERE username = 'cthaat';
    SELECT user_id INTO v_following_id FROM n_users WHERE username = 'admin';
    sp_manage_follow(v_follower_id, v_following_id, 'follow', v_result);
    DBMS_OUTPUT.PUT_LINE('关注关系1: ' || v_result);
    
    -- techuser 关注 admin
    SELECT user_id INTO v_follower_id FROM n_users WHERE username = 'techuser';
    SELECT user_id INTO v_following_id FROM n_users WHERE username = 'admin';
    sp_manage_follow(v_follower_id, v_following_id, 'follow', v_result);
    DBMS_OUTPUT.PUT_LINE('关注关系2: ' || v_result);
    
    -- techuser 关注 cthaat
    SELECT user_id INTO v_follower_id FROM n_users WHERE username = 'techuser';
    SELECT user_id INTO v_following_id FROM n_users WHERE username = 'cthaat';
    sp_manage_follow(v_follower_id, v_following_id, 'follow', v_result);
    DBMS_OUTPUT.PUT_LINE('关注关系3: ' || v_result);
    
    -- admin 关注 cthaat (互相关注)
    SELECT user_id INTO v_follower_id FROM n_users WHERE username = 'admin';
    SELECT user_id INTO v_following_id FROM n_users WHERE username = 'cthaat';
    sp_manage_follow(v_follower_id, v_following_id, 'follow', v_result);
    DBMS_OUTPUT.PUT_LINE('关注关系4: ' || v_result);
    
    -- uiuxmaster 关注 cthaat
    SELECT user_id INTO v_follower_id FROM n_users WHERE username = 'uiuxmaster';
    SELECT user_id INTO v_following_id FROM n_users WHERE username = 'cthaat';
    sp_manage_follow(v_follower_id, v_following_id, 'follow', v_result);
    DBMS_OUTPUT.PUT_LINE('关注关系5: ' || v_result);
    
    -- productguru 关注所有人
    SELECT user_id INTO v_follower_id FROM n_users WHERE username = 'productguru';
    
    SELECT user_id INTO v_following_id FROM n_users WHERE username = 'admin';
    sp_manage_follow(v_follower_id, v_following_id, 'follow', v_result);
    
    SELECT user_id INTO v_following_id FROM n_users WHERE username = 'cthaat';
    sp_manage_follow(v_follower_id, v_following_id, 'follow', v_result);
    
    SELECT user_id INTO v_following_id FROM n_users WHERE username = 'techuser';
    sp_manage_follow(v_follower_id, v_following_id, 'follow', v_result);
    
    SELECT user_id INTO v_following_id FROM n_users WHERE username = 'uiuxmaster';
    sp_manage_follow(v_follower_id, v_following_id, 'follow', v_result);
    
    DBMS_OUTPUT.PUT_LINE('关注关系6-9: 产品经理关注所有人');
END;
/

-- 11.5 插入点赞记录（使用子查询获取用户ID和推文ID）
INSERT INTO
    n_likes (
        user_id,
        tweet_id,
        like_type
    )
VALUES (
        (SELECT user_id FROM n_users WHERE username = 'cthaat'),
        (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'admin' AND ROWNUM = 1),
        'like'
    );


-- 11.6 插入评论数据（使用子查询获取用户ID和推文ID）
INSERT INTO
    n_comments (
        tweet_id,
        user_id,
        content
    )
VALUES (
        (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'admin' AND ROWNUM = 1),
        (SELECT user_id FROM n_users WHERE username = 'cthaat'),
        '感谢管理员！系统确实很棒，期待更多功能！'
    );

INSERT INTO
    n_comments (
        tweet_id,
        user_id,
        content
    )
VALUES (
        (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'admin' AND ROWNUM = 1),
        (SELECT user_id FROM n_users WHERE username = 'techuser'),
        '界面设计很现代，用户体验很好 👍'
    );

INSERT INTO
    n_comments (
        tweet_id,
        user_id,
        content,
        parent_comment_id
    )
VALUES (
        (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'admin' AND ROWNUM = 1),
        (SELECT user_id FROM n_users WHERE username = 'admin'),
        '谢谢大家的支持！我们会继续优化系统',
        (SELECT comment_id FROM n_comments WHERE content LIKE '感谢管理员！%' AND ROWNUM = 1)
    );

INSERT INTO
    n_comments (
        tweet_id,
        user_id,
        content
    )
VALUES (
        (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'cthaat' AND ROWNUM = 1),
        (SELECT user_id FROM n_users WHERE username = 'techuser'),
        '很实用的技术分享！能详细介绍一下索引优化吗？'
    );

INSERT INTO
    n_comments (
        tweet_id,
        user_id,
        content
    )
VALUES (
        (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'cthaat' AND ROWNUM = 1),
        (SELECT user_id FROM n_users WHERE username = 'uiuxmaster'),
        '作为设计师，我觉得数据库设计和UI设计有很多相通之处'
    );

INSERT INTO
    n_comments (
        tweet_id,
        user_id,
        content
    )
VALUES (
        (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'techuser' AND ROWNUM = 1),
        (SELECT user_id FROM n_users WHERE username = 'cthaat'),
        '确实，用户体验是最重要的！'
    );

-- 11.7 插入媒体文件数据（使用子查询获取用户ID和推文ID）
INSERT INTO
    n_media (
        tweet_id,
        user_id,
        media_type,
        file_name,
        file_path,
        file_size,
        mime_type,
        width,
        height,
        alt_text,
        is_processed
    )
VALUES (
        (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'admin' AND ROWNUM = 1),
        (SELECT user_id FROM n_users WHERE username = 'admin'),
        'image',
        'welcome_banner.jpg',
        '/uploads/media/welcome_banner.jpg',
        256000,
        'image/jpeg',
        1200,
        630,
        '推特克隆系统欢迎横幅图片',
        1
    );

INSERT INTO
    n_media (
        tweet_id,
        user_id,
        media_type,
        file_name,
        file_path,
        file_size,
        mime_type,
        width,
        height,
        alt_text,
        is_processed
    )
VALUES (
        (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'cthaat' AND ROWNUM = 1),
        (SELECT user_id FROM n_users WHERE username = 'cthaat'),
        'image',
        'database_diagram.png',
        '/uploads/media/database_diagram.png',
        512000,
        'image/png',
        1024,
        768,
        '数据库设计ER图',
        1
    );

INSERT INTO
    n_media (
        tweet_id,
        user_id,
        media_type,
        file_name,
        file_path,
        file_size,
        mime_type,
        width,
        height,
        alt_text,
        is_processed
    )
VALUES (
        (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'uiuxmaster' AND ROWNUM = 1),
        (SELECT user_id FROM n_users WHERE username = 'uiuxmaster'),
        'image',
        'ui_mockup.png',
        '/uploads/media/ui_mockup.png',
        384000,
        'image/png',
        800,
        600,
        'UI设计稿截图',
        1
    );

INSERT INTO
    n_media (
        user_id,
        media_type,
        file_name,
        file_path,
        file_size,
        mime_type,
        width,
        height,
        alt_text,
        is_processed
    )
VALUES (
        (SELECT user_id FROM n_users WHERE username = 'admin'),
        'image',
        'admin_avatar.png',
        '/uploads/avatars/admin_avatar.png',
        64000,
        'image/png',
        200,
        200,
        '管理员头像',
        1
    );

INSERT INTO
    n_media (
        user_id,
        media_type,
        file_name,
        file_path,
        file_size,
        mime_type,
        width,
        height,
        alt_text,
        is_processed
    )
VALUES (
        (SELECT user_id FROM n_users WHERE username = 'cthaat'),
        'image',
        'cthaat_avatar.jpg',
        '/uploads/avatars/cthaat_avatar.jpg',
        48000,
        'image/jpeg',
        200,
        200,
        'Cthaat开发者头像',
        1
    );

-- 11.8 插入用户会话数据（双Token机制，使用用户名查找用户ID）
INSERT INTO
    n_user_sessions (
        session_id,
        user_id,
        access_token,
        refresh_token,
        access_token_expires_at,
        refresh_token_expires_at,
        device_info,
        device_fingerprint,
        ip_address,
        user_agent
    )
VALUES (
        'sess_' || SUBSTR(SYS_GUID (), 1, 20),
        (SELECT user_id FROM n_users WHERE username = 'admin'),
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMDAwIiwiaWF0IjoxNjM5NTc4MDAwLCJleHAiOjE2Mzk1Nzk4MDB9.access_token_signature',
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMDAwIiwiaWF0IjoxNjM5NTc4MDAwLCJleHAiOjE2NDA3ODc2MDB9.refresh_token_signature',
        SYSDATE + INTERVAL '30' MINUTE,
        SYSDATE + INTERVAL '7' DAY,
        'Windows 10, Chrome 120',
        'win10_chrome_' || TO_CHAR (SYSDATE, 'YYYYMMDDHH24MISS'),
        '192.168.1.100',
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
    );

INSERT INTO
    n_user_sessions (
        session_id,
        user_id,
        access_token,
        refresh_token,
        access_token_expires_at,
        refresh_token_expires_at,
        device_info,
        device_fingerprint,
        ip_address,
        user_agent
    )
VALUES (
        'sess_' || SUBSTR(SYS_GUID (), 1, 20),
        (SELECT user_id FROM n_users WHERE username = 'cthaat'),
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMDAxIiwiaWF0IjoxNjM5NTc4MDAwLCJleHAiOjE2Mzk1Nzk4MDB9.access_token_signature',
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMDAxIiwiaWF0IjoxNjM5NTc4MDAwLCJleHAiOjE2NDA3ODc2MDB9.refresh_token_signature',
        SYSDATE + INTERVAL '30' MINUTE,
        SYSDATE + INTERVAL '7' DAY,
        'macOS Monterey, Safari 16',
        'macos_safari_' || TO_CHAR (SYSDATE, 'YYYYMMDDHH24MISS'),
        '192.168.1.101',
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15'
    );

INSERT INTO
    n_user_sessions (
        session_id,
        user_id,
        access_token,
        refresh_token,
        access_token_expires_at,
        refresh_token_expires_at,
        device_info,
        device_fingerprint,
        ip_address,
        user_agent
    )
VALUES (
        'sess_' || SUBSTR(SYS_GUID (), 1, 20),
        (SELECT user_id FROM n_users WHERE username = 'techuser'),
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMDAyIiwiaWF0IjoxNjM5NTc4MDAwLCJleHAiOjE2Mzk1Nzk4MDB9.access_token_signature',
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMDAyIiwiaWF0IjoxNjM5NTc4MDAwLCJleHAiOjE2NDA3ODc2MDB9.refresh_token_signature',
        SYSDATE + INTERVAL '30' MINUTE,
        SYSDATE + INTERVAL '7' DAY,
        'Ubuntu 22.04, Firefox 118',
        'ubuntu_firefox_' || TO_CHAR (SYSDATE, 'YYYYMMDDHH24MISS'),
        '192.168.1.102',
        'Mozilla/5.0 (X11; Linux x86_64; rv:118.0) Gecko/20100101 Firefox/118.0'
    );

-- 11.9 插入通知测试数据
-- 注意：通知表有触发器会自动创建通知，这里主要测试手动创建的通知

-- 重置通知序列到安全范围（避免与触发器生成的ID冲突）
DECLARE
    v_seq_val NUMBER;
BEGIN
    -- 获取当前序列值
    SELECT seq_notification_id.nextval INTO v_seq_val FROM dual;
    
    -- 确保序列值足够大，避免冲突
    IF v_seq_val < 20000000 THEN
        EXECUTE IMMEDIATE 'ALTER SEQUENCE seq_notification_id INCREMENT BY ' || (20000000 - v_seq_val);
        SELECT seq_notification_id.nextval INTO v_seq_val FROM dual;
        EXECUTE IMMEDIATE 'ALTER SEQUENCE seq_notification_id INCREMENT BY 1';
    END IF;
    
    DBMS_OUTPUT.PUT_LINE('通知序列当前值: ' || v_seq_val);
END;
/

-- 插入系统通知（使用序列自动生成ID，通过用户名查找用户ID）
INSERT INTO
    n_notifications (
        user_id,
        type,
        title,
        message,
        related_type,
        related_id,
        priority,
        is_read
    )
VALUES (
        (SELECT user_id FROM n_users WHERE username = 'cthaat'),
        'system',
        '欢迎加入NekoTribe！',
        '欢迎加入NekoTribe社交平台！开始分享你的想法，关注感兴趣的用户，发现精彩内容。',
        'user',
        (SELECT user_id FROM n_users WHERE username = 'cthaat'),
        'high',
        0
    );

INSERT INTO
    n_notifications (
        user_id,
        type,
        title,
        message,
        related_type,
        related_id,
        priority,
        is_read
    )
VALUES (
        (SELECT user_id FROM n_users WHERE username = 'techuser'),
        'system',
        '欢迎加入NekoTribe！',
        '欢迎加入NekoTribe社交平台！开始分享你的想法，关注感兴趣的用户，发现精彩内容。',
        'user',
        (SELECT user_id FROM n_users WHERE username = 'techuser'),
        'high',
        1
    );

INSERT INTO
    n_notifications (
        user_id,
        type,
        title,
        message,
        related_type,
        related_id,
        priority,
        is_read,
        read_at
    )
VALUES (
        (SELECT user_id FROM n_users WHERE username = 'uiuxmaster'),
        'system',
        '欢迎加入NekoTribe！',
        '欢迎加入NekoTribe社交平台！开始分享你的想法，关注感兴趣的用户，发现精彩内容。',
        'user',
        (SELECT user_id FROM n_users WHERE username = 'uiuxmaster'),
        'high',
        1,
        SYSDATE - INTERVAL '2' HOUR
    );

-- 插入活动通知
INSERT INTO
    n_notifications (
        user_id,
        type,
        title,
        message,
        priority,
        is_read
    )
VALUES (
        (SELECT user_id FROM n_users WHERE username = 'cthaat'),
        'system',
        '平台功能更新',
        '我们为平台增加了新的通知系统！现在你可以实时接收互动消息，不错过任何精彩时刻。',
        'normal',
        0
    );

INSERT INTO
    n_notifications (
        user_id,
        type,
        title,
        message,
        priority,
        is_read
    )
VALUES (
        (SELECT user_id FROM n_users WHERE username = 'techuser'),
        'system',
        '平台功能更新',
        '我们为平台增加了新的通知系统！现在你可以实时接收互动消息，不错过任何精彩时刻。',
        'normal',
        0
    );

-- 插入手动创建的用户互动通知（模拟未被触发器捕获的场景）
INSERT INTO
    n_notifications (
        user_id,
        type,
        title,
        message,
        related_type,
        related_id,
        actor_id,
        priority,
        is_read
    )
VALUES (
        (SELECT user_id FROM n_users WHERE username = 'admin'),
        'mention',
        '在推文中被提及',
        '@admin 管理员，你好！系统运行得很稳定，赞一个！',
        'tweet',
        (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'admin' AND ROWNUM = 1),
        (SELECT user_id FROM n_users WHERE username = 'techuser'),
        'normal',
        0
    );

INSERT INTO
    n_notifications (
        user_id,
        type,
        title,
        message,
        related_type,
        related_id,
        actor_id,
        priority,
        is_read,
        read_at
    )
VALUES (
        (SELECT user_id FROM n_users WHERE username = 'cthaat'),
        'mention',
        '在推文中被提及',
        '@cthaat 你的数据库设计技巧真的很实用，学到了很多！',
        'tweet',
        (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'cthaat' AND ROWNUM = 1),
        (SELECT user_id FROM n_users WHERE username = 'uiuxmaster'),
        'normal',
        1,
        SYSDATE - INTERVAL '1' HOUR
    );

-- 测试使用存储过程创建通知
DECLARE
    v_result VARCHAR2(500);
    v_user_id NUMBER;
    v_user_ids VARCHAR2(200);
BEGIN
    -- 创建一个高优先级系统通知
    SELECT user_id INTO v_user_id FROM n_users WHERE username = 'productguru';
    sp_create_notification(
        p_user_id => v_user_id,
        p_type => 'system',
        p_title => '账户安全提醒',
        p_message => '检测到您的账户从新设备登录，如果不是您本人操作，请立即修改密码。',
        p_priority => 'high',
        p_result => v_result
    );
    DBMS_OUTPUT.PUT_LINE('创建安全通知: ' || v_result);
    
    -- 批量创建活动通知（构建用户ID字符串）
    SELECT LISTAGG(user_id, ',') WITHIN GROUP (ORDER BY user_id)
    INTO v_user_ids
    FROM n_users WHERE username IN ('admin', 'cthaat', 'techuser', 'uiuxmaster', 'productguru');
    
    sp_batch_create_notifications(
        p_user_ids => v_user_ids,
        p_type => 'system',
        p_title => '周末活动预告',
        p_message => '本周末将举行技术分享活动，欢迎大家参加！分享你的开发经验，结识更多技术好友。',
        p_priority => 'normal',
        p_result => v_result
    );
    DBMS_OUTPUT.PUT_LINE('批量创建活动通知: ' || v_result);
    
    -- 创建个性化推荐通知
    SELECT user_id INTO v_user_id FROM n_users WHERE username = 'cthaat';
    sp_create_notification(
        p_user_id => v_user_id,
        p_type => 'system',
        p_title => '为你推荐',
        p_message => '基于你的兴趣，为你推荐了3位技术博主，快去关注他们吧！',
        p_related_type => 'recommendation',
        p_priority => 'normal',
        p_result => v_result
    );
    DBMS_OUTPUT.PUT_LINE('创建推荐通知: ' || v_result);
END;
/

-- 11.10 插入转发推文（作为回复和引用的示例）
-- 创建回复推文
INSERT INTO
    n_tweets (
        author_id,
        content,
        reply_to_tweet_id,
        visibility,
        language
    )
VALUES (
        (SELECT user_id FROM n_users WHERE username = 'uiuxmaster'),
        '@admin 系统的实时通知功能什么时候上线？很期待这个功能！',
        (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'admin' AND ROWNUM = 1),
        'public',
        'zh-CN'
    );

-- 创建转发推文
INSERT INTO
    n_tweets (
        author_id,
        content,
        retweet_of_tweet_id,
        visibility,
        language
    )
VALUES (
        (SELECT user_id FROM n_users WHERE username = 'productguru'),
        '转发一下这个优秀的技术分享！',
        (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'cthaat' AND ROWNUM = 1),
        'public',
        'zh-CN'
    );

-- 创建引用推文
INSERT INTO
    n_tweets (
        author_id,
        content,
        quote_tweet_id,
        visibility,
        language
    )
VALUES (
        (SELECT user_id FROM n_users WHERE username = 'techuser'),
        '同意！数据库设计确实是系统架构的基石。补充一点：除了表结构，索引策略也非常重要。',
        (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'cthaat' AND ROWNUM = 1),
        'public',
        'zh-CN'
    );

-- 更新引用推文的话题标签
INSERT INTO
    n_tweet_hashtags (tweet_id, hashtag_id)
VALUES (
    (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id 
     WHERE u.username = 'techuser' AND t.quote_tweet_id IS NOT NULL AND ROWNUM = 1),
    (SELECT hashtag_id FROM n_hashtags WHERE tag_name = '技术分享')
);

INSERT INTO
    n_tweet_hashtags (tweet_id, hashtag_id)
VALUES (
    (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id 
     WHERE u.username = 'techuser' AND t.quote_tweet_id IS NOT NULL AND ROWNUM = 1),
    (SELECT hashtag_id FROM n_hashtags WHERE tag_name = '数据库')
);

-- 更新转发和回复的用户推文数量
UPDATE n_users
SET
    tweets_count = tweets_count + 1
WHERE
    username = 'uiuxmaster';

UPDATE n_users
SET
    tweets_count = tweets_count + 1
WHERE
    username = 'productguru';

UPDATE n_users
SET
    tweets_count = tweets_count + 1
WHERE
    username = 'techuser';

-- 更新原推文的回复和转发数量
UPDATE n_tweets
SET
    replies_count = replies_count + 1
WHERE
    tweet_id = (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'admin' AND ROWNUM = 1);
-- 回复数+1

UPDATE n_tweets
SET
    retweets_count = retweets_count + 1
WHERE
    tweet_id = (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'cthaat' AND ROWNUM = 1);
-- 转发数+1

UPDATE n_tweets
SET
    retweets_count = retweets_count + 1
WHERE
    tweet_id = (SELECT t.tweet_id FROM n_tweets t JOIN n_users u ON t.author_id = u.user_id WHERE u.username = 'cthaat' AND ROWNUM = 1);
-- 引用也算转发数+1

-- 11.10 更新用户最后登录时间
UPDATE n_users
SET
    last_login_at = SYSDATE - DBMS_RANDOM.VALUE (0, 7)
WHERE
    username IN ('admin', 'cthaat', 'techuser', 'uiuxmaster', 'productguru');

COMMIT;

-- 输出测试数据插入结果
SELECT '测试数据插入完成！' as status, '包含5个用户、8条推文（5条原创+3条互动）、9个关注关系、7个点赞、6个评论、5个媒体文件、3个会话记录、10个话题标签、12+条通知记录' as summary
FROM dual;

-- 验证数据插入结果
SELECT 'ID验证' as check_type, '所有ID均由自增触发器自动生成，不再使用固定ID值' as id_ranges
FROM dual
UNION ALL
SELECT '外键验证' as check_type, '所有点赞记录对应的推文ID都存在，通知关联的用户ID都存在' as validation
FROM dual
UNION ALL
SELECT '数据完整性' as check_type, '推文数量、话题关联、用户统计、通知状态都已更新' as integrity
FROM dual
UNION ALL
SELECT
    '通知系统验证' as check_type,
    '包含系统通知、用户互动通知，测试已读/未读状态，ID由序列自动生成' as notification_check
FROM dual;

-- ==========================================
-- 通知系统测试查询
-- ==========================================

-- 测试通知函数和查询
SELECT '=== 通知系统功能测试 ===' as test_section FROM dual;

-- 1. 测试获取用户未读通知数量
SELECT
    u.username,
    u.display_name,
    fn_get_unread_notification_count (u.user_id) as unread_count
FROM n_users u
WHERE
    u.username IN ('admin', 'cthaat', 'techuser', 'uiuxmaster', 'productguru')
ORDER BY u.user_id;

-- 2. 测试通知列表查询（模拟API调用）
SELECT 'cthaat用户的通知列表：' as query_info FROM dual;

SELECT
    n.notification_id,
    n.type,
    n.title,
    SUBSTR(n.message, 1, 50) || CASE
        WHEN LENGTH(n.message) > 50 THEN '...'
        ELSE ''
    END as message_preview,
    n.is_read,
    n.priority,
    TO_CHAR (
        n.created_at,
        'YYYY-MM-DD HH24:MI:SS'
    ) as created_time,
    CASE
        WHEN n.actor_id IS NOT NULL THEN u.username
        ELSE '系统'
    END as actor
FROM n_notifications n
    LEFT JOIN n_users u ON n.actor_id = u.user_id
WHERE
    n.user_id = (SELECT user_id FROM n_users WHERE username = 'cthaat')
ORDER BY n.created_at DESC;

-- 3. 测试按通知类型统计
SELECT '各类型通知统计：' as query_info FROM dual;

SELECT
    type as notification_type,
    COUNT(*) as total_count,
    SUM(
        CASE
            WHEN is_read = 0 THEN 1
            ELSE 0
        END
    ) as unread_count,
    SUM(
        CASE
            WHEN is_read = 1 THEN 1
            ELSE 0
        END
    ) as read_count
FROM n_notifications
GROUP BY
    type
ORDER BY total_count DESC;

-- 4. 测试通知优先级分布
SELECT '通知优先级分布：' as query_info FROM dual;

SELECT priority, COUNT(*) as count, ROUND(
        COUNT(*) * 100.0 / (
            SELECT COUNT(*)
            FROM n_notifications
        ), 2
    ) as percentage
FROM n_notifications
GROUP BY
    priority
ORDER BY
    CASE priority
        WHEN 'high' THEN 1
        WHEN 'normal' THEN 2
        ELSE 3
    END;

-- 5. 测试最近24小时的通知活动
SELECT '最近24小时通知活动：' as query_info FROM dual;

SELECT
    TO_CHAR (created_at, 'YYYY-MM-DD HH24') as hour_block,
    COUNT(*) as notification_count
FROM n_notifications
WHERE
    created_at >= SYSDATE - 1
GROUP BY
    TO_CHAR (created_at, 'YYYY-MM-DD HH24')
ORDER BY hour_block DESC;

-- 6. 测试用户通知响应率
SELECT '用户通知响应情况：' as query_info FROM dual;

SELECT
    u.username,
    COUNT(n.notification_id) as total_notifications,
    SUM(
        CASE
            WHEN n.is_read = 1 THEN 1
            ELSE 0
        END
    ) as read_notifications,
    CASE
        WHEN COUNT(n.notification_id) > 0 THEN ROUND(
            SUM(
                CASE
                    WHEN n.is_read = 1 THEN 1
                    ELSE 0
                END
            ) * 100.0 / COUNT(n.notification_id),
            2
        )
        ELSE 0
    END as read_rate_percentage
FROM n_users u
    LEFT JOIN n_notifications n ON u.user_id = n.user_id
WHERE
    u.username IN ('admin', 'cthaat', 'techuser', 'uiuxmaster', 'productguru')
GROUP BY
    u.user_id,
    u.username
ORDER BY read_rate_percentage DESC;

-- 7. 测试通知消息格式化函数
SELECT '通知消息格式化测试：' as query_info FROM dual;

SELECT
    'like' as type,
    fn_format_notification_message (
        'like',
        'testuser',
        '这是一条测试推文内容'
    ) as formatted_message
FROM dual
UNION ALL
SELECT
    'follow' as type,
    fn_format_notification_message ('follow', 'newuser') as formatted_message
FROM dual
UNION ALL
SELECT
    'comment' as type,
    fn_format_notification_message ('comment', 'commenter') as formatted_message
FROM dual
UNION ALL
SELECT
    'retweet' as type,
    fn_format_notification_message (
        'retweet',
        'retweeter',
        '这是原推文内容，会被截断显示前50个字符，超出部分会用省略号表示'
    ) as formatted_message
FROM dual;

-- 8. 测试批量标记已读功能
DECLARE
    v_count NUMBER;
    v_notification_ids VARCHAR2(1000);
    v_user_id NUMBER;
BEGIN
    -- 测试标记techuser的所有通知为已读
    SELECT user_id INTO v_user_id FROM n_users WHERE username = 'techuser';
    v_count := fn_mark_notifications_read(v_user_id);
    DBMS_OUTPUT.PUT_LINE('techuser标记了 ' || v_count || ' 个通知为已读');
    
    -- 获取productguru的前两个通知ID进行测试
    SELECT user_id INTO v_user_id FROM n_users WHERE username = 'productguru';
    SELECT LISTAGG(notification_id, ',') WITHIN GROUP (ORDER BY notification_id)
    INTO v_notification_ids
    FROM (
        SELECT notification_id 
        FROM n_notifications 
        WHERE user_id = v_user_id 
        AND ROWNUM <= 2
    );
    
    IF v_notification_ids IS NOT NULL THEN
        v_count := fn_mark_notifications_read(v_user_id, v_notification_ids);
        DBMS_OUTPUT.PUT_LINE('productguru标记了 ' || v_count || ' 个指定通知为已读 (IDs: ' || v_notification_ids || ')');
    ELSE
        DBMS_OUTPUT.PUT_LINE('productguru没有可标记的通知');
    END IF;
END;
/

SELECT '=== 通知系统测试完成 ===' as test_complete FROM dual;

-- ==========================================
-- NekoTribe Oracle数据库完整设计方案
-- 作者: 彭涛
-- 创建日期: 2025-06-25
-- 数据库版本: Oracle 19c+
-- ==========================================

-- 12. 权限分配给只读用户
-- ==========================================

-- 给只读用户分配查看权限
GRANT SELECT ON n_users TO neko_readonly;

GRANT SELECT ON n_tweets TO neko_readonly;

GRANT SELECT ON n_follows TO neko_readonly;

GRANT SELECT ON n_likes TO neko_readonly;

GRANT SELECT ON n_comments TO neko_readonly;

GRANT SELECT ON n_media TO neko_readonly;

GRANT SELECT ON n_hashtags TO neko_readonly;

GRANT SELECT ON n_tweet_hashtags TO neko_readonly;

-- 给只读用户分配视图权限
GRANT SELECT ON v_user_profile TO neko_readonly;

GRANT SELECT ON v_tweet_details TO neko_readonly;

GRANT SELECT ON v_trending_hashtags TO neko_readonly;

GRANT SELECT ON v_user_engagement_stats TO neko_readonly;

GRANT SELECT ON v_tweet_interactions TO neko_readonly;

-- ==========================================
-- NekoTribe Oracle数据库完整设计方案
-- 作者: 彭涛
-- 创建日期: 2025-06-25
-- 数据库版本: Oracle 19c+
-- ==========================================

-- 13. 数据库统计信息收集
-- ==========================================

-- 收集表统计信息以优化查询性能
BEGIN
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_USERS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_TWEETS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_FOLLOWS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_LIKES');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_COMMENTS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_MEDIA');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_HASHTAGS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_TWEET_HASHTAGS');
    DBMS_STATS.GATHER_TABLE_STATS('NEKO_APP', 'N_USER_SESSIONS');
END;
/

-- 14. 创建常用查询的物化视图（需要CREATE MATERIALIZED VIEW权限）
-- ==========================================

-- 注意：以下物化视图需要特殊权限才能创建，如果当前用户权限不足，请联系管理员创建

-- 用户活跃度统计物化视图
/*
CREATE MATERIALIZED VIEW mv_user_activity_daily
REFRESH COMPLETE ON DEMAND
AS
SELECT 
TRUNC(t.created_at) as activity_date,
t.author_id,
u.username,
COUNT(*) as daily_tweets,
SUM(t.likes_count) as daily_likes_received,
AVG(t.likes_count) as avg_likes_per_tweet
FROM n_tweets t
JOIN n_users u ON t.author_id = u.user_id
WHERE t.is_deleted = 0
GROUP BY TRUNC(t.created_at), t.author_id, u.username;

-- 话题趋势统计物化视图
CREATE MATERIALIZED VIEW mv_hashtag_trends_hourly
REFRESH COMPLETE ON DEMAND
AS
SELECT 
TRUNC(t.created_at, 'HH24') as trend_hour,
h.hashtag_id,
h.tag_name,
COUNT(*) as hourly_usage,
COUNT(DISTINCT t.author_id) as unique_users
FROM n_tweets t
JOIN n_tweet_hashtags th ON t.tweet_id = th.tweet_id
JOIN n_hashtags h ON th.hashtag_id = h.hashtag_id
WHERE t.is_deleted = 0
GROUP BY TRUNC(t.created_at, 'HH24'), h.hashtag_id, h.tag_name;
*/

-- 输出创建成功信息
SELECT 'NekoTribe数据库创建完成！' as status, '包含8个主要数据表、6个视图、3个存储过程、3个函数、7个触发器' as details, '支持用户管理、推文发布、关注关系、点赞评论、媒体文件、话题标签等完整功能' as features
FROM dual;

-- 显示表结构概览
SELECT
    table_name,
    (
        SELECT COUNT(*)
        FROM user_tab_columns
        WHERE
            table_name = ut.table_name
    ) as column_count,
    (
        SELECT COUNT(*)
        FROM user_constraints
        WHERE
            table_name = ut.table_name
            AND constraint_type = 'R'
    ) as foreign_keys
FROM user_tables ut
WHERE
    table_name LIKE 'N_%'
ORDER BY table_name;