package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

var errDirectMessageMissing = errors.New("direct message missing")
var errDirectDeleteForbidden = errors.New("direct delete forbidden")

var directDeleteSQL = func() struct {
	LockConversation, LockMessage, DeleteMessage, RefreshConversation, RedactNotification string
} {
	var statements struct {
		LockConversation, LockMessage, DeleteMessage, RefreshConversation, RedactNotification string
	}
	if json.Unmarshal(contracts.DirectMessageDelete, &statements) != nil || statements.RedactNotification == "" {
		panic("invalid direct message delete contract")
	}
	return statements
}()

type directDeleteStore interface {
	DeleteDirectMessage(context.Context, int64, int64, int64) (int64, error)
}

type directDeletePublisher interface {
	PublishDirectDeleted(context.Context, int64, int64, int64, int64) error
}

func (s OracleSessions) DeleteDirectMessage(ctx context.Context, actor, conversation, message int64) (int64, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return 0, errSessionStore
	}
	defer tx.Rollback()
	conversationID := sql.Named("conversation_id", conversation)
	messageID := sql.Named("message_id", message)
	userID := sql.Named("user_id", actor)
	var recipient, sender, deleted int64
	if err = tx.QueryRowContext(ctx, directDeleteSQL.LockConversation, userID, conversationID).Scan(&recipient); errors.Is(err, sql.ErrNoRows) {
		return 0, errDirectConversationForbidden
	} else if err != nil || recipient <= 0 || recipient > maxSocketID || recipient == actor {
		return 0, errSessionStore
	}
	if err = tx.QueryRowContext(ctx, directDeleteSQL.LockMessage, conversationID, messageID).Scan(&sender, &deleted); errors.Is(err, sql.ErrNoRows) {
		return 0, errDirectMessageMissing
	} else if err != nil {
		return 0, errSessionStore
	}
	if sender != actor {
		return 0, errDirectDeleteForbidden
	}
	if deleted == 1 {
		if tx.Rollback() != nil {
			return 0, errSessionStore
		}
		return 0, nil
	}
	execOne := func(statement string, args ...any) bool {
		result, err := tx.ExecContext(ctx, statement, args...)
		if err != nil {
			return false
		}
		count, err := result.RowsAffected()
		return err == nil && count == 1
	}
	if !execOne(directDeleteSQL.DeleteMessage, conversationID, messageID, userID) ||
		!execOne(directDeleteSQL.RefreshConversation, conversationID) {
		return 0, errSessionStore
	}
	if _, err := tx.ExecContext(ctx, directDeleteSQL.RedactNotification, messageID, userID); err != nil || tx.Commit() != nil {
		return 0, errSessionStore
	}
	return recipient, nil
}

func directMessageDeleteRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, events directEventPublisher) bool {
	if r.Method != http.MethodDelete {
		return false
	}
	path, ok := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/chat/direct-conversations/")
	parts := strings.Split(path, "/")
	if !ok || len(parts) != 3 || parts[1] != "messages" || parts[0] == "" || parts[2] == "" {
		return false
	}
	actor, ok := interactionActor(w, r, codec, repository)
	if !ok {
		return true
	}
	parse := func(raw string) int64 {
		decoded, err := url.PathUnescape(raw)
		if err != nil || !publicID.MatchString(decoded) {
			return 0
		}
		id, err := strconv.ParseInt(decoded, 10, 64)
		if err != nil || id > maxSocketID {
			return 0
		}
		return id
	}
	conversation, message := parse(parts[0]), parse(parts[2])
	if conversation == 0 {
		respond(w, 400, 40001, "conversation_id 参数错误", nil)
		return true
	}
	if message == 0 {
		respond(w, 400, 40001, "message_id 参数错误", nil)
		return true
	}
	store, ok := repository.(directDeleteStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	recipient, err := store.DeleteDirectMessage(r.Context(), actor, conversation, message)
	switch {
	case err == nil:
		if publisher, ok := events.(directDeletePublisher); ok && recipient > 0 {
			if err := publisher.PublishDirectDeleted(r.Context(), actor, recipient, conversation, message); err != nil {
				log.Print("direct deletion delivery unavailable")
			}
		}
		respond(w, 200, 200, "direct message deleted", nil)
	case errors.Is(err, errDirectConversationForbidden):
		respond(w, 403, 40301, "无权访问该私聊会话", nil)
	case errors.Is(err, errDirectDeleteForbidden):
		respond(w, 403, 40301, "无权删除该私信", nil)
	case errors.Is(err, errDirectMessageMissing):
		respond(w, 404, 40401, "私信不存在", nil)
	default:
		respond(w, 500, 50001, "服务器内部错误", nil)
	}
	return true
}
