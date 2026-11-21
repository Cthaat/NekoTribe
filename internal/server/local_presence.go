package server

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"sync"
	"time"
)

type localPresenceSubscription struct {
	input  chan []byte
	cancel context.CancelFunc
	user   int64
	echoes map[[32]byte]time.Time
}

// One instance is shared by the HTTP presence publisher and all local sockets.
// Remote adapters remain owned by the application and are not closed here.
type LocalPresenceEvents struct {
	source        NotificationEventSource
	publisher     *UserEventPublisher
	serverID      string
	clock         func() time.Time
	mu            sync.Mutex
	closed        bool
	next          uint64
	subscriptions map[uint64]*localPresenceSubscription
	running       sync.WaitGroup
}

func NewLocalPresenceEvents(source NotificationEventSource, publisher *UserEventPublisher) (*LocalPresenceEvents, error) {
	id := ""
	clock := time.Now
	if publisher != nil {
		if publisher.serverID == "" || publisher.clock == nil {
			return nil, errNotificationEvent
		}
		id = publisher.serverID
		clock = publisher.clock
	} else {
		value, err := randomUUID()
		if err != nil {
			return nil, errNotificationEvent
		}
		id = "go_" + value
	}
	return &LocalPresenceEvents{source: source, publisher: publisher, serverID: id, clock: clock, subscriptions: map[uint64]*localPresenceSubscription{}}, nil
}

func (h *LocalPresenceEvents) Subscribe(parent context.Context, user int64) (<-chan []byte, func(), error) {
	if parent.Err() != nil || user <= 0 || user > 9007199254740991 {
		return nil, nil, errNotificationEvent
	}
	ctx, cancel := context.WithCancel(parent)
	sub := &localPresenceSubscription{input: make(chan []byte, 16), cancel: cancel, user: user}
	out := make(chan []byte, 16)
	h.mu.Lock()
	if h.closed || len(h.subscriptions) >= 1024 {
		h.mu.Unlock()
		cancel()
		return nil, nil, errNotificationEvent
	}
	h.next++
	id := h.next
	h.subscriptions[id] = sub
	h.running.Add(1)
	h.mu.Unlock()
	var once sync.Once
	stop := func() { once.Do(func() { cancel(); h.mu.Lock(); delete(h.subscriptions, id); h.mu.Unlock() }) }
	state := "connecting"
	if h.source == nil {
		state = "unavailable"
	}
	out <- h.status(user, state)
	go func() {
		defer h.running.Done()
		defer close(out)
		defer stop()
		remote := make(chan []byte, 16)
		done := make(chan struct{})
		go func() { defer close(done); h.remote(ctx, sub, remote) }()
		defer func() { cancel(); <-done }()
		for {
			var body []byte
			select {
			case <-ctx.Done():
				return
			case body = <-sub.input:
			case body = <-remote:
			}
			select {
			case out <- body:
			default:
				return
			}
		}
	}()
	return out, stop, nil
}

func (h *LocalPresenceEvents) status(user int64, state string) []byte {
	body, _ := json.Marshal(map[string]interface{}{"type": "system_notification", "data": map[string]interface{}{"code": "realtime_status", "user_id": user, "server_id": h.serverID, "local_presence": true, "remote_events": state}, "timestamp": h.clock().UnixMilli()})
	return body
}

func (h *LocalPresenceEvents) remote(ctx context.Context, sub *localPresenceSubscription, out chan<- []byte) {
	if h.source == nil {
		return
	}
	last := "connecting"
	user := sub.user
	emit := func(body []byte) bool {
		select {
		case out <- append([]byte(nil), body...):
			return true
		case <-ctx.Done():
			return false
		}
	}
	status := func(state string) bool {
		if state == last {
			return true
		}
		last = state
		return emit(h.status(user, state))
	}
	wait := func() bool {
		timer := time.NewTimer(time.Second)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return false
		case <-timer.C:
			return true
		}
	}
	for ctx.Err() == nil {
		events, stop, err := h.source.Subscribe(ctx, user)
		if err != nil || events == nil || stop == nil {
			if stop != nil {
				stop()
			}
			if !status("unavailable") || !wait() {
				return
			}
			continue
		}
		if !status("connected") {
			stop()
			return
		}
		open := true
		for open {
			select {
			case <-ctx.Done():
				stop()
				return
			case body, ok := <-events:
				if !ok {
					open = false
					continue
				}
				if len(body) > 262144 {
					continue
				}
				var frame struct {
					Type string
					Data struct {
						ServerID string `json:"server_id"`
					}
				}
				if json.Unmarshal(body, &frame) != nil {
					continue
				}
				channel := fmt.Sprintf("ws:user:%d", user)
				if frame.Type == "presence_update" {
					channel = "ws:presence"
					if frame.Data.ServerID == h.serverID {
						continue
					}
				}
				if !socketEventMatchesChannel(channel, fmt.Sprintf("ws:user:%d", user), body) {
					continue
				}
				if (frame.Type == "direct_message" || frame.Type == "direct_message_deleted") && frame.Data.ServerID == h.serverID {
					h.mu.Lock()
					until := sub.echoes[sha256.Sum256(body)]
					h.mu.Unlock()
					if time.Now().Before(until) {
						continue
					}
				}
				if !emit(body) {
					stop()
					return
				}
			}
		}
		stop()
		if !status("unavailable") || !wait() {
			return
		}
	}
}

type directEventPublisher interface {
	PublishDirect(context.Context, int64, int64, DirectMessage) error
}

func (h *LocalPresenceEvents) PublishDirect(ctx context.Context, sender, recipient int64, message DirectMessage) error {
	return h.publishDirectEvent(ctx, sender, recipient, "direct_message", map[string]any{
		"conversation_id": message.ConversationID, "direct_message": message, "server_id": h.serverID,
	})
}

func (h *LocalPresenceEvents) PublishDirectDeleted(ctx context.Context, sender, recipient, conversation, message int64) error {
	return h.publishDirectEvent(ctx, sender, recipient, "direct_message_deleted", map[string]any{
		"conversation_id": conversation, "message_id": message, "server_id": h.serverID,
	})
}

func (h *LocalPresenceEvents) publishDirectEvent(ctx context.Context, sender, recipient int64, kind string, data map[string]any) error {
	if ctx.Err() != nil || sender == recipient || sender < 1 || recipient < 1 || sender > maxSocketID || recipient > maxSocketID {
		return errNotificationEvent
	}
	payload, err := json.Marshal(map[string]any{
		"type": kind, "timestamp": h.clock().UnixMilli(), "data": data,
	})
	if err != nil || len(payload) > 262144 || !socketEventMatchesChannel("ws:user", "ws:user", payload) {
		return errNotificationEvent
	}
	key, now := sha256.Sum256(payload), time.Now()
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return errNotificationEvent
	}
	for id, sub := range h.subscriptions {
		if sub.user != sender && sub.user != recipient {
			continue
		}
		select {
		case sub.input <- append([]byte(nil), payload...):
			if sub.echoes == nil {
				sub.echoes = make(map[[32]byte]time.Time)
			}
			if len(sub.echoes) >= 128 {
				var oldest [32]byte
				var expiry time.Time
				for candidate, until := range sub.echoes {
					if expiry.IsZero() || until.Before(expiry) {
						oldest, expiry = candidate, until
					}
				}
				delete(sub.echoes, oldest)
			}
			sub.echoes[key] = now.Add(time.Minute)
		default:
			sub.cancel()
			delete(h.subscriptions, id)
		}
	}
	h.mu.Unlock()
	if h.publisher == nil || h.publisher.client == nil {
		return errNotificationEvent
	}
	ctx, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()
	first := h.publisher.client.Publish(ctx, fmt.Sprintf("ws:user:%d", sender), payload).Err()
	second := h.publisher.client.Publish(ctx, fmt.Sprintf("ws:user:%d", recipient), payload).Err()
	if first != nil || second != nil {
		return errNotificationEvent
	}
	return nil
}

func (h *LocalPresenceEvents) PublishPresence(ctx context.Context, presence userPresence) error {
	if ctx.Err() != nil {
		return errNotificationEvent
	}
	payload, err := buildPresenceEvent(presence, h.serverID, h.clock().UnixMilli())
	if err != nil {
		return err
	}
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return errNotificationEvent
	}
	for id, sub := range h.subscriptions {
		select {
		case sub.input <- append([]byte(nil), payload...):
		default:
			sub.cancel()
			delete(h.subscriptions, id)
		}
	}
	h.mu.Unlock()
	if h.publisher == nil {
		return errNotificationEvent
	}
	return h.publisher.PublishPresence(ctx, presence)
}

func (h *LocalPresenceEvents) Close() error {
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return nil
	}
	h.closed = true
	for _, sub := range h.subscriptions {
		sub.cancel()
	}
	h.mu.Unlock()
	h.running.Wait()
	return nil
}
