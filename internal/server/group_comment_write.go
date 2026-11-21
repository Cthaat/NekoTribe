package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type groupCommentMutation struct {
	group, post, comment int64
	action, content      string
	parent, reply        *int64
}

type groupCommentWriteStore interface {
	WriteGroupComment(context.Context, int64, groupCommentMutation, StorageURLPolicy) (any, error)
}

const canCommentGroupContentSQL = "SELECT fn_has_group_permission(:user_id,:group_id,'member') FROM dual"
const groupCommentAuthorSQL = "SELECT author_id FROM n_group_comments WHERE post_id=:post_id AND comment_id=:comment_id AND is_deleted=0"
const insertGroupCommentSQL = `INSERT INTO n_group_comments (comment_id,post_id,author_id,parent_comment_id,reply_to_user_id,content)
VALUES (:comment_id,:post_id,:user_id,:parent_comment_id,:reply_to_user_id,:content)`
const readCreatedGroupCommentSQL = `SELECT comment_id,post_id,author_id,parent_comment_id,reply_to_user_id,content,likes_count,created_at,updated_at,0,1
FROM n_group_comments WHERE post_id=:post_id AND comment_id=:comment_id AND is_deleted=0`
const deleteGroupCommentSQL = `UPDATE n_group_comments SET is_deleted=1,deleted_by=:user_id
WHERE post_id=:post_id AND comment_id=:comment_id AND is_deleted=0`
const likeGroupCommentSQL = `INSERT INTO n_group_comment_likes (comment_id,user_id)
SELECT :comment_id,:user_id FROM dual WHERE NOT EXISTS
(SELECT 1 FROM n_group_comment_likes WHERE comment_id=:comment_id AND user_id=:user_id)`
const unlikeGroupCommentSQL = "DELETE FROM n_group_comment_likes WHERE comment_id=:comment_id AND user_id=:user_id"

func requireGroupCommentAuthor(ctx context.Context, tx *sql.Tx, post, comment sql.NamedArg) (int64, error) {
	var author int64
	err := tx.QueryRowContext(ctx, groupCommentAuthorSQL, post, comment).Scan(&author)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, &groupMembershipFailure{404, "群组评论不存在"}
	}
	if err != nil {
		return 0, errSessionStore
	}
	return author, nil
}

func (s OracleSessions) WriteGroupComment(ctx context.Context, actor int64, in groupCommentMutation, storage StorageURLPolicy) (any, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, errSessionStore
	}
	defer tx.Rollback()
	gb, ab, pb := sql.Named("group_id", in.group), sql.Named("user_id", actor), sql.Named("post_id", in.post)
	if err := lockGroupContent(ctx, tx, ab, gb); err != nil {
		return nil, err
	}
	author, err := requireGroupPostAuthor(ctx, tx, gb, pb)
	if err != nil {
		return nil, err
	}
	if in.action != "delete" {
		if err := requireVisibleGroupAuthor(ctx, tx, actor, author, "群组帖子不存在"); err != nil {
			return nil, err
		}
	}
	var value any
	if in.action == "create" {
		value, err = createGroupComment(ctx, tx, actor, author, in, storage)
	} else {
		value, err = changeGroupComment(ctx, tx, actor, author, in)
	}
	if err != nil {
		return nil, err
	}
	if tx.Commit() != nil {
		return nil, errSessionStore
	}
	return value, nil
}

func createGroupComment(ctx context.Context, tx *sql.Tx, actor, postAuthor int64, in groupCommentMutation, storage StorageURLPolicy) (groupComment, error) {
	gb, ab, pb := sql.Named("group_id", in.group), sql.Named("user_id", actor), sql.Named("post_id", in.post)
	allowed, err := checkGroupContentPermission(ctx, tx, canCommentGroupContentSQL, ab, gb)
	if err != nil {
		return groupComment{}, err
	}
	if !allowed {
		return groupComment{}, &groupMembershipFailure{422, "只有群组成员可以评论"}
	}
	target := postAuthor
	if in.parent != nil {
		target, err = requireGroupCommentAuthor(ctx, tx, pb, sql.Named("comment_id", *in.parent))
		if err != nil {
			return groupComment{}, err
		}
		if target != postAuthor {
			if err := requireVisibleGroupAuthor(ctx, tx, actor, target, "群组评论不存在"); err != nil {
				return groupComment{}, err
			}
		}
	}
	if in.reply != nil && *in.reply != target {
		return groupComment{}, &groupMembershipFailure{422, "回复用户与目标不匹配"}
	}
	if in.parent != nil {
		in.reply = &target
	}
	if err := checkPublishAccess(ctx, tx, actor); err != nil {
		return groupComment{}, err
	}
	var id int64
	if tx.QueryRowContext(ctx, "SELECT seq_group_comment_id.NEXTVAL AS id FROM dual").Scan(&id) != nil || id < 1 || id > maxSocketID {
		return groupComment{}, errSessionStore
	}
	cb := sql.Named("comment_id", id)
	if writeOneChatRow(ctx, tx, insertGroupCommentSQL, cb, pb, ab, sql.Named("parent_comment_id", in.parent),
		sql.Named("reply_to_user_id", in.reply), sql.Named("content", in.content)) != nil {
		return groupComment{}, errSessionStore
	}
	var row groupCommentRow
	if tx.QueryRowContext(ctx, readCreatedGroupCommentSQL, pb, cb).Scan(row.destinations()...) != nil {
		return groupComment{}, errSessionStore
	}
	result, err := hydrateGroupComment(ctx, tx, actor, row, storage)
	if visibilityErr := verifyGroupCommentTargets(ctx, tx, actor, postAuthor, target); visibilityErr != nil {
		return groupComment{}, visibilityErr
	}
	if err != nil {
		return groupComment{}, errSessionStore
	}
	return result, nil
}

func verifyGroupCommentTargets(ctx context.Context, tx *sql.Tx, actor, postAuthor, commentAuthor int64) error {
	if err := requireVisibleGroupAuthor(ctx, tx, actor, postAuthor, "群组帖子不存在"); err != nil {
		return err
	}
	if commentAuthor == postAuthor {
		return nil
	}
	return requireVisibleGroupAuthor(ctx, tx, actor, commentAuthor, "群组评论不存在")
}

func changeGroupComment(ctx context.Context, tx *sql.Tx, actor, postAuthor int64, in groupCommentMutation) (any, error) {
	gb, ab, pb, cb := sql.Named("group_id", in.group), sql.Named("user_id", actor), sql.Named("post_id", in.post), sql.Named("comment_id", in.comment)
	author, err := requireGroupCommentAuthor(ctx, tx, pb, cb)
	if err != nil {
		return nil, err
	}
	if in.action == "delete" {
		if actor != author {
			allowed, err := checkGroupContentPermission(ctx, tx, canModerateGroupContentSQL, ab, gb)
			if err != nil {
				return nil, err
			}
			if !allowed {
				return nil, &groupMembershipFailure{422, "无权删除评论"}
			}
		}
		if writeOneChatRow(ctx, tx, deleteGroupCommentSQL, ab, pb, cb) != nil {
			return nil, errSessionStore
		}
		return nil, nil
	}
	if author != postAuthor {
		if err := requireVisibleGroupAuthor(ctx, tx, actor, author, "群组评论不存在"); err != nil {
			return nil, err
		}
	}
	liked := in.action == "like"
	query := unlikeGroupCommentSQL
	if liked {
		query = likeGroupCommentSQL
	}
	if _, err := tx.ExecContext(ctx, query, cb, ab); err != nil {
		return nil, errSessionStore
	}
	var count int64
	if tx.QueryRowContext(ctx, "SELECT likes_count FROM n_group_comments WHERE comment_id=:comment_id", cb).Scan(&count) != nil {
		return nil, errSessionStore
	}
	if err := verifyGroupCommentTargets(ctx, tx, actor, postAuthor, author); err != nil {
		return nil, err
	}
	return map[string]any{"comment_id": in.comment, "is_liked": liked, "likes_count": count}, nil
}

func parseGroupCommentBody(raw []byte, in *groupCommentMutation) string {
	var obj map[string]json.RawMessage
	if json.Unmarshal(raw, &obj) != nil || obj == nil {
		return "请求体必须是 JSON 对象"
	}
	var content *string
	if json.Unmarshal(obj["content"], &content) != nil || content == nil {
		return "content 参数错误"
	}
	in.content = strings.TrimFunc(*content, jsTrimSpace)
	if in.content == "" || len(in.content) > 1000 {
		return "content 参数错误"
	}
	for _, field := range []struct {
		key    string
		target **int64
	}{
		{"parent_comment_id", &in.parent}, {"reply_to_user_id", &in.reply},
	} {
		if value, ok := obj[field.key]; ok {
			var number *float64
			if json.Unmarshal(value, &number) != nil ||
				number != nil && (*number < 1 || *number > maxSocketID || float64(int64(*number)) != *number) {
				return field.key + " 参数错误"
			}
			if number != nil {
				id := int64(*number)
				*field.target = &id
			}
		}
	}
	return ""
}

func groupCommentWriteRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository, config RefreshConfig) bool {
	path, ok := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/groups/")
	parts := strings.Split(path, "/")
	if !ok || len(parts) < 4 || parts[1] != "posts" || parts[3] != "comments" {
		return false
	}
	var in groupCommentMutation
	var message string
	switch {
	case len(parts) == 4 && r.Method == http.MethodPost:
		in.action, message = "create", "group comment created"
	case len(parts) == 5 && r.Method == http.MethodDelete:
		in.action, message = "delete", "group comment deleted"
	case len(parts) == 6 && parts[5] == "likes" && (r.Method == http.MethodPost || r.Method == http.MethodDelete):
		in.action, message = "like", "success"
		if r.Method == http.MethodDelete {
			in.action = "unlike"
		}
	default:
		return false
	}
	actor, group, valid := interactionIdentity(w, r, codec, repo, parts[0])
	if !valid {
		return true
	}
	in.group = group
	in.post, valid = groupContentPostID(parts[2])
	if !valid {
		respond(w, 400, 40001, "post_id 参数错误", nil)
		return true
	}
	if len(parts) > 4 {
		in.comment, valid = groupContentPostID(parts[4])
		if !valid {
			respond(w, 400, 40001, "comment_id 参数错误", nil)
			return true
		}
	}
	if in.action == "create" {
		raw, err := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
		if err != nil || len(raw) > 1<<20 {
			respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
			return true
		}
		if bad := parseGroupCommentBody(raw, &in); bad != "" {
			respond(w, 400, 40001, bad, nil)
			return true
		}
	}
	store, ok := repo.(groupCommentWriteStore)
	if !ok {
		groupInviteReadError(w, errSessionStore)
		return true
	}
	result, err := store.WriteGroupComment(r.Context(), actor, in, config.Storage)
	if err != nil {
		groupInviteReadError(w, err)
		return true
	}
	if comment, created := result.(groupComment); in.action == "create" && created {
		if notices, ok := repo.(groupCommentNoticeStore); ok {
			if notifyGroupComment(r.Context(), repo, notices, config, actor, in.group, comment) != nil {
				log.Print("group comment notification unavailable")
			}
		}
	}
	respond(w, 200, 200, message, result)
	return true
}

type groupCommentNoticeStore interface {
	postNotificationDeliveryStore
	GroupCommentRecipients(context.Context, int64, int64, int64, int64) ([]groupPostRecipient, error)
}

const groupCommentRecipientsSQL = `WITH current_reply AS (
  SELECT c.comment_id,c.post_id,c.parent_comment_id,p.author_id AS post_author,g.group_id,g.name,g.privacy
  FROM n_group_comments c
  JOIN n_group_posts p ON p.post_id=c.post_id AND p.is_deleted=0
  JOIN n_users post_author ON post_author.user_id=p.author_id AND post_author.is_active=1
  JOIN n_groups g ON g.group_id=p.group_id AND g.is_active=1 AND g.is_deleted=0
  WHERE g.group_id=:group_id AND p.post_id=:post_id AND c.comment_id=:comment_id
    AND c.author_id=:actor_id AND c.is_deleted=0
), targets AS (
  SELECT post_author AS user_id FROM current_reply
  UNION
  SELECT parent.author_id AS user_id FROM current_reply r
  JOIN n_group_comments parent ON parent.comment_id=r.parent_comment_id
    AND parent.post_id=r.post_id AND parent.is_deleted=0
)
SELECT t.user_id,r.name AS group_name,COALESCE(u.display_name,u.username) AS actor_name
FROM targets t CROSS JOIN current_reply r
JOIN n_users u ON u.user_id=:actor_id AND u.is_active=1
JOIN n_users recipient ON recipient.user_id=t.user_id AND recipient.is_active=1
LEFT JOIN n_group_notification_preferences pref ON pref.group_id=r.group_id AND pref.user_id=t.user_id
WHERE t.user_id<>:actor_id AND NVL(pref.is_enabled,1)=1
  AND NOT EXISTS (SELECT 1 FROM n_user_blocks b
    WHERE (b.user_id=t.user_id AND b.target_user_id IN (:actor_id,r.post_author))
       OR (b.target_user_id=t.user_id AND b.user_id IN (:actor_id,r.post_author)))
  AND (r.privacy='public' OR EXISTS (SELECT 1 FROM n_group_members m
    WHERE m.group_id=r.group_id AND m.user_id=t.user_id AND m.status='active'))
ORDER BY t.user_id`

func (s OracleSessions) GroupCommentRecipients(ctx context.Context, actor, group, post, comment int64) ([]groupPostRecipient, error) {
	rows, err := s.DB.QueryContext(ctx, groupCommentRecipientsSQL, sql.Named("actor_id", actor), sql.Named("group_id", group), sql.Named("post_id", post), sql.Named("comment_id", comment))
	return readGroupNoticeRecipients(rows, err)
}

func notifyGroupComment(ctx context.Context, repo SessionRepository, store groupCommentNoticeStore, config RefreshConfig, actor, group int64, comment groupComment) error {
	rows, err := store.GroupCommentRecipients(ctx, actor, group, comment.Post, comment.ID)
	if err != nil {
		return err
	}
	parent := "null"
	if comment.Parent != nil {
		parent = fmt.Sprint(*comment.Parent)
	}
	kind := "group_comment"
	for _, recipient := range rows {
		input := notificationInput{UserID: recipient.id, ActorID: &actor, Type: kind, ResourceType: &kind, ResourceID: &comment.ID, Priority: "normal",
			Title: groupNoticeTitle(recipient.actor + " 评论了 " + recipient.group + " 的帖子"), Message: groupNoticeExcerpt(comment.Content),
			MetadataJSON: fmt.Sprintf(`{"group_id":%d,"post_id":%d,"comment_id":%d,"parent_comment_id":%s,"event":"group_comment_created"}`, group, comment.Post, comment.ID, parent)}
		if err := deliverPostCreateNotification(ctx, repo, store, config, input); err != nil {
			log.Print("group comment notification unavailable for recipient")
		}
	}
	return nil
}
