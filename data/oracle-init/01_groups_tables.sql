-- ============================================
-- NekoTribe 群组功能 - 建表脚本
-- 作者: NekoTribe Team
-- 创建日期: 2025-11-30
-- 描述: 创建群组功能相关的六个核心表
-- ============================================

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

