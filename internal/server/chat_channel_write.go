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

type chatChannelChange struct {
	create, remove bool
	name, category *string
	private        *bool
	kind           string
}

type chatChannelWriteStore interface {
	WriteChatChannel(context.Context, int64, int64, chatChannelChange) (chatChannel, error)
}

const chatChannelWriteAccessSQL = `SELECT c.group_id FROM n_chat_channels c
JOIN n_groups g ON g.group_id=c.group_id AND g.is_active=1 AND g.is_deleted=0
JOIN n_group_members gm ON gm.group_id=c.group_id AND gm.user_id=:user_id
WHERE c.channel_id=:channel_id AND c.is_deleted=0 AND gm.status IN ('active','muted')
AND gm.role IN ('owner','admin','moderator')`

const insertChatChannelSQL = `INSERT INTO n_chat_channels
(channel_id,group_id,name,channel_type,category,position,is_private,created_by)
VALUES (:channel_id,:group_id,:name,:channel_type,:category,
(SELECT NVL(MAX(position),0)+10 FROM n_chat_channels WHERE group_id=:group_id),
:is_private,:user_id)`

func (s OracleSessions) WriteChatChannel(ctx context.Context, user, id int64, change chatChannelChange) (chatChannel, error) {
	var channel chatChannel
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return channel, errSessionStore
	}
	defer tx.Rollback()
	userBind := sql.Named("user_id", user)
	channelBind := sql.Named("channel_id", id)
	group := id
	readGroup := func() error {
		return tx.QueryRowContext(ctx, chatChannelWriteAccessSQL, userBind, channelBind).Scan(&group)
	}
	if !change.create {
		if err := readGroup(); err != nil {
			return channel, chatChannelAccessError(err)
		}
	}
	groupBind := sql.Named("group_id", group)
	var owner, canManage int64
	if err := tx.QueryRowContext(ctx, lockChatGroupSQL, groupBind).Scan(&owner); err != nil {
		return channel, chatChannelAccessError(err)
	}
	err = tx.QueryRowContext(ctx, chatGroupMembershipSQL+" FOR UPDATE OF gm.role", userBind, groupBind).Scan(&canManage)
	if err != nil {
		return channel, chatChannelAccessError(err)
	}
	if canManage != 1 {
		return channel, errChatGroupForbidden
	}
	if !change.create {
		if err := readGroup(); err != nil {
			return channel, chatChannelAccessError(err)
		}
	}

	var query string
	var binds []any
	switch {
	case change.create:
		var channelID int64
		if err := tx.QueryRowContext(ctx, "SELECT seq_chat_channel_id.NEXTVAL FROM dual").Scan(&channelID); err != nil ||
			channelID < 1 || channelID > maxSocketID {
			return channel, errSessionStore
		}
		channelBind = sql.Named("channel_id", channelID)
		query = insertChatChannelSQL
		binds = []any{channelBind, groupBind, sql.Named("name", *change.name), sql.Named("channel_type", change.kind),
			sql.Named("category", *change.category), sql.Named("is_private", chatPrivateFlag(*change.private)), userBind}
	case change.remove:
		query = "UPDATE n_chat_channels SET is_deleted=1,updated_at=CURRENT_TIMESTAMP WHERE channel_id=:channel_id AND is_deleted=0"
		binds = []any{channelBind}
	default:
		clauses := make([]string, 0, 4)
		if change.name != nil {
			clauses = append(clauses, "name=:name")
			binds = append(binds, sql.Named("name", *change.name))
		}
		if change.category != nil {
			clauses = append(clauses, "category=:category")
			binds = append(binds, sql.Named("category", *change.category))
		}
		if change.private != nil {
			clauses = append(clauses, "is_private=:is_private")
			binds = append(binds, sql.Named("is_private", chatPrivateFlag(*change.private)))
		}
		if len(clauses) != 0 {
			clauses = append(clauses, "updated_at=CURRENT_TIMESTAMP")
			query = "UPDATE n_chat_channels SET " + strings.Join(clauses, ",") + " WHERE channel_id=:channel_id AND is_deleted=0"
			binds = append(binds, channelBind)
		}
	}
	if query != "" {
		result, err := tx.ExecContext(ctx, query, binds...)
		if err != nil {
			return channel, errSessionStore
		}
		if rows, err := result.RowsAffected(); err != nil || rows != 1 {
			return channel, errSessionStore
		}
	}
	if !change.remove {
		channel, err = scanChatChannel(tx.QueryRowContext(ctx, chatChannelByIDSQL, userBind, groupBind, channelBind))
		if err != nil {
			return chatChannel{}, errSessionStore
		}
	}
	if tx.Commit() != nil {
		return chatChannel{}, errSessionStore
	}
	return channel, nil
}

func chatChannelAccessError(err error) error {
	if errors.Is(err, sql.ErrNoRows) {
		return errChatGroupForbidden
	}
	return errSessionStore
}

func chatPrivateFlag(private bool) int64 {
	if private {
		return 1
	}
	return 0
}

func parseChatChannelChange(r *http.Request, create bool) (chatChannelChange, string) {
	change := chatChannelChange{create: create, kind: "text"}
	const maxBody = 1 << 20
	raw, err := io.ReadAll(io.LimitReader(r.Body, maxBody+1))
	if err != nil || len(raw) > maxBody {
		return change, "请求体格式错误"
	}
	var body map[string]any
	if json.Unmarshal(raw, &body) != nil || body == nil {
		return change, "请求体格式错误"
	}
	if value, supplied := body["name"]; supplied || create {
		name := strings.TrimSpace(chatChannelString(value, ""))
		if name == "" || len(name) > 100 {
			return change, "name 参数错误"
		}
		change.name = &name
	}
	if value, supplied := body["category"]; supplied || create {
		category := chatChannelString(value, "文字频道")
		if category == "" {
			category = "文字频道"
		}
		if len(category) > 50 {
			return change, "category 参数错误"
		}
		change.category = &category
	}
	if value, supplied := body["is_private"]; supplied || create {
		private := chatChannelBoolean(value)
		change.private = &private
	}
	if create {
		change.kind = chatChannelString(body["type"], "text")
		switch change.kind {
		case "text", "announcement", "voice", "video":
		default:
			return change, "type 参数错误"
		}
	}
	return change, ""
}

func chatChannelBoolean(value any) bool {
	switch value := value.(type) {
	case bool:
		return value
	case float64:
		return value == 1
	case string:
		return strings.EqualFold(value, "true") || strings.EqualFold(value, "yes") || value == "1"
	default:
		return false
	}
}

func chatChannelString(value any, fallback string) string {
	switch value := value.(type) {
	case string:
		return value
	case bool, float64:
		raw, _ := json.Marshal(value)
		return string(raw)
	default:
		return fallback
	}
}

func chatChannelWriteRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository) bool {
	path := r.URL.EscapedPath()
	var id string
	var matched bool
	switch r.Method {
	case http.MethodPost:
		if rest, ok := strings.CutPrefix(path, "/api/v2/chat/groups/"); ok {
			id, matched = strings.CutSuffix(rest, "/channels")
		}
	case http.MethodPatch, http.MethodDelete:
		id, matched = strings.CutPrefix(path, "/api/v2/chat/channels/")
	}
	if !matched || id == "" || strings.Contains(id, "/") {
		return false
	}
	user, target, ok := interactionIdentity(w, r, codec, repository, id)
	if !ok {
		return true
	}
	change := chatChannelChange{remove: true}
	if r.Method != http.MethodDelete {
		var message string
		change, message = parseChatChannelChange(r, r.Method == http.MethodPost)
		if message != "" {
			respond(w, 400, 40001, message, nil)
			return true
		}
	}
	store, ok := repository.(chatChannelWriteStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	channel, err := store.WriteChatChannel(r.Context(), user, target, change)
	switch {
	case errors.Is(err, errChatGroupForbidden):
		respond(w, 403, 40301, "需要群组管理权限", nil)
	case err != nil:
		respond(w, 500, 50001, "服务器内部错误", nil)
	case change.remove:
		respond(w, 200, 200, "chat channel deleted", nil)
	case change.create:
		respond(w, 200, 200, "chat channel created", channel)
	default:
		respond(w, 200, 200, "chat channel updated", channel)
	}
	return true
}
