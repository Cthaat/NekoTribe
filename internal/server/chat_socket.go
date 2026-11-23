package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

const maxSocketID = 9007199254740991
const maxSocketChatChannels = 64

type chatChannelAccess interface {
	CanReadChatChannel(context.Context, int64, int64) (bool, error)
}

type directMessageAccess interface {
	CanDeliverDirectMessage(context.Context, int64, int64, int64, bool) (bool, error)
}

var directMessageAccessSQL = func() string {
	var contract struct{ MessageAccessSQL string }
	if json.Unmarshal(contracts.DirectRealtimeAccess, &contract) != nil || contract.MessageAccessSQL == "" {
		panic("invalid direct realtime access contract")
	}
	return contract.MessageAccessSQL
}()

func (s OracleSessions) CanDeliverDirectMessage(ctx context.Context, user, conversation, message int64, deleted bool) (bool, error) {
	var allowed int
	deletedFlag := 0
	if deleted {
		deletedFlag = 1
	}
	err := s.DB.QueryRowContext(ctx, directMessageAccessSQL, sql.Named("conversation_id", conversation),
		sql.Named("message_id", message), sql.Named("user_id", user), sql.Named("is_deleted", deletedFlag)).Scan(&allowed)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, errSessionStore
	}
	return allowed == 1, nil
}

type chatChannelSource interface {
	SubscribeChatChannel(context.Context, int64) (<-chan []byte, func(), error)
}

// Keep the membership and private-channel rules aligned with v2RequireChatChannelAccess.
const readChatChannelSQL = `SELECT 1 FROM n_chat_channels c
JOIN n_groups g ON g.group_id = c.group_id
JOIN n_group_members gm ON gm.group_id = c.group_id AND gm.user_id = :user_id
JOIN n_users u ON u.user_id = gm.user_id AND u.is_active = 1 AND u.status = 'active'
WHERE c.channel_id = :channel_id AND c.is_deleted = 0
AND g.is_active = 1 AND g.is_deleted = 0 AND gm.status IN ('active', 'muted')
AND (c.is_private = 0 OR gm.role IN ('owner', 'admin', 'moderator'))`

func (s OracleSessions) CanReadChatChannel(ctx context.Context, userID, channelID int64) (bool, error) {
	var allowed int
	err := s.DB.QueryRowContext(ctx, readChatChannelSQL, sql.Named("user_id", userID), sql.Named("channel_id", channelID)).Scan(&allowed)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, errSessionStore
	}
	return allowed == 1, nil
}

func chatSocketID(raw json.RawMessage) int64 {
	id := numericChatSocketID(raw)
	if id == 0 {
		var text string
		if json.Unmarshal(raw, &text) != nil {
			return 0
		}
		id, _ = strconv.ParseInt(text, 10, 64)
	}
	if id < 1 || id > maxSocketID {
		return 0
	}
	return id
}

func numericChatSocketID(raw json.RawMessage) int64 {
	var id float64
	if json.Unmarshal(raw, &id) != nil || id < 1 || id > maxSocketID || id != float64(int64(id)) {
		return 0
	}
	return int64(id)
}

func directSocketMessageIDs(kind string, data map[string]json.RawMessage) (int64, int64) {
	id := numericChatSocketID(data["conversation_id"])
	if kind == "direct_message_deleted" || kind == "direct_message_updated" {
		for key := range data {
			if key != "conversation_id" && key != "message_id" && key != "server_id" {
				return 0, 0
			}
		}
		if value, present := data["server_id"]; present {
			var server string
			if json.Unmarshal(value, &server) != nil || server == "" {
				return 0, 0
			}
		}
		return id, numericChatSocketID(data["message_id"])
	}
	if kind != "direct_message" {
		return 0, 0
	}
	var message map[string]json.RawMessage
	if id == 0 || json.Unmarshal(data["direct_message"], &message) != nil || numericChatSocketID(message["conversation_id"]) != id {
		return 0, 0
	}
	return id, numericChatSocketID(message["message_id"])
}

func isDirectRealtimeEvent(kind string) bool {
	return kind == "direct_message" || kind == "direct_message_deleted" || kind == "direct_message_updated"
}

func validDirectSocketEvent(kind string, data map[string]json.RawMessage) bool {
	conversation, message := directSocketMessageIDs(kind, data)
	return conversation != 0 && message != 0
}

func chatSocketRoom(id int64) string {
	return fmt.Sprintf("chat:channel:%d", id)
}

func validChatSocketEvent(id int64, body []byte) bool {
	_, ok := parseChatSocketEvent(id, body)
	return ok
}

func parseChatSocketEvent(id int64, body []byte) (socketEventFrame, bool) {
	var frame socketEventFrame
	if json.Unmarshal(body, &frame) != nil || frame.Data == nil || !validSocketTimestamp(frame.Timestamp) ||
		(frame.Room != nil && *frame.Room != chatSocketRoom(id)) || numericChatSocketID(frame.Data["channel_id"]) != id {
		return frame, false
	}
	switch frame.Type {
	case "chat_message", "chat_message_updated", "chat_message_deleted", "chat_reaction_updated", "chat_channel_updated", "room_message":
		return frame, true
	case "typing_start", "typing_stop":
		return frame, validSocketSignalFrame(body, "channel_id", "user_id")
	}
	return frame, false
}

type chatSocketRoomSubscription struct {
	id     int64
	cancel context.CancelFunc
}

type chatSocketDelivery struct {
	room  *chatSocketRoomSubscription
	body  []byte
	frame socketEventFrame
}

func runChatSocketRoom(ctx context.Context, room *chatSocketRoomSubscription, source chatChannelSource, out chan<- chatSocketDelivery, overflow context.CancelFunc) {
	send := func(body []byte, frame socketEventFrame) bool {
		select {
		case out <- chatSocketDelivery{room, body, frame}:
			return true
		case <-ctx.Done():
			return false
		default:
			if ctx.Err() == nil {
				overflow()
			}
			return false
		}
	}
	for ctx.Err() == nil {
		events, stop, err := source.SubscribeChatChannel(ctx, room.id)
		if err == nil && events != nil && stop != nil {
			if !send(nil, socketEventFrame{}) { // Acknowledged subscription, before the first event.
				stop()
				return
			}
			for events != nil {
				select {
				case <-ctx.Done():
					stop()
					return
				case body, ok := <-events:
					if !ok {
						events = nil
						continue
					}
					if len(body) > 262144 {
						continue
					}
					frame, valid := parseChatSocketEvent(room.id, body)
					if !valid {
						continue
					}
					if !send(body, frame) {
						stop()
						return
					}
				}
			}
		}
		if stop != nil {
			stop()
		}
		timer := time.NewTimer(time.Second)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}
