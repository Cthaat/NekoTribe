-- ============================================
-- NekoTribe 群组功能 - 函数脚本
-- 作者: NekoTribe Team
-- 创建日期: 2025-11-30
-- 描述: 创建权限检查、辅助计算等函数
-- ============================================

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
