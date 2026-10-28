package server

import (
	"context"
	"database/sql"
	"errors"
	"strings"
)

var (
	errPostReferenceUnavailable = errors.New("post reference unavailable")
	errPostMediaUnavailable     = errors.New("post media unavailable")
	errPostCreateInvalid        = errors.New("post create input invalid")
	errPostContentEmpty         = errors.New("post content empty")
)

// PostCreateInput is an internal, already parsed request; no notification is sent by this transaction.
type PostCreateInput struct {
	Content, Visibility, Location               string
	ReplyToPostID, RepostOfPostID, QuotedPostID *int64
	MediaIDs                                    []int64
	Tags                                        []string
	Mentions                                    []int64
}

const insertPostAtomicSQL = `INSERT INTO n_posts (post_id,author_id,content,post_type,reply_to_post_id,repost_of_post_id,quoted_post_id,visibility,language,location) SELECT :post_id,:author_id,:content,:post_type,:reply_to_post_id,:repost_of_post_id,:quoted_post_id,:visibility,'zh',:location FROM dual`
const insertPostMediaAtomicSQL = `INSERT INTO n_post_media (post_id,media_id,sort_order) SELECT :post_id,media_id,:sort_order FROM n_media_assets WHERE media_id=:media_id AND owner_user_id=:user_id AND status IN ('uploaded','processing','ready')`
const mergePostTagAtomicSQL = `MERGE INTO n_tags t USING (SELECT :name AS name, LOWER(:name) AS name_lower FROM dual) src ON (t.name_lower=src.name_lower) WHEN NOT MATCHED THEN INSERT (tag_id,name,name_lower) VALUES (seq_tag_id.NEXTVAL,src.name,src.name_lower)`
const attachPostTagAtomicSQL = `INSERT INTO n_post_tags (post_id,tag_id) SELECT :post_id,tag_id FROM n_tags WHERE name_lower=LOWER(:name) AND NOT EXISTS (SELECT 1 FROM n_post_tags WHERE post_id=:post_id AND tag_id=n_tags.tag_id)`
const attachPostMentionAtomicSQL = `INSERT INTO n_post_mentions (post_id,mentioned_user_id) SELECT :post_id,user_id FROM n_users WHERE user_id=:user_id AND NOT EXISTS (SELECT 1 FROM n_post_mentions WHERE post_id=:post_id AND mentioned_user_id=:user_id)`

// CreatePostAtomic commits a post and its relationships once. Notifications and reads follow outside this transaction.
func (s OracleSessions) CreatePostAtomic(ctx context.Context, user int64, input PostCreateInput) (id int64, err error) {
	if user <= 0 {
		return 0, errPostCreateInvalid
	}
	if input.Visibility == "" {
		input.Visibility = "public"
	}
	switch input.Visibility {
	case "public", "followers", "mentioned", "private":
	default:
		return 0, errPostCreateInvalid
	}
	kind := "post"
	var source *int64
	for _, ref := range []struct {
		id   *int64
		kind string
	}{{input.ReplyToPostID, "reply"}, {input.RepostOfPostID, "repost"}, {input.QuotedPostID, "quote"}} {
		if ref.id != nil {
			if source != nil || *ref.id <= 0 || *ref.id > 9007199254740991 {
				return 0, errPostCreateInvalid
			}
			source = ref.id
			kind = ref.kind
		}
	}
	media := uniquePostIDs(input.MediaIDs, 4)
	if kind != "repost" && strings.TrimFunc(input.Content, jsTrimSpace) == "" && len(media) == 0 {
		return 0, errPostContentEmpty
	}
	conn, e := s.DB.Conn(ctx)
	if e != nil {
		return 0, errSessionStore
	}
	defer func() {
		if conn.Close() != nil {
			id = 0
			err = errSessionStore
		}
	}()
	if source != nil {
		var found int64
		e = conn.QueryRowContext(ctx, bookmarkVisibilitySQL, sql.Named("post_id", *source), sql.Named("user_id", user)).Scan(&found)
		if errors.Is(e, sql.ErrNoRows) {
			return 0, errPostReferenceUnavailable
		}
		if e != nil {
			return 0, errSessionStore
		}
	}
	if e = conn.QueryRowContext(ctx, `SELECT seq_post_id.NEXTVAL FROM dual`).Scan(&id); e != nil {
		return 0, errSessionStore
	}
	tx, e := conn.BeginTx(ctx, nil)
	if e != nil {
		return 0, errSessionStore
	}
	committed := false
	defer func() {
		if !committed {
			if e := tx.Rollback(); e != nil && !errors.Is(e, sql.ErrTxDone) {
				id = 0
				err = errSessionStore
			}
		}
	}()
	query := insertPostAtomicSQL
	binds := []any{sql.Named("post_id", id), sql.Named("author_id", user), sql.Named("content", nullablePostString(input.Content)), sql.Named("post_type", kind), sql.Named("reply_to_post_id", input.ReplyToPostID), sql.Named("repost_of_post_id", input.RepostOfPostID), sql.Named("quoted_post_id", input.QuotedPostID), sql.Named("visibility", input.Visibility), sql.Named("location", nullablePostString(input.Location))}
	if source != nil {
		query += ` WHERE EXISTS (SELECT 1 FROM n_posts p WHERE p.post_id=:source_post_id AND p.is_deleted=0 AND fn_can_view_post(:author_id,p.post_id)=1)`
		binds = append(binds, sql.Named("source_post_id", *source))
	}
	n, e := postTxExecute(ctx, tx, query, binds...)
	if e != nil {
		return 0, e
	}
	if n == 0 {
		return 0, errPostReferenceUnavailable
	}
	if n != 1 {
		return 0, errSessionStore
	}
	for i, mediaID := range media {
		n, e = postTxExecute(ctx, tx, insertPostMediaAtomicSQL, sql.Named("post_id", id), sql.Named("media_id", mediaID), sql.Named("sort_order", i+1), sql.Named("user_id", user))
		if e != nil {
			return 0, e
		}
		if n != 1 {
			return 0, errPostMediaUnavailable
		}
	}
	for _, tag := range uniquePostTags(input.Tags) {
		if _, e = postTxExecute(ctx, tx, mergePostTagAtomicSQL, sql.Named("name", tag)); e != nil {
			return 0, e
		}
		if _, e = postTxExecute(ctx, tx, attachPostTagAtomicSQL, sql.Named("post_id", id), sql.Named("name", tag)); e != nil {
			return 0, e
		}
	}
	for _, mentioned := range uniquePostIDs(input.Mentions, 50) {
		if _, e = postTxExecute(ctx, tx, attachPostMentionAtomicSQL, sql.Named("post_id", id), sql.Named("user_id", mentioned)); e != nil {
			return 0, e
		}
	}
	if e = tx.Commit(); e != nil {
		return 0, errSessionStore
	}
	committed = true
	return id, nil
}
func postTxExecute(ctx context.Context, tx *sql.Tx, query string, args ...any) (int64, error) {
	result, err := tx.ExecContext(ctx, query, args...)
	if err != nil {
		return 0, errSessionStore
	}
	n, err := result.RowsAffected()
	if err != nil {
		return 0, errSessionStore
	}
	return n, nil
}
func nullablePostString(value string) any {
	if value == "" {
		return nil
	}
	return value
}
func uniquePostIDs(values []int64, limit int) []int64 {
	out := make([]int64, 0, limit)
	seen := make(map[int64]bool)
	for _, value := range values {
		if !seen[value] {
			seen[value] = true
			out = append(out, value)
			if len(out) == limit {
				break
			}
		}
	}
	return out
}
func uniquePostTags(values []string) []string {
	out := make([]string, 0, 20)
	seen := make(map[string]bool)
	for _, value := range values {
		value = strings.TrimFunc(value, jsTrimSpace)
		value = strings.TrimFunc(strings.TrimPrefix(value, "#"), jsTrimSpace)
		if value != "" && !seen[value] {
			seen[value] = true
			out = append(out, value)
			if len(out) == 20 {
				break
			}
		}
	}
	return out
}
