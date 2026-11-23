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

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/auth"
)

type chatRealtimeDetailsDefinition struct {
	TypingMinIntervalMS int64 `json:"typing_min_interval_ms"`
	TypingTTLMS         int64 `json:"typing_ttl_ms"`
	SQL                 map[string]string
}

var chatRealtimeDetails = func() chatRealtimeDetailsDefinition {
	var contract chatRealtimeDetailsDefinition
	if json.Unmarshal(contracts.ChatRealtimeDetails, &contract) != nil ||
		contract.TypingMinIntervalMS <= 0 || contract.TypingTTLMS <= 0 ||
		contract.SQL["read_status"] == "" || contract.SQL["advance_read"] == "" ||
		contract.SQL["direct_read_delivery"] == "" || contract.SQL["direct_typing_peer"] == "" {
		panic("invalid chat realtime details contract")
	}
	return contract
}()

var (
	markDirectReadSQL   = chatRealtimeDetails.SQL["advance_read"]
	errDirectReadCursor = errors.New("invalid direct read cursor")
)

type directReadStatus struct {
	ConversationID               int64  `json:"conversation_id"`
	LastReadMessageID            *int64 `json:"last_read_message_id"`
	ParticipantLastReadMessageID *int64 `json:"participant_last_read_message_id"`
	UnreadCount                  int64  `json:"unread_count"`
}

type directReadAdvance struct {
	target, message int64
}

type directReadStore interface {
	DirectReadStatus(context.Context, int64, int64) (directReadStatus, error)
	AdvanceDirectRead(context.Context, int64, int64, int64) (directReadStatus, directReadAdvance, error)
}

type directReadPublisher interface {
	PublishDirectRead(context.Context, int64, int64, int64, int64) error
}

func publishDirectReadAdvance(ctx context.Context, events directEventPublisher, actor, conversation int64, advance directReadAdvance) {
	if publisher, ok := events.(directReadPublisher); ok && advance.message != 0 {
		if err := publisher.PublishDirectRead(context.WithoutCancel(ctx), actor, advance.target, conversation, advance.message); err != nil {
			log.Print("direct read status delivery unavailable")
		}
	}
}

func readDirectStatus(ctx context.Context, query notificationQueryer, actor, conversation int64) (directReadStatus, error) {
	var status directReadStatus
	err := query.QueryRowContext(ctx, chatRealtimeDetails.SQL["read_status"], sql.Named("conversation_id", conversation),
		sql.Named("user_id", actor)).Scan(&status.ConversationID, &status.LastReadMessageID, &status.ParticipantLastReadMessageID, &status.UnreadCount)
	if errors.Is(err, sql.ErrNoRows) {
		return directReadStatus{}, errDirectConversationForbidden
	}
	if err != nil {
		return directReadStatus{}, errSessionStore
	}
	return status, nil
}

func advanceDirectRead(ctx context.Context, tx *sql.Tx, actor, conversation, message int64) (bool, error) {
	count, err := postTxExecute(ctx, tx, markDirectReadSQL, sql.Named("conversation_id", conversation),
		sql.Named("user_id", actor), sql.Named("last_read_message_id", message))
	if err != nil || count < 0 || count > 1 {
		return false, errSessionStore
	}
	return count == 1, nil
}

func (s OracleSessions) DirectReadStatus(ctx context.Context, actor, conversation int64) (directReadStatus, error) {
	return readDirectStatus(ctx, s.DB, actor, conversation)
}

func (s OracleSessions) AdvanceDirectRead(ctx context.Context, actor, conversation, message int64) (directReadStatus, directReadAdvance, error) {
	return advanceDirectReadOn(ctx, s.DB, actor, conversation, message)
}

func advanceDirectReadOn(ctx context.Context, db directTxBeginner, actor, conversation, message int64) (directReadStatus, directReadAdvance, error) {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return directReadStatus{}, directReadAdvance{}, errSessionStore
	}
	defer tx.Rollback()
	var target int64
	err = tx.QueryRowContext(ctx, directSendAccessSQL, sql.Named("user_id", actor), sql.Named("conversation_id", conversation)).Scan(&target)
	if errors.Is(err, sql.ErrNoRows) {
		return directReadStatus{}, directReadAdvance{}, errDirectConversationForbidden
	}
	if err != nil || target < 1 || target > maxSocketID || target == actor {
		return directReadStatus{}, directReadAdvance{}, errSessionStore
	}
	if err := validateDirectReply(ctx, tx, conversation, &message); err != nil {
		if errors.Is(err, errDirectReply) {
			err = errDirectReadCursor
		}
		return directReadStatus{}, directReadAdvance{}, err
	}
	changed, err := advanceDirectRead(ctx, tx, actor, conversation, message)
	if err != nil {
		return directReadStatus{}, directReadAdvance{}, err
	}
	status, err := readDirectStatus(ctx, tx, actor, conversation)
	if err != nil {
		return directReadStatus{}, directReadAdvance{}, err
	}
	if tx.Commit() != nil {
		return directReadStatus{}, directReadAdvance{}, errSessionStore
	}
	var advance directReadAdvance
	if changed {
		advance = directReadAdvance{target, message}
	}
	return status, advance, nil
}

func parseDirectReadCursor(body []byte) int64 {
	var data map[string]json.RawMessage
	if json.Unmarshal(body, &data) != nil || len(data) != 1 || hasTooManyJSONMembers(body, 1) {
		return 0
	}
	return numericChatSocketID(data["last_read_message_id"])
}

func directReadStatusRoute(w http.ResponseWriter, r *http.Request, codec *auth.TokenManager, repository SessionRepository, config RefreshConfig) bool {
	if r.Method != http.MethodGet && r.Method != http.MethodPut {
		return false
	}
	path, ok := strings.CutPrefix(r.URL.EscapedPath(), "/api/v2/chat/direct-conversations/")
	if !ok {
		return false
	}
	rawID, ok := strings.CutSuffix(path, "/read-status")
	if !ok || strings.Contains(rawID, "/") {
		return false
	}
	w.Header().Set("Cache-Control", "private, no-store")
	actor, ok := interactionActor(w, r, codec, repository)
	if !ok {
		return true
	}
	conversation := directPathID(rawID)
	if conversation == 0 {
		respond(w, 400, 40001, "conversation_id 参数错误", nil)
		return true
	}
	store, ok := repository.(directReadStore)
	if !ok {
		respond(w, 500, 50001, "服务器内部错误", nil)
		return true
	}
	var status directReadStatus
	var err error
	if r.Method == http.MethodGet {
		status, err = store.DirectReadStatus(r.Context(), actor, conversation)
	} else {
		body, readErr := io.ReadAll(io.LimitReader(r.Body, 4097))
		cursor := parseDirectReadCursor(body)
		if readErr != nil || len(body) > 4096 || cursor == 0 {
			respond(w, 400, 40001, "last_read_message_id 参数错误", nil)
			return true
		}
		var advance directReadAdvance
		status, advance, err = store.AdvanceDirectRead(r.Context(), actor, conversation, cursor)
		if err == nil {
			publishDirectReadAdvance(r.Context(), config.DirectEvents, actor, conversation, advance)
		}
	}
	switch {
	case err == nil:
		respond(w, 200, 200, "success", status)
	case errors.Is(err, errDirectConversationForbidden):
		respond(w, 403, 40301, "无权访问该私聊会话", nil)
	case errors.Is(err, errDirectReadCursor):
		respond(w, 400, 40001, "last_read_message_id 参数错误", nil)
	default:
		respond(w, 500, 50001, "服务器内部错误", nil)
	}
	return true
}
