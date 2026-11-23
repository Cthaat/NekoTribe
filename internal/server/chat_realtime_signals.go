package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"
)

const directReadUpdatedEvent = "direct_read_updated"

type socketEventFrame struct {
	Type      string                     `json:"type"`
	Room      *string                    `json:"room"`
	Data      map[string]json.RawMessage `json:"data"`
	Timestamp *float64                   `json:"timestamp"`
}

type directSignalAccess interface {
	DirectTypingPeer(context.Context, int64, int64) (int64, error)
	CanDeliverDirectRead(context.Context, int64, int64, int64, int64) (bool, error)
}

type typingPublisher interface {
	PublishTyping(context.Context, typingSignal) error
}

type typingSignal struct {
	kind                      string
	actor, conversation, peer int64
	channel                   int64
}

func (s OracleSessions) DirectTypingPeer(ctx context.Context, actor, conversation int64) (int64, error) {
	var peer int64
	err := s.DB.QueryRowContext(ctx, chatRealtimeDetails.SQL["direct_typing_peer"],
		sql.Named("user_id", actor), sql.Named("conversation_id", conversation)).Scan(&peer)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil || peer < 1 || peer > maxSocketID || peer == actor {
		return 0, errSessionStore
	}
	return peer, nil
}

func (s OracleSessions) CanDeliverDirectRead(ctx context.Context, viewer, conversation, reader, message int64) (bool, error) {
	var allowed int
	err := s.DB.QueryRowContext(ctx, chatRealtimeDetails.SQL["direct_read_delivery"],
		sql.Named("reader_id", reader), sql.Named("last_read_message_id", message),
		sql.Named("conversation_id", conversation), sql.Named("user_id", viewer)).Scan(&allowed)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, errSessionStore
	}
	return allowed == 1, nil
}

func isTypingEvent(kind string) bool {
	return kind == "typing_start" || kind == "typing_stop"
}

func socketSignalFields(data map[string]json.RawMessage, fields ...string) bool {
	size := len(fields)
	if raw, present := data["server_id"]; present {
		var server string
		if json.Unmarshal(raw, &server) != nil || server == "" {
			return false
		}
		size++
	}
	if len(data) != size {
		return false
	}
	for _, field := range fields {
		if numericChatSocketID(data[field]) == 0 {
			return false
		}
	}
	return true
}

func validSocketSignalFrame(body []byte, fields ...string) bool {
	return socketSignalFields(strictSocketSignalData(body, "type", "timestamp", "data"), fields...)
}

func validUserSocketSignal(kind string, body []byte) bool {
	if kind == directReadUpdatedEvent {
		return validSocketSignalFrame(body, "conversation_id", "reader_id", "last_read_message_id")
	}
	if isTypingEvent(kind) {
		return validSocketSignalFrame(body, "conversation_id", "user_id")
	}
	return false
}

func strictSocketSignalData(body []byte, fields ...string) map[string]json.RawMessage {
	var envelope map[string]json.RawMessage
	if json.Unmarshal(body, &envelope) != nil || len(envelope) != len(fields) || hasTooManyJSONMembers(body, len(fields)) {
		return nil
	}
	for _, field := range fields {
		if len(envelope[field]) == 0 {
			return nil
		}
	}
	var data map[string]json.RawMessage
	if raw := envelope["data"]; json.Unmarshal(raw, &data) != nil || hasTooManyJSONMembers(raw, len(data)) {
		return nil
	}
	return data
}

func parseTypingIngress(body []byte) (conversation, channel int64) {
	data := strictSocketSignalData(body, "type", "data")
	if len(data) != 1 {
		return 0, 0
	}
	return numericChatSocketID(data["conversation_id"]), numericChatSocketID(data["channel_id"])
}

func freshTypingSignal(timestamp *float64, now time.Time) bool {
	if !validSocketTimestamp(timestamp) {
		return false
	}
	age := now.UnixMilli() - int64(*timestamp)
	return age < chatRealtimeDetails.TypingTTLMS && age >= -chatRealtimeDetails.TypingTTLMS
}

func canDeliverUserSignal(ctx context.Context, access directSignalAccess, viewer int64, frame socketEventFrame) bool {
	conversation := numericChatSocketID(frame.Data["conversation_id"])
	checkCtx, finish := context.WithTimeout(ctx, 5*time.Second)
	defer finish()
	if frame.Type == directReadUpdatedEvent {
		reader := numericChatSocketID(frame.Data["reader_id"])
		message := numericChatSocketID(frame.Data["last_read_message_id"])
		ok, err := access.CanDeliverDirectRead(checkCtx, viewer, conversation, reader, message)
		return err == nil && ok
	}
	actor := numericChatSocketID(frame.Data["user_id"])
	if actor == viewer || !freshTypingSignal(frame.Timestamp, time.Now()) {
		return false
	}
	peer, err := access.DirectTypingPeer(checkCtx, viewer, conversation)
	return err == nil && peer == actor
}
