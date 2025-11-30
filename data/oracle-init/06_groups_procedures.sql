-- ============================================
-- NekoTribe 群组功能 - 存储过程脚本
-- 作者: NekoTribe Team
-- 创建日期: 2025-11-30
-- 描述: 创建群组核心业务存储过程
-- ============================================

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