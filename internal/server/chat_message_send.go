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
	"slices"
	"strings"
	"time"
)

type chatSendInput struct {
	content string
	reply   *int64
	media   []int64
}

type chatSendStore interface {
	SendChatMessage(context.Context, int64, int64, chatSendInput, StorageURLPolicy) (chatMessage, error)
}

var (
	errChatCannotSpeak     = errors.New("cannot speak in channel")
	errChatUnsupportedKind = errors.New("channel does not support text")
	errChatReply           = errors.New("invalid reply")
	errChatAttachment      = errors.New("invalid attachment")
)

const chatSendAccessSQL = `SELECT c.group_id,c.channel_type,gm.status,
CASE WHEN gm.role IN ('owner','admin','moderator') THEN 1 ELSE 0 END
FROM n_chat_channels c JOIN n_group_members gm ON gm.group_id=c.group_id
WHERE c.channel_id=:channel_id AND gm.user_id=:user_id`

const chatSendReplySQL = `SELECT message_id FROM n_chat_messages
WHERE message_id=:message_id AND channel_id=:channel_id AND is_deleted=0 FOR UPDATE`

const chatSendMediaSQL = `SELECT media_id,storage_key FROM n_media_assets
WHERE media_id=:media_id AND owner_user_id=:user_id AND status='ready' FOR UPDATE`

const chatSendInsertSQL = `INSERT INTO n_chat_messages
(message_id,channel_id,group_id,author_id,message_type,content,reply_to_message_id)
VALUES (:message_id,:channel_id,:group_id,:user_id,'text',:content,:reply)`

const chatSendAttachSQL = `INSERT INTO n_chat_message_media (chat_message_media_id,message_id,media_id,position)
VALUES (seq_chat_message_media_id.NEXTVAL,:message_id,:media_id,:position)`

const chatSendSummarySQL = `UPDATE n_chat_channels SET last_message_id=:message_id,
last_message_at=CURRENT_TIMESTAMP,message_count=message_count+1,updated_at=CURRENT_TIMESTAMP
WHERE channel_id=:channel_id AND is_deleted=0`

func (s OracleSessions) SendChatMessage(ctx context.Context, user, channel int64, input chatSendInput, storage StorageURLPolicy) (chatMessage, error) {
	var message chatMessage
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return message, errSessionStore
	}
	defer tx.Rollback()
	if err := lockChatChannelAccess(ctx, tx, user, channel); err != nil {
		return message, err
	}

	channelBind, userBind := sql.Named("channel_id", channel), sql.Named("user_id", user)
	var group, manage int64
	var kind, status string
	if err := tx.QueryRowContext(ctx, chatSendAccessSQL, channelBind, userBind).Scan(&group, &kind, &status, &manage); err != nil {
		return message, errSessionStore
	}
	if status != "active" || kind == "announcement" && manage != 1 {
		return message, errChatCannotSpeak
	}
	if kind != "text" && kind != "announcement" {
		return message, errChatUnsupportedKind
	}

	if err := checkPublishAccess(ctx, tx, user); err != nil {
		return message, err
	}
	var found int64
	if input.reply != nil {
		err := tx.QueryRowContext(ctx, chatSendReplySQL, sql.Named("message_id", *input.reply), channelBind).Scan(&found)
		if errors.Is(err, sql.ErrNoRows) {
			return message, errChatReply
		}
		if err != nil {
			return message, errSessionStore
		}
	}
	// Lock assets in ID order across concurrent sends while preserving input order on insert.
	mediaLocks := slices.Clone(input.media)
	slices.Sort(mediaLocks)
	for _, media := range mediaLocks {
		var key sql.NullString
		mediaBind := sql.Named("media_id", media)
		err := tx.QueryRowContext(ctx, chatSendMediaSQL, mediaBind, userBind).Scan(&found, &key)
		if errors.Is(err, sql.ErrNoRows) {
			return message, errChatAttachment
		}
		if err != nil {
			return message, errSessionStore
		}
		if err := checkPrivateMediaBinding(ctx, tx, key.String, "chat", mediaBind, 0, errChatAttachment); err != nil {
			return message, err
		}
	}

	var id int64
	if err := tx.QueryRowContext(ctx, "SELECT seq_chat_message_id.NEXTVAL FROM dual").Scan(&id); err != nil || id < 1 || id > maxSocketID {
		return message, errSessionStore
	}
	messageBind := sql.Named("message_id", id)
	if writeOneChatRow(ctx, tx, chatSendInsertSQL, messageBind, channelBind, sql.Named("group_id", group), userBind,
		sql.Named("content", input.content), sql.Named("reply", input.reply)) != nil {
		return message, errSessionStore
	}
	for position, media := range input.media {
		if writeOneChatRow(ctx, tx, chatSendAttachSQL, messageBind, sql.Named("media_id", media), sql.Named("position", position+1)) != nil {
			return message, errSessionStore
		}
	}
	if writeOneChatRow(ctx, tx, chatSendSummarySQL, messageBind, channelBind) != nil {
		return message, errSessionStore
	}
	message, err = readChatMessage(ctx, tx, user, channel, id, manage == 1, storage)
	if err != nil || tx.Commit() != nil {
		return chatMessage{}, errSessionStore
	}
	return message, nil
}

func parseChatSend(r *http.Request) (chatSendInput, string) {
	var input chatSendInput
	raw, err := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
	var body map[string]any
	if err != nil || len(raw) > 1<<20 || json.Unmarshal(raw, &body) != nil || body == nil {
		return input, "请求体格式错误"
	}
	if value := body["content"]; value != nil {
		text, ok := value.(string)
		if !ok {
			return input, "content 参数错误"
		}
		input.content = strings.TrimFunc(text, jsTrimSpace)
	}
	if len(input.content) > 4000 {
		return input, "content 超过最大长度"
	}
	if value := body["reply_to_message_id"]; value != nil {
		id, ok := chatSendID(value)
		if !ok {
			return input, "reply_to_message_id 参数错误"
		}
		input.reply = &id
	}
	if value, supplied := body["media_ids"]; supplied {
		items, ok := value.([]any)
		if !ok || len(items) > 32 {
			return input, "media_ids 参数错误"
		}
		seen := make(map[int64]bool, len(items))
		for _, item := range items {
			id, ok := chatSendID(item)
			if !ok || seen[id] {
				return input, "media_ids 参数错误"
			}
			seen[id] = true
			input.media = append(input.media, id)
		}
	}
	if input.content == "" && len(input.media) == 0 {
		return input, "消息内容或附件不能为空"
	}
	return input, ""
}

func chatSendID(value any) (int64, bool) {
	number, ok := value.(float64)
	if !ok || number < 1 || number > maxSocketID || float64(int64(number)) != number {
		return 0, false
	}
	return int64(number), true
}

func sendChatMessage(w http.ResponseWriter, r *http.Request, repository SessionRepository, config RefreshConfig, user, channel int64) {
	input, failure := parseChatSend(r)
	if failure != "" {
		respond(w, 400, 40001, failure, nil)
		return
	}
	store, ok := repository.(chatSendStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return
	}
	message, err := store.SendChatMessage(r.Context(), user, channel, input, config.Storage)
	switch {
	case errors.Is(err, errPublishForbidden):
		respond(w, 403, 40301, publishPolicy.Message, nil)
	case errors.Is(err, errChatGroupForbidden):
		respond(w, 403, 40301, "无权访问该聊天频道", nil)
	case errors.Is(err, errChatCannotSpeak):
		respond(w, 403, 40301, "当前群组状态不允许发送消息", nil)
	case errors.Is(err, errChatUnsupportedKind):
		respond(w, 400, 40001, "该频道类型暂不支持文字消息", nil)
	case errors.Is(err, errChatReply):
		respond(w, 400, 40001, "回复消息不存在", nil)
	case errors.Is(err, errChatAttachment):
		respond(w, 400, 40001, "附件不存在或无权使用", nil)
	case err != nil:
		respond(w, 500, 50001, "服务器内部错误", nil)
	default:
		publisher, ok := config.NotificationPublisher.(chatMessagePublisher)
		if !ok || publisher.PublishChatMessage(context.WithoutCancel(r.Context()), message) != nil {
			log.Print("chat message delivery unavailable")
		}
		respond(w, 200, 200, "chat message created", message)
	}
}

type chatMessagePublisher interface {
	PublishChatMessage(context.Context, chatMessage) error
}

type chatRoomEvent struct {
	channel   int64
	kind      string
	messageID int64
	message   *chatMessage
}

type chatRoomPublisher interface {
	PublishChatRoomEvent(context.Context, chatRoomEvent) error
}

func (p *UserEventPublisher) PublishChatMessage(ctx context.Context, message chatMessage) error {
	return p.PublishChatRoomEvent(ctx, chatRoomEvent{channel: message.ChannelID, kind: "chat_message", messageID: message.ID, message: &message})
}

func (p *UserEventPublisher) PublishChatRoomEvent(ctx context.Context, event chatRoomEvent) error {
	if p == nil || p.client == nil || p.clock == nil || p.serverID == "" ||
		event.channel < 1 || event.channel > maxSocketID {
		return errNotificationEvent
	}
	data := map[string]any{"channel_id": event.channel, "server_id": p.serverID}
	if event.message != nil {
		message := *event.message
		if message.ChannelID != event.channel {
			return errNotificationEvent
		}
		message.CanDelete, message.CanPin = false, false
		message.Author.Relationship = SelfRelationship{Relation: "none"}
		message.Reactions = slices.Clone(message.Reactions)
		for i := range message.Reactions {
			message.Reactions[i].Reacted = false
		}
		data["message"] = message
		data["viewer_neutral"] = true
	} else {
		data["message_id"] = event.messageID
	}
	return p.publishChatRoomData(ctx, event.channel, event.kind, data)
}

func (p *UserEventPublisher) publishChatRoomData(ctx context.Context, channel int64, kind string, data map[string]any) error {
	if p == nil || p.client == nil || p.clock == nil || p.serverID == "" || channel < 1 || channel > maxSocketID {
		return errNotificationEvent
	}
	frame := map[string]any{"type": kind, "timestamp": p.clock().UnixMilli(), "data": data}
	if !isTypingEvent(kind) {
		frame["room"] = chatSocketRoom(channel)
	}
	payload, err := json.Marshal(frame)
	if err != nil || len(payload) > 262144 || !validChatSocketEvent(channel, payload) {
		return errNotificationEvent
	}
	ctx, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()
	if p.client.Publish(ctx, fmt.Sprintf("ws:chat:channel:%d", channel), payload).Err() != nil {
		return errNotificationEvent
	}
	return nil
}
