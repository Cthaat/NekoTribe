package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
)

func (s OracleSessions) CommentNoticeContext(ctx context.Context, actor, post, comment int64) (commentNoticeContext, error) {
	result := commentNoticeContext{ActorName: "有人", CommentExcerpt: json.RawMessage("null"), PostExcerpt: json.RawMessage("null")}
	var name sql.NullString
	err := s.DB.QueryRowContext(ctx, `SELECT COALESCE(display_name,username) FROM n_users WHERE user_id=:user_id`, sql.Named("user_id", actor)).Scan(&name)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return result, errSessionStore
	}
	if err == nil && name.Valid {
		result.ActorName = name.String
	}
	var author sql.NullInt64
	err = s.DB.QueryRowContext(ctx, `SELECT author_id FROM n_posts WHERE post_id=:post_id AND is_deleted=0`, sql.Named("post_id", post)).Scan(&author)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return result, errSessionStore
	}
	if err == nil && author.Valid {
		result.PostAuthor = author.Int64
	}
	_, excerpt, err := s.commentExcerpt(ctx, comment)
	if err != nil {
		return result, err
	}
	result.CommentExcerpt = excerpt
	var content sql.NullString
	err = s.DB.QueryRowContext(ctx, `SELECT DBMS_LOB.SUBSTR(content,4000,1) FROM n_posts WHERE post_id=:post_id AND is_deleted=0`, sql.Named("post_id", post)).Scan(&content)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return result, errSessionStore
	}
	if err == nil {
		result.PostExcerpt = postLikeExcerpt(content)
	}
	return result, nil
}

func (s OracleSessions) commentExcerpt(ctx context.Context, id int64) (int64, json.RawMessage, error) {
	var user, post sql.NullInt64
	var content sql.NullString
	err := s.DB.QueryRowContext(ctx, `SELECT user_id,post_id,DBMS_LOB.SUBSTR(content,4000,1) FROM n_comments WHERE comment_id=:comment_id AND is_deleted=0`, sql.Named("comment_id", id)).Scan(&user, &post, &content)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, json.RawMessage("null"), nil
	}
	if err != nil {
		return 0, nil, errSessionStore
	}
	return user.Int64, postLikeExcerpt(content), nil
}

func (s OracleSessions) CommentParentNotice(ctx context.Context, id, postAuthor int64) (commentParentNotice, error) {
	result := commentParentNotice{Excerpt: json.RawMessage("null")}
	var author sql.NullInt64
	err := s.DB.QueryRowContext(ctx, `SELECT user_id FROM n_comments WHERE comment_id=:comment_id AND is_deleted=0`, sql.Named("comment_id", id)).Scan(&author)
	if errors.Is(err, sql.ErrNoRows) {
		return result, nil
	}
	if err != nil {
		return result, errSessionStore
	}
	if !author.Valid {
		return result, nil
	}
	result.Author = author.Int64
	if result.Author == postAuthor {
		return result, nil
	}
	_, result.Excerpt, err = s.commentExcerpt(ctx, id)
	if err != nil {
		return result, err
	}
	return result, nil
}

func (s OracleSessions) StoreCommentNotification(ctx context.Context, input notificationInput) (*notificationStored, error) {
	return s.storeNotification(ctx, input)
}
