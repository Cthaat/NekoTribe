package server

import (
	"context"
	"database/sql"
	"errors"
	"io"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type directExactStore interface {
	GetDirectMessage(context.Context, int64, int64, int64, StorageURLPolicy) (DirectMessage, error)
}

type directReactionStore interface {
	SetDirectReaction(context.Context, int64, int64, int64, string, bool, StorageURLPolicy) (directReactionResult, error)
}

type directUpdatePublisher interface {
	PublishDirectUpdated(context.Context, int64, int64, int64, int64) error
}

type directReactionResult struct {
	message DirectMessage
	target  int64
	changed bool
}

func (s OracleSessions) SetDirectReaction(ctx context.Context, actor, conversation, message int64, emoji string, add bool, storage StorageURLPolicy) (directReactionResult, error) {
	if !validDirectEmoji(emoji) || strings.TrimFunc(emoji, jsTrimSpace) != emoji {
		return directReactionResult{}, errConversationInvalid
	}
	conn, err := s.directExtrasConnection(ctx)
	if err != nil {
		return directReactionResult{}, err
	}
	defer conn.Close()
	return setDirectReactionOn(ctx, conn, actor, conversation, message, emoji, add, storage)
}

func setDirectReactionOn(ctx context.Context, connection directTxBeginner, actor, conversation, message int64, emoji string, add bool, storage StorageURLPolicy) (directReactionResult, error) {
	tx, err := connection.BeginTx(ctx, nil)
	if err != nil {
		return directReactionResult{}, errSessionStore
	}
	defer tx.Rollback()
	var target, found int64
	conversationID, messageID, actorID := sql.Named("conversation_id", conversation), sql.Named("message_id", message), sql.Named("user_id", actor)
	err = tx.QueryRowContext(ctx, directSendAccessSQL, actorID, conversationID).Scan(&target)
	if errors.Is(err, sql.ErrNoRows) {
		return directReactionResult{}, errDirectConversationForbidden
	}
	if err != nil || target <= 0 || target > maxSocketID || target == actor {
		return directReactionResult{}, errSessionStore
	}
	err = tx.QueryRowContext(ctx, directExtrasContract.SQL["query_message"], conversationID, messageID).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		return directReactionResult{}, errDirectMessageMissing
	}
	if err != nil || found != message {
		return directReactionResult{}, errSessionStore
	}
	query := directExtrasContract.SQL["remove_reaction"]
	if add {
		query = directExtrasContract.SQL["add_reaction"]
	}
	changed, err := postTxExecute(ctx, tx, query, messageID, actorID, sql.Named("emoji", emoji))
	if err != nil || changed < 0 || changed > 1 {
		return directReactionResult{}, errSessionStore
	}
	result, err := readDirectExactMessage(ctx, tx, actor, conversation, message, storage)
	if err != nil {
		return directReactionResult{}, err
	}
	if tx.Commit() != nil {
		return directReactionResult{}, errSessionStore
	}
	return directReactionResult{message: result, target: target, changed: changed == 1}, nil
}

func directPathID(raw string) int64 {
	decoded, err := url.PathUnescape(raw)
	if err != nil || !publicID.MatchString(decoded) {
		return 0
	}
	id, err := strconv.ParseInt(decoded, 10, 64)
	if err != nil || id < 1 || id > maxSocketID {
		return 0
	}
	return id
}

func directMessageExtrasRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) bool {
	path, ok := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/chat/direct-conversations/")
	if !ok {
		return false
	}
	parts := strings.Split(path, "/")
	exact := len(parts) == 3 && parts[1] == "messages" && r.Method == http.MethodGet
	reaction := len(parts) == 4 && parts[1] == "messages" && parts[3] == "reactions" && (r.Method == http.MethodPost || r.Method == http.MethodDelete)
	if !exact && !reaction {
		return false
	}
	w.Header().Set("Cache-Control", "private, no-store")
	actor, ok := interactionActor(w, r, codec, repository)
	if !ok {
		return true
	}
	conversation, message := directPathID(parts[0]), directPathID(parts[2])
	if conversation == 0 || message == 0 {
		respond(w, 400, 40001, "私信参数错误", nil)
		return true
	}
	ctx := r.Context()
	var receipt DirectMessage
	var err error
	if exact {
		if store, ok := repository.(directExactStore); ok {
			receipt, err = store.GetDirectMessage(ctx, actor, conversation, message, config.Storage)
		} else {
			err = errDirectExtrasUnavailable
		}
	} else {
		body, readErr := io.ReadAll(io.LimitReader(r.Body, 4097))
		emoji, parseErr := parseDirectReaction(body)
		if readErr != nil || len(body) > 4096 || parseErr != nil {
			respond(w, 400, 40001, "emoji 参数错误", nil)
			return true
		}
		if store, ok := repository.(directReactionStore); ok {
			var result directReactionResult
			result, err = store.SetDirectReaction(ctx, actor, conversation, message, emoji, r.Method == http.MethodPost, config.Storage)
			if err == nil {
				receipt = result.message
				if publisher, ok := config.DirectEvents.(directUpdatePublisher); ok && result.changed {
					if err := publisher.PublishDirectUpdated(ctx, actor, result.target, conversation, message); err != nil {
						log.Print("direct message update delivery unavailable")
					}
				}
			}
		} else {
			err = errDirectExtrasUnavailable
		}
	}
	switch {
	case err == nil:
		respond(w, 200, 200, "success", receipt)
	case errors.Is(err, errDirectConversationForbidden):
		respond(w, 403, 40301, "无权访问该私聊会话", nil)
	case errors.Is(err, errDirectMessageMissing):
		respond(w, 404, 40401, "私信不存在", nil)
	case errors.Is(err, errDirectExtrasUnavailable):
		respond(w, 503, 50301, "私信服务暂不可用", nil)
	case errors.Is(err, errConversationInvalid):
		respond(w, 400, 40001, "私信参数错误", nil)
	default:
		respond(w, 500, 50001, "服务器内部错误", nil)
	}
	return true
}
