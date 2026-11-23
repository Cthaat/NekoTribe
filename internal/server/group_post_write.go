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
	"unicode/utf16"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type groupPostMutation struct {
	action                 string
	group, post            int64
	content, media, reason string
	pin, announcement      bool
	poll                   *postPollCreation
	markdown               *string
}

type groupPostWriteStore interface {
	WriteGroupPost(context.Context, int64, groupPostMutation, StorageURLPolicy) (any, error)
}

const lockGroupContentSQL = "SELECT group_id FROM n_groups WHERE group_id=:group_id AND is_active=1 AND is_deleted=0 FOR UPDATE"
const canViewGroupContentSQL = "SELECT fn_can_view_group(:user_id,:group_id) FROM dual"
const canPostGroupContentSQL = "SELECT fn_can_post_in_group(:user_id,:group_id) FROM dual"
const canModerateGroupContentSQL = "SELECT fn_has_group_permission(:user_id,:group_id,'moderator') FROM dual"
const groupAuthorVisibleSQL = `SELECT 1 AS visible FROM n_users u
WHERE u.user_id=:author_id AND u.is_active=1
  AND NOT EXISTS (SELECT 1 FROM n_user_blocks b
    WHERE (b.user_id=:viewer_id AND b.target_user_id=u.user_id)
       OR (b.target_user_id=:viewer_id AND b.user_id=u.user_id))`

const groupPostAuthorSQL = "SELECT author_id FROM n_group_posts WHERE group_id=:group_id AND post_id=:post_id AND is_deleted=0"
const insertGroupPostSQL = `INSERT INTO n_group_posts (post_id,group_id,author_id,content,media_urls,is_announcement)
VALUES (:post_id,:group_id,:user_id,:content,:media_urls,:is_announcement)`
const deleteGroupPostSQL = `UPDATE n_group_posts SET is_deleted=1,deleted_by=:user_id,delete_reason=:reason
WHERE group_id=:group_id AND post_id=:post_id AND is_deleted=0`
const pinGroupPostSQL = `UPDATE n_group_posts SET is_pinned=:is_pinned
WHERE group_id=:group_id AND post_id=:post_id AND is_deleted=0`
const likeGroupPostSQL = `INSERT INTO n_group_post_likes (post_id,user_id)
SELECT :post_id,:user_id FROM dual WHERE NOT EXISTS
(SELECT 1 FROM n_group_post_likes WHERE post_id=:post_id AND user_id=:user_id)`
const unlikeGroupPostSQL = "DELETE FROM n_group_post_likes WHERE post_id=:post_id AND user_id=:user_id"

func checkGroupContentPermission(ctx context.Context, tx *sql.Tx, query string, binds ...any) (bool, error) {
	var allowed int64
	if tx.QueryRowContext(ctx, query, binds...).Scan(&allowed) != nil {
		return false, errSessionStore
	}
	return allowed == 1, nil
}

func lockGroupContent(ctx context.Context, tx *sql.Tx, actor, group sql.NamedArg) error {
	var locked int64
	err := tx.QueryRowContext(ctx, lockGroupContentSQL, group).Scan(&locked)
	if errors.Is(err, sql.ErrNoRows) {
		return errGroupDetailMissing
	}
	if err != nil {
		return errSessionStore
	}
	visible, err := checkGroupContentPermission(ctx, tx, canViewGroupContentSQL, actor, group)
	if err != nil {
		return err
	}
	if !visible {
		return errGroupDetailMissing
	}
	return nil
}

func requireVisibleGroupAuthor(ctx context.Context, tx *sql.Tx, viewer, author int64, missing string) error {
	var visible int
	err := tx.QueryRowContext(ctx, groupAuthorVisibleSQL, sql.Named("viewer_id", viewer), sql.Named("author_id", author)).Scan(&visible)
	if errors.Is(err, sql.ErrNoRows) {
		return &groupMembershipFailure{404, missing}
	}
	if err != nil {
		return errSessionStore
	}
	return nil
}

func requireGroupPostAuthor(ctx context.Context, tx *sql.Tx, group, post sql.NamedArg) (int64, error) {
	var author int64
	err := tx.QueryRowContext(ctx, groupPostAuthorSQL, group, post).Scan(&author)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, &groupMembershipFailure{404, "群组帖子不存在"}
	}
	if err != nil {
		return 0, errSessionStore
	}
	return author, nil
}

func (s OracleSessions) WriteGroupPost(ctx context.Context, actor int64, in groupPostMutation, storage StorageURLPolicy) (any, error) {
	beginTx := s.DB.BeginTx
	if in.action == "create" && (in.poll != nil || in.markdown != nil) {
		conn, err := s.DB.Conn(ctx)
		if err != nil {
			return nil, errSessionStore
		}
		defer conn.Close()
		if err := checkPostCreationExtras(ctx, conn, in.poll, in.markdown); err != nil {
			return nil, err
		}
		beginTx = conn.BeginTx
	}
	tx, err := beginTx(ctx, nil)
	if err != nil {
		return nil, errSessionStore
	}
	defer tx.Rollback()
	gb, ab := sql.Named("group_id", in.group), sql.Named("user_id", actor)
	if err := lockGroupContent(ctx, tx, ab, gb); err != nil {
		return nil, err
	}
	result, err := writeGroupPost(ctx, tx, actor, in, storage)
	if err != nil {
		return nil, err
	}
	if tx.Commit() != nil {
		return nil, errSessionStore
	}
	return result, nil
}

func requireGroupPostCreationAccess(ctx context.Context, tx *sql.Tx, actor int64, in groupPostMutation) error {
	group, user := sql.Named("group_id", in.group), sql.Named("user_id", actor)
	allowed, err := checkGroupContentPermission(ctx, tx, canPostGroupContentSQL, user, group)
	if err != nil {
		return err
	}
	if !allowed {
		return &groupMembershipFailure{422, "无权发帖"}
	}
	if in.announcement {
		allowed, err := checkGroupContentPermission(ctx, tx, canModerateGroupContentSQL, user, group)
		if err != nil {
			return err
		}
		if !allowed {
			return &groupMembershipFailure{422, "无权发布公告"}
		}
	}
	return checkPublishAccess(ctx, tx, actor)
}

func createGroupPostOn(ctx context.Context, tx *sql.Tx, actor int64, in groupPostMutation, storage StorageURLPolicy) (int64, error) {
	if err := requireGroupPostCreationAccess(ctx, tx, actor, in); err != nil {
		return 0, err
	}
	urls := strings.Split(in.media, ",")
	if err := lockGroupMediaURLs(ctx, tx, urls, storage); err != nil {
		if errors.Is(err, errGroupImageMissing) {
			return 0, &groupMembershipFailure{400, "群组附件不存在或已删除"}
		}
		return 0, err
	}
	for _, url := range urls {
		if strings.Contains(url, ",") {
			return 0, &groupMembershipFailure{400, "media_urls 参数错误"}
		}
	}
	media := strings.Join(urls, ",")
	if len(media) > 2000 {
		return 0, &groupMembershipFailure{400, "media_urls 参数错误"}
	}
	var post int64
	if tx.QueryRowContext(ctx, "SELECT seq_group_post_id.NEXTVAL AS id FROM dual").Scan(&post) != nil || post < 1 || post > maxSocketID {
		return 0, errSessionStore
	}
	announcement := 0
	if in.announcement {
		announcement = 1
	}
	if err := writeOneChatRow(ctx, tx, insertGroupPostSQL, sql.Named("post_id", post),
		sql.Named("group_id", in.group), sql.Named("user_id", actor), sql.Named("content", in.content),
		sql.Named("media_urls", emptyGroupFilter(media)), sql.Named("is_announcement", announcement)); err != nil {
		return 0, err
	}
	if in.poll != nil {
		if err := insertPostPoll(ctx, tx, postPollTarget{group: in.group, post: post}, in.poll); err != nil {
			return 0, err
		}
	}
	if in.markdown != nil {
		if err := insertPostMarkdown(ctx, tx, post, true, *in.markdown); err != nil {
			return 0, err
		}
	}
	return post, nil
}

func writeGroupPost(ctx context.Context, tx *sql.Tx, actor int64, in groupPostMutation, storage StorageURLPolicy) (any, error) {
	gb, ab, pb := sql.Named("group_id", in.group), sql.Named("user_id", actor), sql.Named("post_id", in.post)
	if in.action == "create" {
		post, err := createGroupPostOn(ctx, tx, actor, in, storage)
		if err != nil {
			return nil, err
		}
		result, _, err := readGroupContent(ctx, tx, actor,
			groupContentRequest{group: in.group, post: post, page: SessionPage{Start: 1, End: 1}, order: "all"}, storage)
		if err != nil {
			return nil, errSessionStore
		}
		if in.poll != nil || in.markdown != nil {
			created, ok := result.(groupPost)
			if !ok {
				return nil, errSessionStore
			}
			if in.poll != nil {
				created.Poll, err = readPostPoll(ctx, tx, &actor, postPollTarget{group: in.group, post: post}, false)
				if err != nil {
					return nil, err
				}
				if created.Poll == nil {
					return nil, errSessionStore
				}
			}
			created.Markdown = in.markdown
			result = created
		}
		return result, nil
	}
	author, err := requireGroupPostAuthor(ctx, tx, gb, pb)
	if err != nil {
		return nil, err
	}
	checkVisibility := in.action == "like" || in.action == "unlike" || (in.action == "pin" && in.pin)
	if checkVisibility {
		if err := requireVisibleGroupAuthor(ctx, tx, actor, author, "群组帖子不存在"); err != nil {
			return nil, err
		}
	}
	if in.action == "pin" || in.action == "delete" && actor != author {
		allowed, err := checkGroupContentPermission(ctx, tx, canModerateGroupContentSQL, ab, gb)
		if err != nil {
			return nil, err
		}
		if !allowed {
			message := "无权删除帖子"
			if in.action == "pin" {
				message = "无权置顶帖子"
			}
			return nil, &groupMembershipFailure{422, message}
		}
	}
	switch in.action {
	case "delete":
		if writeOneChatRow(ctx, tx, deleteGroupPostSQL, ab, sql.Named("reason", emptyGroupFilter(in.reason)), gb, pb) != nil {
			return nil, errSessionStore
		}
		return nil, nil
	case "pin":
		pin := 0
		if in.pin {
			pin = 1
		}
		if writeOneChatRow(ctx, tx, pinGroupPostSQL, sql.Named("is_pinned", pin), gb, pb) != nil {
			return nil, errSessionStore
		}
		if checkVisibility {
			if err := requireVisibleGroupAuthor(ctx, tx, actor, author, "群组帖子不存在"); err != nil {
				return nil, err
			}
		}
		return map[string]any{"post_id": in.post, "is_pinned": in.pin}, nil
	case "like", "unlike":
		query := unlikeGroupPostSQL
		liked := in.action == "like"
		if liked {
			query = likeGroupPostSQL
		}
		if _, err := tx.ExecContext(ctx, query, pb, ab); err != nil {
			return nil, errSessionStore
		}
		var count int64
		if tx.QueryRowContext(ctx, "SELECT likes_count FROM n_group_posts WHERE post_id=:post_id", pb).Scan(&count) != nil {
			return nil, errSessionStore
		}
		if err := requireVisibleGroupAuthor(ctx, tx, actor, author, "群组帖子不存在"); err != nil {
			return nil, err
		}
		return map[string]any{"post_id": in.post, "is_liked": liked, "likes_count": count}, nil
	default:
		return nil, errSessionStore
	}
}

func parseGroupPostMutation(raw []byte, in *groupPostMutation) string {
	if in.action == "delete" && strings.Trim(string(raw), "\t\r\n ") == "" {
		return ""
	}
	var obj map[string]json.RawMessage
	if json.Unmarshal(raw, &obj) != nil || obj == nil {
		return "请求体必须是 JSON 对象"
	}
	switch in.action {
	case "create":
		var content *string
		if json.Unmarshal(obj["content"], &content) != nil || content == nil {
			return "content 参数错误"
		}
		in.content = strings.TrimFunc(*content, jsTrimSpace)
		if in.content == "" || len(in.content) > 4000 {
			return "content 参数错误"
		}
		if raw, exists := obj["is_announcement"]; exists {
			var value *bool
			if json.Unmarshal(raw, &value) != nil || value == nil {
				return "is_announcement 参数错误"
			}
			in.announcement = *value
		}
		if field, exists := obj["media_urls"]; exists {
			var urls []*string
			if json.Unmarshal(field, &urls) != nil || urls == nil {
				return "media_urls 参数错误"
			}
			media := make([]string, 0, len(urls))
			for _, raw := range urls {
				if raw == nil || strings.Contains(*raw, ",") {
					return "media_urls 参数错误"
				}
				if value := strings.TrimFunc(*raw, jsTrimSpace); value != "" {
					media = append(media, value)
				}
			}
			in.media = strings.Join(media, ",")
			if len(in.media) > 2000 {
				return "media_urls 参数错误"
			}
		}
		if field, exists := obj["poll"]; exists {
			var value any
			if json.Unmarshal(field, &value) != nil {
				return "poll 参数错误"
			}
			poll, err := parsePostPollCreation(value)
			if err != nil {
				return "poll 参数错误"
			}
			in.poll = poll
		}
		if field, exists := obj["markdown"]; exists {
			var value any
			if json.Unmarshal(field, &value) != nil {
				return "markdown 参数错误"
			}
			markdown, err := parsePostMarkdown(value)
			if err != nil {
				return "markdown 参数错误"
			}
			in.markdown = markdown
		}
	case "delete":
		if field, exists := obj["reason"]; exists {
			var reason *string
			if json.Unmarshal(field, &reason) != nil {
				return "reason 参数错误"
			}
			if reason != nil {
				in.reason = *reason
			}
			if len(in.reason) > 200 {
				return "reason 参数错误"
			}
		}
	case "pin":
		var pin *bool
		if json.Unmarshal(obj["is_pinned"], &pin) != nil || pin == nil {
			return "is_pinned 参数错误"
		}
		in.pin = *pin
	}
	return ""
}

func groupPostWriteRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repo SessionRepository, config RefreshConfig) bool {
	path, ok := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/groups/")
	parts := strings.Split(path, "/")
	if !ok || len(parts) < 2 || parts[1] != "posts" {
		return false
	}
	var in groupPostMutation
	var message string
	switch {
	case len(parts) == 2 && r.Method == http.MethodPost:
		in.action, message = "create", "group post created"
	case len(parts) == 3 && r.Method == http.MethodDelete:
		in.action, message = "delete", "group post deleted"
	case len(parts) == 4 && parts[3] == "pin-status" && r.Method == http.MethodPut:
		in.action, message = "pin", "pin status updated"
	case len(parts) == 4 && parts[3] == "likes" && (r.Method == http.MethodPost || r.Method == http.MethodDelete):
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
	if len(parts) > 2 {
		in.post, valid = groupContentPostID(parts[2])
		if !valid {
			respond(w, 400, 40001, "post_id 参数错误", nil)
			return true
		}
	}
	if in.action != "like" && in.action != "unlike" {
		raw, err := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
		if err != nil || len(raw) > 1<<20 {
			respond(w, 400, 40001, "请求体必须是 JSON 对象", nil)
			return true
		}
		if bad := parseGroupPostMutation(raw, &in); bad != "" {
			respond(w, 400, 40001, bad, nil)
			return true
		}
	}
	store, ok := repo.(groupPostWriteStore)
	if !ok {
		groupInviteReadError(w, errSessionStore)
		return true
	}
	result, err := store.WriteGroupPost(r.Context(), actor, in, config.Storage)
	if err != nil {
		if errors.Is(err, errPostPollCutoff) || errors.Is(err, errPostPollUnavailable) {
			failure := postPollFailure(err)
			respond(w, failure.status, failure.status*100+1, failure.message, nil)
			return true
		}
		if errors.Is(err, errPostMarkdownInvalid) || errors.Is(err, errPostMarkdownUnavailable) {
			failure := postMarkdownFailure(err)
			respond(w, failure.status, failure.status*100+1, failure.message, nil)
			return true
		}
		groupInviteReadError(w, err)
		return true
	}
	if post, created := result.(groupPost); in.action == "create" && created {
		if notices, ok := repo.(groupPostNoticeStore); ok {
			if notifyGroupPost(r.Context(), repo, notices, config, actor, post) != nil {
				log.Print("group post notification unavailable")
			}
		}
	}
	respond(w, 200, 200, message, result)
	return true
}

type groupPostNoticeStore interface {
	postNotificationDeliveryStore
	GroupPostRecipients(context.Context, int64, int64, int64) ([]groupPostRecipient, error)
}

type groupPostRecipient struct {
	id           int64
	group, actor string
}

const groupPostRecipientsSQL = `SELECT m.user_id,g.name,COALESCE(u.display_name,u.username) AS actor_name
FROM n_group_members m
JOIN n_groups g ON g.group_id=m.group_id AND g.is_active=1 AND g.is_deleted=0
JOIN n_group_posts p ON p.group_id=g.group_id AND p.post_id=:post_id AND p.is_deleted=0 AND p.author_id=:actor_id
JOIN n_users u ON u.user_id=:actor_id AND u.is_active=1
JOIN n_users recipient ON recipient.user_id=m.user_id AND recipient.is_active=1
LEFT JOIN n_group_notification_preferences pref ON pref.group_id=g.group_id AND pref.user_id=m.user_id
WHERE g.group_id=:group_id AND m.status='active' AND m.user_id<>:actor_id AND NVL(pref.is_enabled,1)=1
  AND NOT EXISTS (SELECT 1 FROM n_user_blocks b
    WHERE (b.user_id=m.user_id AND b.target_user_id=:actor_id)
       OR (b.target_user_id=m.user_id AND b.user_id=:actor_id))
ORDER BY m.user_id`

func (s OracleSessions) GroupPostRecipients(ctx context.Context, actor, group, post int64) ([]groupPostRecipient, error) {
	rows, err := s.DB.QueryContext(ctx, groupPostRecipientsSQL, sql.Named("actor_id", actor), sql.Named("group_id", group), sql.Named("post_id", post))
	return readGroupNoticeRecipients(rows, err)
}

func readGroupNoticeRecipients(rows *sql.Rows, err error) ([]groupPostRecipient, error) {
	if err != nil {
		return nil, errSessionStore
	}
	defer rows.Close()
	var out []groupPostRecipient
	for rows.Next() {
		var row groupPostRecipient
		if err := rows.Scan(&row.id, &row.group, &row.actor); err != nil {
			return nil, errSessionStore
		}
		out = append(out, row)
	}
	if rows.Err() != nil {
		return nil, errSessionStore
	}
	return out, nil
}

func groupNoticeTitle(value string) string {
	for len(value) > 200 {
		_, size := utf8.DecodeLastRuneInString(value)
		value = value[:len(value)-size]
	}
	return value
}

func groupNoticeExcerpt(value string) string {
	chars := utf16.Encode([]rune(value))
	if len(chars) > 120 {
		chars = chars[:120]
		if chars[119] >= 0xd800 && chars[119] <= 0xdbff {
			chars = chars[:119]
		}
	}
	return string(utf16.Decode(chars))
}

func notifyGroupPost(ctx context.Context, repo SessionRepository, store groupPostNoticeStore, config RefreshConfig, actor int64, post groupPost) error {
	rows, err := store.GroupPostRecipients(ctx, actor, post.Group, post.ID)
	if err != nil {
		return err
	}
	kind := "group_post"
	for _, recipient := range rows {
		input := notificationInput{UserID: recipient.id, ActorID: &actor, Type: kind, ResourceType: &kind, ResourceID: &post.ID, Priority: "normal",
			Title: groupNoticeTitle(recipient.actor + " 在 " + recipient.group + " 发布了新帖子"), Message: groupNoticeExcerpt(post.Content),
			MetadataJSON: fmt.Sprintf(`{"group_id":%d,"post_id":%d,"event":"group_post_created"}`, post.Group, post.ID)}
		if err := deliverPostCreateNotification(ctx, repo, store, config, input); err != nil {
			log.Print("group post notification unavailable for recipient")
		}
	}
	return nil
}
