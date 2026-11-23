package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"strings"
)

var (
	errDirectRecipientMissing = errors.New("recipient missing")
	errDirectBlocked          = errors.New("direct message blocked")
	errDirectStrangers        = errors.New("recipient rejects stranger messages")
)

type directSendStore interface {
	SendDirectMessage(context.Context, int64, int64, string, StorageURLPolicy) (directSendResult, error)
	NotificationByID(context.Context, int64, int64) (NotificationItem, bool, error)
}

type directExtrasSendStore interface {
	SendDirectMessageWithExtras(context.Context, int64, int64, chatSendInput, StorageURLPolicy) (directSendResult, error)
}

type directSendResult struct {
	message DirectMessage
	target  int64
	notice  *notificationStored
	read    directReadAdvance
}

const directSendAccessSQL = `SELECT CASE WHEN user_low_id=:user_id THEN user_high_id ELSE user_low_id END
FROM n_direct_conversations WHERE conversation_id=:conversation_id AND is_deleted=0
AND (user_low_id=:user_id OR user_high_id=:user_id) FOR UPDATE`

const directRecipientSQL = `SELECT NVL(us.allow_dm_from_strangers,0),
fn_get_user_relationship(:sender_id,u.user_id),
(SELECT COUNT(*) FROM n_group_members sender
 JOIN n_group_members recipient ON recipient.group_id=sender.group_id
 JOIN n_groups g ON g.group_id=sender.group_id
 WHERE sender.user_id=:sender_id AND recipient.user_id=u.user_id
 AND sender.status IN ('active','muted') AND recipient.status IN ('active','muted')
 AND g.is_active=1 AND g.is_deleted=0)
FROM n_users u LEFT JOIN n_user_settings us ON us.user_id=u.user_id
WHERE u.user_id=:target_user_id AND u.is_active=1`

const directMessageByIDSQL = `SELECT dm.message_id,dm.conversation_id,dm.sender_id,dm.content,dm.is_deleted,
dm.created_at,dm.updated_at,dm.edited_at,dm.deleted_at,u.username,u.avatar_url,u.display_name,u.bio,u.location,u.website,
u.is_verified,u.followers_count,u.following_count,u.posts_count,u.likes_count,'self' AS relation
FROM n_direct_messages dm JOIN v_user_profile_public u ON u.user_id=dm.sender_id
WHERE dm.message_id=:message_id AND dm.sender_id=:sender_id`

func checkDirectRecipient(ctx context.Context, query notificationQueryer, sender, recipient int64) error {
	var strangers, groups int64
	var relation sql.NullString
	err := query.QueryRowContext(ctx, directRecipientSQL, sql.Named("sender_id", sender),
		sql.Named("target_user_id", recipient)).Scan(&strangers, &relation, &groups)
	if errors.Is(err, sql.ErrNoRows) {
		return errDirectRecipientMissing
	}
	if err != nil {
		return errSessionStore
	}
	switch relation.String {
	case "blocked_by", "blocking":
		return errDirectBlocked
	case "mutual_follow", "followed_by":
	default:
		if strangers != 1 && groups == 0 {
			return errDirectStrangers
		}
	}
	return nil
}

func (s OracleSessions) SendDirectMessage(ctx context.Context, actor, conversation int64, content string, storage StorageURLPolicy) (directSendResult, error) {
	return sendDirectMessageOn(ctx, s.DB, actor, conversation, chatSendInput{content: content}, storage)
}

func (s OracleSessions) SendDirectMessageWithExtras(ctx context.Context, actor, conversation int64, input chatSendInput, storage StorageURLPolicy) (directSendResult, error) {
	conn, err := s.directExtrasConnection(ctx)
	if err != nil {
		return directSendResult{}, err
	}
	defer conn.Close()
	return sendDirectMessageOn(ctx, conn, actor, conversation, input, storage)
}

func sendDirectMessageOn(ctx context.Context, connection directTxBeginner, actor, conversation int64, input chatSendInput, storage StorageURLPolicy) (directSendResult, error) {
	tx, err := connection.BeginTx(ctx, nil)
	if err != nil {
		return directSendResult{}, errSessionStore
	}
	defer tx.Rollback()
	var result directSendResult
	conversationBind := sql.Named("conversation_id", conversation)
	actorBind := sql.Named("user_id", actor)
	senderBind := sql.Named("sender_id", actor)
	err = tx.QueryRowContext(ctx, directSendAccessSQL, actorBind, conversationBind).Scan(&result.target)
	if errors.Is(err, sql.ErrNoRows) {
		return directSendResult{}, errDirectConversationForbidden
	}
	if err != nil || result.target == actor || result.target <= 0 {
		return directSendResult{}, errSessionStore
	}
	if err := checkDirectRecipient(ctx, tx, actor, result.target); err != nil {
		return directSendResult{}, err
	}
	if err := checkPublishAccess(ctx, tx, actor); err != nil {
		return directSendResult{}, err
	}
	if err := validateDirectReply(ctx, tx, conversation, input.reply); err != nil {
		return directSendResult{}, err
	}
	if err := lockDirectAttachments(ctx, tx, actor, input.media); err != nil {
		return directSendResult{}, err
	}
	var messageID int64
	if err := tx.QueryRowContext(ctx, `SELECT seq_direct_message_id.NEXTVAL FROM dual`).Scan(&messageID); err != nil || messageID < 1 || messageID > maxSocketID {
		return directSendResult{}, errSessionStore
	}
	messageBind := sql.Named("message_id", messageID)
	execOne := func(ctx context.Context, query string, binds ...any) error {
		result, err := tx.ExecContext(ctx, query, binds...)
		if err != nil {
			return errSessionStore
		}
		if count, err := result.RowsAffected(); err != nil || count != 1 {
			return errSessionStore
		}
		return nil
	}
	const insert = `INSERT INTO n_direct_messages (message_id,conversation_id,sender_id,content)
VALUES (:message_id,:conversation_id,:sender_id,:content)`
	const update = `UPDATE n_direct_conversations SET last_message_id=:message_id,last_message_at=CURRENT_TIMESTAMP,
message_count=message_count+1,updated_at=CURRENT_TIMESTAMP WHERE conversation_id=:conversation_id`
	content := input.content
	if content == "" {
		content = " "
	}
	if execOne(ctx, insert, messageBind, conversationBind, senderBind, sql.Named("content", content)) != nil {
		return directSendResult{}, errSessionStore
	}
	if input.reply != nil {
		if err := execOne(ctx, directExtrasContract.SQL["insert_reply"], messageBind, sql.Named("reply_to_message_id", *input.reply)); err != nil {
			return directSendResult{}, err
		}
	}
	for index, mediaID := range input.media {
		if err := execOne(ctx, directExtrasContract.SQL["insert_media"], messageBind, sql.Named("media_id", mediaID), sql.Named("position", index+1)); err != nil {
			return directSendResult{}, err
		}
	}
	if execOne(ctx, update, messageBind, conversationBind) != nil {
		return directSendResult{}, errSessionStore
	}
	changed, err := advanceDirectRead(ctx, tx, actor, conversation, messageID)
	if err != nil {
		return directSendResult{}, err
	}
	if changed {
		result.read = directReadAdvance{result.target, messageID}
	}
	result.message, err = scanDirectMessage(tx.QueryRowContext(ctx, directMessageByIDSQL, messageBind, senderBind), actor)
	if err != nil {
		return directSendResult{}, errSessionStore
	}
	if input.reply != nil || len(input.media) > 0 {
		items := []DirectMessage{result.message}
		if err := loadDirectMessageExtras(ctx, tx, actor, items, false); err != nil {
			return directSendResult{}, err
		}
		result.message = items[0]
	}
	author := &result.message.Author
	author.AvatarURL, err = normalizeAvatarURL(storage, author.AvatarURL)
	if err != nil {
		return directSendResult{}, errSessionStore
	}
	name := author.DisplayName
	if name == "" {
		name = author.Username
	}
	if name == "" {
		name = "有人"
	}
	preview := directPreview(input.content)
	if preview == "" {
		preview = "附件"
	}
	metadata, err := json.Marshal(map[string]any{"conversation_id": conversation, "event": "direct_message_created"})
	if err != nil {
		return directSendResult{}, errSessionStore
	}
	kind := "direct_message"
	result.notice, err = storeNotificationWith(ctx, tx, execOne, notificationInput{
		UserID: result.target, ActorID: &actor, Type: kind, Title: name + " 给你发来私信",
		Message: preview, ResourceType: &kind, ResourceID: &messageID, Priority: "normal", MetadataJSON: string(metadata),
	})
	if err != nil || tx.Commit() != nil {
		return directSendResult{}, errSessionStore
	}
	return result, nil
}

func directPreview(content string) string {
	normalized := strings.Join(strings.FieldsFunc(content, jsTrimSpace), " ")
	units := 0
	for offset, r := range normalized {
		width := 1
		if r > 0xffff {
			width = 2
		}
		if units+width > 80 {
			return normalized[:offset] + "..."
		}
		units += width
	}
	return normalized
}

func createDirectMessage(w http.ResponseWriter, r *http.Request, repository SessionRepository, config RefreshConfig, actor, conversation int64) {
	raw, readErr := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
	input, parseErr := parseDirectSend(raw)
	if readErr != nil || len(raw) > 1<<20 || parseErr != nil {
		respond(w, 400, 40001, "私信内容或附件参数错误", nil)
		return
	}
	store, ok := repository.(directSendStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	var result directSendResult
	var err error
	if input.reply != nil || len(input.media) > 0 {
		if extras, supported := repository.(directExtrasSendStore); supported {
			result, err = extras.SendDirectMessageWithExtras(r.Context(), actor, conversation, input, config.Storage)
		} else {
			err = errDirectExtrasUnavailable
		}
	} else {
		result, err = store.SendDirectMessage(r.Context(), actor, conversation, input.content, config.Storage)
	}
	switch {
	case errors.Is(err, errPublishForbidden):
		respond(w, 403, 40301, publishPolicy.Message, nil)
	case errors.Is(err, errDirectConversationForbidden):
		respond(w, 403, 40301, "无权访问该私聊会话", nil)
	case errors.Is(err, errDirectRecipientMissing):
		respond(w, 404, 40401, "用户不存在", nil)
	case errors.Is(err, errDirectBlocked):
		respond(w, 403, 40301, "无法向该用户发送私信", nil)
	case errors.Is(err, errDirectStrangers):
		respond(w, 403, 40301, "对方不接收陌生人私信", nil)
	case errors.Is(err, errDirectReply):
		respond(w, 400, 40001, "无法引用该私信", nil)
	case errors.Is(err, errDirectAttachment):
		respond(w, 404, 40401, "私信附件不存在或不可用", nil)
	case errors.Is(err, errDirectExtrasUnavailable):
		respond(w, 503, 50301, "私信服务暂不可用", nil)
	case err != nil:
		respond(w, 500, 50001, "服务器内部错误", nil)
	default:
		if config.DirectEvents == nil || config.DirectEvents.PublishDirect(r.Context(), actor, result.target, result.message) != nil {
			log.Print("direct message delivery unavailable")
		}
		publishDirectReadAdvance(r.Context(), config.DirectEvents, actor, conversation, result.read)
		if result.notice != nil && result.notice.PushEnabled {
			item, found, err := store.NotificationByID(r.Context(), result.target, result.notice.ID)
			if err != nil || !found || hydrateNotification(r.Context(), repository, result.target, &item, config.Storage) != nil ||
				config.NotificationPublisher == nil || config.NotificationPublisher.Publish(r.Context(), result.target, "notification_created", map[string]any{"notification": item, "notification_type": "direct_message"}) != nil {
				log.Print("notification delivery unavailable")
			}
		}
		respond(w, 200, 200, "direct message created", result.message)
	}
}
