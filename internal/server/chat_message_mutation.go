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
	"unicode/utf16"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type chatMutation struct {
	kind    string
	content string
	pinned  bool
	emoji   string
}

type chatMutationResult struct {
	channel int64
	message chatMessage
}

type chatMutationStore interface {
	MutateChatMessage(context.Context, int64, int64, chatMutation, StorageURLPolicy) (chatMutationResult, error)
}

var (
	errChatMessageMissing    = errors.New("chat message missing")
	errChatMutationForbidden = errors.New("chat message mutation forbidden")
)

const chatMutationChannelSQL = `SELECT channel_id FROM n_chat_messages WHERE message_id=:message_id AND is_deleted=0`
const chatReactionAddSQL = `MERGE INTO n_chat_message_reactions r
USING (SELECT :message_id AS message_id,:user_id AS user_id,:emoji AS emoji FROM dual) src
ON (r.message_id=src.message_id AND r.user_id=src.user_id AND r.emoji=src.emoji)
WHEN NOT MATCHED THEN INSERT (message_id,user_id,emoji) VALUES (src.message_id,src.user_id,src.emoji)`
const chatReactionRemoveSQL = `DELETE FROM n_chat_message_reactions WHERE message_id=:message_id AND user_id=:user_id AND emoji=:emoji`
const chatMutationTargetSQL = `SELECT author_id,message_type FROM n_chat_messages
WHERE message_id=:message_id AND channel_id=:channel_id AND is_deleted=0 FOR UPDATE`
const chatEditSQL = `UPDATE n_chat_messages SET content=:content,edited_at=CURRENT_TIMESTAMP,updated_at=CURRENT_TIMESTAMP
WHERE message_id=:message_id AND is_deleted=0`
const chatPinSQL = `UPDATE n_chat_messages SET is_pinned=:is_pinned,updated_at=CURRENT_TIMESTAMP
WHERE message_id=:message_id AND is_deleted=0`
const chatDeleteSQL = `UPDATE n_chat_messages SET is_deleted=1,deleted_by=:user_id,deleted_at=CURRENT_TIMESTAMP,updated_at=CURRENT_TIMESTAMP
WHERE message_id=:message_id AND is_deleted=0`
const chatDeleteSummarySQL = `UPDATE n_chat_channels c
SET message_count=GREATEST(c.message_count-1,0),
last_message_id=CASE WHEN c.last_message_id=:message_id THEN
 (SELECT MAX(m.message_id) FROM n_chat_messages m WHERE m.channel_id=c.channel_id AND m.is_deleted=0)
 ELSE c.last_message_id END,
last_message_at=CASE WHEN c.last_message_id=:message_id THEN
 (SELECT MAX(m.created_at) KEEP (DENSE_RANK LAST ORDER BY m.message_id) FROM n_chat_messages m
  WHERE m.channel_id=c.channel_id AND m.is_deleted=0)
 ELSE c.last_message_at END,
updated_at=CURRENT_TIMESTAMP WHERE c.channel_id=:channel_id AND c.is_deleted=0`

func (s OracleSessions) MutateChatMessage(ctx context.Context, user, id int64, change chatMutation, storage StorageURLPolicy) (chatMutationResult, error) {
	var out chatMutationResult
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return out, errSessionStore
	}
	defer tx.Rollback()
	messageBind, userBind := sql.Named("message_id", id), sql.Named("user_id", user)
	err = tx.QueryRowContext(ctx, chatMutationChannelSQL, messageBind).Scan(&out.channel)
	if errors.Is(err, sql.ErrNoRows) {
		return out, errChatMessageMissing
	}
	if err != nil {
		return out, errSessionStore
	}
	if err := lockChatChannelAccess(ctx, tx, user, out.channel); err != nil {
		return out, err
	}
	channelBind := sql.Named("channel_id", out.channel)
	var group, manage, author int64
	var channelType, status, messageType string
	if err := tx.QueryRowContext(ctx, chatSendAccessSQL, channelBind, userBind).Scan(&group, &channelType, &status, &manage); err != nil {
		return out, errSessionStore
	}
	err = tx.QueryRowContext(ctx, chatMutationTargetSQL, messageBind, channelBind).Scan(&author, &messageType)
	if errors.Is(err, sql.ErrNoRows) {
		return out, errChatMessageMissing
	}
	if err != nil {
		return out, errSessionStore
	}

	var query string
	args := []any{messageBind}
	switch change.kind {
	case "edit":
		if messageType != "text" {
			return out, errChatMessageMissing
		}
		if author != user || status != "active" {
			return out, errChatMutationForbidden
		}
		if err := checkPublishAccess(ctx, tx, user); err != nil {
			return out, err
		}
		query = chatEditSQL
		args = append(args, sql.Named("content", change.content))
	case "delete":
		if author != user && manage != 1 {
			return out, errChatMutationForbidden
		}
		query = chatDeleteSQL
		args = append(args, userBind)
	case "pin":
		if manage != 1 {
			return out, errChatMutationForbidden
		}
		query = chatPinSQL
		args = append(args, sql.Named("is_pinned", chatPrivateFlag(change.pinned)))
	case "react", "unreact":
		query = chatReactionAddSQL
		if change.kind == "unreact" {
			query = chatReactionRemoveSQL
		}
		args = append(args, userBind, sql.Named("emoji", change.emoji))
	default:
		return out, errSessionStore
	}
	if change.kind == "react" || change.kind == "unreact" {
		if _, err := tx.ExecContext(ctx, query, args...); err != nil {
			return out, errSessionStore
		}
	} else if err := writeOneChatRow(ctx, tx, query, args...); err != nil {
		return out, err
	}
	if change.kind == "delete" {
		if err := writeOneChatRow(ctx, tx, chatDeleteSummarySQL, messageBind, channelBind); err != nil {
			return out, err
		}
	} else {
		out.message, err = readChatMessage(ctx, tx, user, out.channel, id, manage == 1, storage)
		if err != nil {
			return out, err
		}
	}
	if tx.Commit() != nil {
		return chatMutationResult{}, errSessionStore
	}
	return out, nil
}

func writeOneChatRow(ctx context.Context, tx *sql.Tx, query string, args ...any) error {
	result, err := tx.ExecContext(ctx, query, args...)
	if err != nil {
		return errSessionStore
	}
	if rows, err := result.RowsAffected(); err != nil || rows != 1 {
		return errSessionStore
	}
	return nil
}

func readChatMessage(ctx context.Context, tx *sql.Tx, viewer, channel, id int64, manage bool, storage StorageURLPolicy) (chatMessage, error) {
	message, err := scanChatMessage(tx.QueryRowContext(ctx, chatMessageByIDSQL, sql.Named("viewer_id", viewer),
		sql.Named("channel_id", channel), sql.Named("message_id", id)), viewer, manage)
	if err != nil {
		return chatMessage{}, errSessionStore
	}
	message.Author.AvatarURL, err = normalizeAvatarURL(storage, message.Author.AvatarURL)
	items := []chatMessage{message}
	if err != nil || loadChatMessageDetails(ctx, tx, viewer, items, storage) != nil {
		return chatMessage{}, errSessionStore
	}
	return items[0], nil
}

func chatMutationRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) bool {
	path, ok := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/chat/messages/")
	if !ok {
		return false
	}
	raw := path
	change := chatMutation{}
	message := ""
	reactionID, reactions := strings.CutSuffix(path, "/reactions")
	switch {
	case reactions && r.Method == http.MethodPost:
		raw, change.kind, message = reactionID, "react", "chat reaction created"
	case reactions && r.Method == http.MethodDelete:
		raw, change.kind, message = reactionID, "unreact", "chat reaction deleted"
	case r.Method == http.MethodPatch:
		change.kind, message = "edit", "chat message updated"
	case r.Method == http.MethodDelete:
		change.kind, message = "delete", "chat message deleted"
	case r.Method == http.MethodPut:
		var matched bool
		raw, matched = strings.CutSuffix(path, "/pin-status")
		if !matched {
			return false
		}
		change.kind, message = "pin", "chat message pin status updated"
	default:
		return false
	}
	if raw == "" || strings.Contains(raw, "/") {
		return false
	}
	user, id, valid := interactionIdentity(w, r, codec, repository, raw)
	if !valid {
		return true
	}
	if change.kind != "delete" {
		raw, err := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
		var body map[string]any
		if err != nil || len(raw) > 1<<20 || json.Unmarshal(raw, &body) != nil || body == nil {
			respond(w, 400, 40001, "请求体格式错误", nil)
			return true
		}
		switch change.kind {
		case "edit":
			content, _ := body["content"].(string)
			change.content = strings.TrimFunc(content, jsTrimSpace)
			if change.content == "" || len(change.content) > 4000 {
				respond(w, 400, 40001, "content 参数错误", nil)
				return true
			}
		case "pin":
			change.pinned = chatChannelBoolean(body["is_pinned"])
		case "react", "unreact":
			emoji, _ := body["emoji"].(string)
			change.emoji = strings.TrimFunc(emoji, jsTrimSpace)
			if change.emoji == "" || len(change.emoji) > 32 || len(utf16.Encode([]rune(change.emoji))) > 16 {
				respond(w, 400, 40001, "emoji 参数错误", nil)
				return true
			}
		}
	}
	store, ok := repository.(chatMutationStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	out, err := store.MutateChatMessage(r.Context(), user, id, change, config.Storage)
	switch {
	case errors.Is(err, errChatMessageMissing):
		respond(w, 404, 40401, "聊天消息不存在", nil)
	case errors.Is(err, errPublishForbidden):
		respond(w, 403, 40301, publishPolicy.Message, nil)
	case errors.Is(err, errChatGroupForbidden), errors.Is(err, errChatMutationForbidden):
		respond(w, 403, 40301, "无权操作该聊天消息", nil)
	case err != nil:
		respond(w, 500, 50001, "服务器内部错误", nil)
	default:
		var data any
		event := chatRoomEvent{channel: out.channel, kind: "chat_message_deleted", messageID: id}
		if change.kind != "delete" {
			data = out.message
			event.kind = "chat_message_updated"
			if change.kind == "react" || change.kind == "unreact" {
				event.kind = "chat_reaction_updated"
			}
			event.message = &out.message
		}
		publisher, ok := config.NotificationPublisher.(chatRoomPublisher)
		if !ok || publisher.PublishChatRoomEvent(context.WithoutCancel(r.Context()), event) != nil {
			log.Print("chat message delivery unavailable")
		}
		respond(w, 200, 200, message, data)
	}
	return true
}
