-- ============================================
-- NekoTribe 群组功能 - 序列和触发器脚本
-- 作者: NekoTribe Team
-- 创建日期: 2025-11-30
-- 描述: 创建自增ID的序列和触发器
-- ============================================

-- ============================================
-- 序列定义
-- ============================================

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

-- ============================================
-- 触发器定义 - 自动生成主键ID
-- ============================================

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
