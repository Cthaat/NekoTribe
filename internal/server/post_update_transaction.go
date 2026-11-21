package server

import (
	"context"
	"database/sql"
	"errors"
	"strings"
)

var errPostUpdateNotOwner = errors.New("post update not owner")
var errPostUpdateMedia = errors.New("post update media unavailable")

func (s OracleSessions) UpdatePostAtomic(ctx context.Context, user, id int64, input PostUpdateInput) (err error) {
	if user <= 0 || id <= 0 || user > 9007199254740991 || id > 9007199254740991 {
		return errSessionStore
	}
	conn, e := s.DB.Conn(ctx)
	if e != nil {
		return errSessionStore
	}
	defer func() {
		if conn.Close() != nil {
			err = errSessionStore
		}
	}()
	tx, e := conn.BeginTx(ctx, nil)
	if e != nil {
		return errSessionStore
	}
	committed := false
	defer func() {
		if !committed {
			if e := tx.Rollback(); e != nil && !errors.Is(e, sql.ErrTxDone) {
				err = errSessionStore
			}
		}
	}()
	if err := checkPublishAccess(ctx, tx, user); err != nil {
		return err
	}
	var owner, deleted int64
	var kind string
	var content, visibility sql.NullString
	e = tx.QueryRowContext(ctx, `SELECT author_id,is_deleted,post_type,DBMS_LOB.SUBSTR(content,4000,1) AS content,visibility FROM n_posts WHERE post_id=:post_id FOR UPDATE`, sql.Named("post_id", id)).Scan(&owner, &deleted, &kind, &content, &visibility)
	if errors.Is(e, sql.ErrNoRows) {
		return errPostReferenceUnavailable
	}
	if e != nil {
		return errSessionStore
	}
	if deleted == 1 {
		return errPostReferenceUnavailable
	}
	if owner != user {
		return errPostUpdateNotOwner
	}
	nextContent := content.String
	if input.Content != nil {
		nextContent = *input.Content
	}
	nextVisibility := visibility.String
	if input.Visibility != nil {
		nextVisibility = *input.Visibility
	}
	if input.MediaIDs == nil && input.Visibility != nil && nextVisibility == "public" {
		if err := rejectRetainedPrivatePostMedia(ctx, tx, id); err != nil {
			return err
		}
	}
	var mediaCount int
	var mediaIDs []float64
	if input.MediaIDs != nil {
		mediaIDs = uniquePostIDs(*input.MediaIDs, 4)
		mediaCount = len(mediaIDs)
	} else if tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM n_post_media WHERE post_id=:post_id`, sql.Named("post_id", id)).Scan(&mediaCount) != nil {
		return errSessionStore
	}
	if kind != "repost" && strings.TrimFunc(nextContent, jsTrimSpace) == "" && mediaCount == 0 {
		return errPostContentEmpty
	}
	fields := []string{}
	binds := []interface{}{sql.Named("post_id", id), sql.Named("user_id", user)}
	for _, field := range []struct {
		name  string
		value *string
	}{{"content", input.Content}, {"visibility", input.Visibility}, {"language", input.Language}, {"location", input.Location}} {
		if field.value != nil {
			fields = append(fields, field.name+"=:"+field.name)
			binds = append(binds, sql.Named(field.name, nullablePostString(*field.value)))
		}
	}
	if len(fields) > 0 || input.MediaIDs != nil || input.Tags != nil || input.Mentions != nil {
		fields = append(fields, "updated_at=CURRENT_TIMESTAMP")
		n, e := postTxExecute(ctx, tx, "UPDATE n_posts SET "+strings.Join(fields, ",")+" WHERE post_id=:post_id AND author_id=:user_id AND is_deleted=0", binds...)
		if e != nil {
			return e
		}
		if n == 0 {
			return errPostReferenceUnavailable
		}
		if n != 1 {
			return errSessionStore
		}
	}
	if input.MediaIDs != nil {
		if err := lockPostMedia(ctx, tx, user, id, nextVisibility, mediaIDs, errPostUpdateMedia); err != nil {
			return err
		}
		if _, e := postTxExecute(ctx, tx, `DELETE FROM n_post_media WHERE post_id=:post_id`, sql.Named("post_id", id)); e != nil {
			return e
		}
		for index, media := range mediaIDs {
			n, e := postTxExecute(ctx, tx, insertPostMediaAtomicSQL, sql.Named("post_id", id), sql.Named("user_id", user), sql.Named("media_id", media), sql.Named("sort_order", index+1))
			if e != nil {
				return e
			}
			if n != 1 {
				return errPostUpdateMedia
			}
		}
	}
	if input.Tags != nil {
		if _, e := postTxExecute(ctx, tx, `DELETE FROM n_post_tags WHERE post_id=:post_id`, sql.Named("post_id", id)); e != nil {
			return e
		}
		for _, tag := range uniquePostTags(*input.Tags) {
			if _, e := postTxExecute(ctx, tx, mergePostTagAtomicSQL, sql.Named("name", tag)); e != nil {
				return e
			}
			if _, e := postTxExecute(ctx, tx, attachPostTagAtomicSQL, sql.Named("post_id", id), sql.Named("name", tag)); e != nil {
				return e
			}
		}
	}
	if input.Mentions != nil {
		if _, e := postTxExecute(ctx, tx, `DELETE FROM n_post_mentions WHERE post_id=:post_id`, sql.Named("post_id", id)); e != nil {
			return e
		}
		for _, user := range uniquePostIDs(*input.Mentions, 50) {
			if _, e := postTxExecute(ctx, tx, attachPostMentionAtomicSQL, sql.Named("post_id", id), sql.Named("user_id", user)); e != nil {
				return e
			}
		}
	}
	if tx.Commit() != nil {
		return errSessionStore
	}
	committed = true
	return nil
}
