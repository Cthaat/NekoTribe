-- ============================================
-- NekoTribe 群组功能 - 索引脚本
-- 作者: NekoTribe Team
-- 创建日期: 2025-11-30
-- 描述: 创建优化查询性能的索引
-- ============================================

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
