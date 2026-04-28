-- ============================================
-- NekoTribe 群组功能 - 视图脚本
-- 作者: NekoTribe Team
-- 创建日期: 2025-11-30
-- 描述: 创建群组相关的视图，简化查询
-- ============================================

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
