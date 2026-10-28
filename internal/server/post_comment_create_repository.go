package server

import (
	"context"
	"database/sql"
	"errors"
)

var (
	errCommentPostUnavailable   = errors.New("post unavailable")
	errCommentParentUnavailable = errors.New("parent comment unavailable")
	errCommentUnavailable       = errors.New("comment unavailable")
)

const insertCommentSQL = `INSERT INTO n_comments (comment_id,post_id,user_id,parent_comment_id,root_comment_id,content) SELECT :comment_id,:post_id,:user_id,:parent_comment_id,:root_comment_id,:content FROM dual WHERE fn_can_view_post(:user_id,:post_id)=1 AND EXISTS (SELECT 1 FROM n_posts p WHERE p.post_id=:post_id AND p.is_deleted=0) AND (:parent_comment_id IS NULL OR EXISTS (SELECT 1 FROM n_comments parent WHERE parent.comment_id=:parent_comment_id AND parent.post_id=:post_id AND parent.is_deleted=0))`
const createdCommentSQL = `SELECT c.comment_id,c.post_id,c.user_id,c.parent_comment_id,c.root_comment_id,DBMS_LOB.SUBSTR(c.content,4000,1),c.created_at,c.updated_at,c.likes_count,c.replies_count,0 AS is_liked FROM v_post_comment_list_item c WHERE c.comment_id=:comment_id AND c.post_id=:post_id AND c.user_id=:viewer_id AND fn_can_view_post(:viewer_id,c.post_id)=1`

// CreatePostComment commits the insert independently of later reads and notification delivery.
func (s OracleSessions) CreatePostComment(ctx context.Context, user, post int64, content string, parent *int64) (PostComment, error) {
	visible, err := s.bookmarkVisible(ctx, user, post)
	if err != nil {
		return PostComment{}, err
	}
	if !visible {
		return PostComment{}, errCommentPostUnavailable
	}
	var id int64
	if err = s.DB.QueryRowContext(ctx, `SELECT seq_comment_id.NEXTVAL FROM dual`).Scan(&id); err != nil {
		return PostComment{}, errSessionStore
	}
	root := id
	if parent != nil {
		err = s.DB.QueryRowContext(ctx, `SELECT NVL(root_comment_id, comment_id) FROM n_comments WHERE comment_id=:comment_id AND post_id=:post_id AND is_deleted=0`, sql.Named("comment_id", *parent), sql.Named("post_id", post)).Scan(&root)
		if errors.Is(err, sql.ErrNoRows) {
			return PostComment{}, errCommentParentUnavailable
		}
		if err != nil {
			return PostComment{}, errSessionStore
		}
	}
	changed, err := s.execute(ctx, insertCommentSQL, sql.Named("comment_id", id), sql.Named("post_id", post), sql.Named("user_id", user), sql.Named("parent_comment_id", parent), sql.Named("root_comment_id", root), sql.Named("content", content))
	if err != nil {
		return PostComment{}, err
	}
	if changed == 0 {
		visible, err = s.bookmarkVisible(ctx, user, post)
		if err != nil {
			return PostComment{}, err
		}
		if !visible {
			return PostComment{}, errCommentPostUnavailable
		}
		if parent != nil {
			return PostComment{}, errCommentParentUnavailable
		}
		return PostComment{}, errCommentPostUnavailable
	}
	item, err := scanPostComment(s.DB.QueryRowContext(ctx, createdCommentSQL, sql.Named("comment_id", id), sql.Named("post_id", post), sql.Named("viewer_id", user)))
	if errors.Is(err, sql.ErrNoRows) {
		return PostComment{}, errCommentUnavailable
	}
	if err != nil {
		return PostComment{}, errSessionStore
	}
	return item, nil
}
