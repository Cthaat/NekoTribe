package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type chatChannelStatusStore interface {
	SetChatChannelRead(context.Context, int64, int64, int64) (chatChannelRead, error)
	SetChatChannelMute(context.Context, int64, int64, bool) error
}

type chatChannelRead struct {
	ChannelID int64  `json:"channel_id"`
	LastRead  *int64 `json:"last_read_message_id"`
	Unread    int64  `json:"unread_count"`
}

var errChatReadMessage = errors.New("message is unavailable in this channel")

const chatChannelGroupSQL = "SELECT group_id FROM n_chat_channels WHERE channel_id=:channel_id AND is_deleted=0"

const chatReadTargetSQL = `SELECT MAX(message_id) AS message_id FROM n_chat_messages
WHERE channel_id=:channel_id AND is_deleted=0 AND (:target=0 OR message_id=:target)`

const mergeChatReadSQL = `MERGE INTO n_chat_channel_reads r USING
(SELECT :channel_id AS channel_id,:user_id AS user_id,:message_id AS message_id FROM dual) src
ON (r.channel_id=src.channel_id AND r.user_id=src.user_id)
WHEN MATCHED THEN UPDATE SET r.last_read_message_id=CASE
 WHEN NVL(src.message_id,0)>NVL(r.last_read_message_id,0) THEN src.message_id ELSE r.last_read_message_id END,
 r.last_read_at=CURRENT_TIMESTAMP
WHEN NOT MATCHED THEN INSERT (channel_id,user_id,last_read_message_id,last_read_at)
VALUES (src.channel_id,src.user_id,src.message_id,CURRENT_TIMESTAMP)`

const chatReadResultSQL = `SELECT r.last_read_message_id,
(SELECT COUNT(*) FROM n_chat_messages m WHERE m.channel_id=r.channel_id
 AND m.is_deleted=0 AND m.message_id>NVL(r.last_read_message_id,0)) AS unread_count
FROM n_chat_channel_reads r WHERE r.channel_id=:channel_id AND r.user_id=:user_id`

const mergeChatMuteSQL = `MERGE INTO n_chat_channel_mutes m USING
(SELECT :channel_id AS channel_id,:user_id AS user_id FROM dual) src
ON (m.channel_id=src.channel_id AND m.user_id=src.user_id)
WHEN NOT MATCHED THEN INSERT (channel_id,user_id) VALUES (src.channel_id,src.user_id)`

const deleteChatMuteSQL = "DELETE FROM n_chat_channel_mutes WHERE channel_id=:channel_id AND user_id=:user_id"

func lockChatChannelAccess(ctx context.Context, tx *sql.Tx, user, channel int64) error {
	userBind, channelBind := sql.Named("user_id", user), sql.Named("channel_id", channel)
	var ignored, group int64
	// Check access before taking the group lock, then lock and recheck membership.
	if err := tx.QueryRowContext(ctx, readChatChannelSQL, userBind, channelBind).Scan(&ignored); err != nil {
		return chatChannelAccessError(err)
	}
	if err := tx.QueryRowContext(ctx, chatChannelGroupSQL, channelBind).Scan(&group); err != nil {
		return chatChannelAccessError(err)
	}
	if err := tx.QueryRowContext(ctx, lockChatGroupSQL, sql.Named("group_id", group)).Scan(&ignored); err != nil {
		return chatChannelAccessError(err)
	}
	if err := tx.QueryRowContext(ctx, readChatChannelSQL+" FOR UPDATE OF gm.role", userBind, channelBind).Scan(&ignored); err != nil {
		return chatChannelAccessError(err)
	}
	return nil
}

func (s OracleSessions) SetChatChannelRead(ctx context.Context, user, channel, target int64) (chatChannelRead, error) {
	out := chatChannelRead{ChannelID: channel}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return out, errSessionStore
	}
	defer tx.Rollback()
	if err := lockChatChannelAccess(ctx, tx, user, channel); err != nil {
		return out, err
	}
	channelBind, userBind := sql.Named("channel_id", channel), sql.Named("user_id", user)
	var candidate, current sql.NullInt64
	if err := tx.QueryRowContext(ctx, chatReadTargetSQL, channelBind, sql.Named("target", target)).Scan(&candidate); err != nil {
		return out, errSessionStore
	}
	if target != 0 && !candidate.Valid {
		return out, errChatReadMessage
	}
	if _, err := tx.ExecContext(ctx, mergeChatReadSQL, channelBind, userBind, sql.Named("message_id", candidate)); err != nil {
		return out, errSessionStore
	}
	if err := tx.QueryRowContext(ctx, chatReadResultSQL, channelBind, userBind).Scan(&current, &out.Unread); err != nil || tx.Commit() != nil {
		return out, errSessionStore
	}
	if current.Valid {
		out.LastRead = &current.Int64
	}
	return out, nil
}

func (s OracleSessions) SetChatChannelMute(ctx context.Context, user, channel int64, mute bool) error {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return errSessionStore
	}
	defer tx.Rollback()
	if err := lockChatChannelAccess(ctx, tx, user, channel); err != nil {
		return err
	}
	query := deleteChatMuteSQL
	if mute {
		query = mergeChatMuteSQL
	}
	if _, err := tx.ExecContext(ctx, query, sql.Named("channel_id", channel), sql.Named("user_id", user)); err != nil || tx.Commit() != nil {
		return errSessionStore
	}
	return nil
}

func chatChannelStatusRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository) bool {
	path, ok := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/chat/channels/")
	id, status, split := strings.Cut(path, "/")
	if r.Method != http.MethodPut || !ok || !split || id == "" || (status != "read-status" && status != "mute-status") {
		return false
	}
	user, channel, valid := interactionIdentity(w, r, codec, repository, id)
	if !valid {
		return true
	}
	read := status == "read-status"
	raw, err := io.ReadAll(io.LimitReader(r.Body, (1<<20)+1))
	var body map[string]any
	if err != nil || len(raw) > 1<<20 ||
		((!read || len(strings.TrimSpace(string(raw))) != 0) && json.Unmarshal(raw, &body) != nil) ||
		(!read && body == nil) {
		respond(w, 400, 40001, "请求体格式错误", nil)
		return true
	}
	var target int64
	if value := body["last_read_message_id"]; read && value != nil {
		number, valid := value.(float64)
		if !valid || number < 1 || number > maxSocketID || float64(int64(number)) != number {
			respond(w, 400, 40001, "last_read_message_id 参数错误", nil)
			return true
		}
		target = int64(number)
	}
	store, ok := repository.(chatChannelStatusStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	var data any
	message := "chat read status updated"
	if read {
		data, err = store.SetChatChannelRead(r.Context(), user, channel, target)
	} else {
		mute := chatChannelBoolean(body["is_muted"])
		err = store.SetChatChannelMute(r.Context(), user, channel, mute)
		data = struct {
			ChannelID int64 `json:"channel_id"`
			IsMuted   bool  `json:"is_muted"`
		}{channel, mute}
		message = "chat channel mute status updated"
	}
	switch {
	case errors.Is(err, errChatGroupForbidden):
		respond(w, 403, 40301, "无权访问该聊天频道", nil)
	case errors.Is(err, errChatReadMessage):
		respond(w, 400, 40001, "已读消息不存在或不属于该频道", nil)
	case err != nil:
		respond(w, 500, 50001, "服务器内部错误", nil)
	default:
		respond(w, 200, 200, message, data)
	}
	return true
}
