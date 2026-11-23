package server

import (
	"context"
	"fmt"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
)

type chatSignalsTestSessions struct {
	socketSessions
	direct, roomActor, roomViewer atomic.Bool
}

func (s *chatSignalsTestSessions) CanReadChatChannel(_ context.Context, user, channel int64) (bool, error) {
	return channel == 7 && ((user == 42 && s.roomViewer.Load()) || (user == 9 && s.roomActor.Load())), nil
}

func (s *chatSignalsTestSessions) DirectTypingPeer(_ context.Context, viewer, conversation int64) (int64, error) {
	if !s.direct.Load() || conversation != 12 {
		return 0, nil
	}
	switch viewer {
	case 42:
		return 9, nil
	case 9:
		return 42, nil
	default:
		return 0, nil
	}
}

func (s *chatSignalsTestSessions) CanDeliverDirectRead(_ context.Context, user, conversation, reader, cursor int64) (bool, error) {
	return user == 42 && conversation == 12 && reader == 9 && cursor == 10, nil
}

type chatSignalsTestPublisher struct {
	directPublisherFunc
	typing chan typingSignal
}

func (p chatSignalsTestPublisher) PublishTyping(_ context.Context, signal typingSignal) error {
	p.typing <- signal
	return nil
}

func TestChatRealtimeTypingAndReadDeliveryFences(t *testing.T) {
	codec, tokens := fixture(t)
	sessions := &chatSignalsTestSessions{}
	sessions.direct.Store(true)
	sessions.roomViewer.Store(true)
	sessions.roomActor.Store(true)
	userEvents := &fakeSocketSource{queues: make(map[int64]chan []byte)}
	channelEvents := chatSocketTestSource{make(chan []byte, 8), make(chan int64, 1), make(chan struct{})}
	publisher := chatSignalsTestPublisher{typing: make(chan typingSignal, 8)}
	app := httptest.NewServer(NewHandlerWithConfig(codec, sessions, CorsPolicy{}, RefreshConfig{
		NotificationEvents: userEvents, ChatChannelEvents: channelEvents, DirectEvents: publisher,
	}))
	defer app.Close()
	ctx, stop := context.WithTimeout(context.Background(), 5*time.Second)
	defer stop()
	endpoint := "ws" + strings.TrimPrefix(app.URL, "http") + "/_ws?token=" + url.QueryEscape(tokens["access-hs256"])
	conn, _, err := websocket.Dial(ctx, endpoint, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	socketRead(t, conn)
	send := func(raw string) {
		t.Helper()
		if err := conn.Write(ctx, websocket.MessageText, []byte(raw)); err != nil {
			t.Fatal(err)
		}
	}
	assertPublished := func(want ...typingSignal) {
		t.Helper()
		send(`{"type":"ping"}`)
		if frame := socketRead(t, conn); frame["type"] != "pong" {
			t.Fatalf("unexpected self event: %v", frame)
		}
		for _, signal := range want {
			select {
			case got := <-publisher.typing:
				if got != signal {
					t.Fatalf("published %+v, want %+v", got, signal)
				}
			default:
				t.Fatalf("missing published signal %+v", signal)
			}
		}
		select {
		case got := <-publisher.typing:
			t.Fatalf("unexpected published signal %+v", got)
		default:
		}
	}
	send(`{"type":"typing_start","data":{"conversation_id":12,"user_id":9}}`)
	send(`{"type":"typing_start","data":{"conversation_id":12,"channel_id":7}}`)
	send(`{"type":"typing_start","data":{"conversation_id":12,"conversation_id":12}}`)
	send(`{"type":"typing_start","data":{"conversation_id":"12"}}`)
	send(`{"type":"typing_start","data":{"conversation_id":12},"timestamp":1}`)
	send(`{"type":"typing_start","data":{"channel_id":7}}`)
	assertPublished()

	send(`{"type":"chat_join_channel","data":{"channel_id":7}}`)
	socketRead(t, conn)
	if frame := socketRead(t, conn); frame["data"].(map[string]any)["code"] != "chat_channel_ready" {
		t.Fatal(frame)
	}

	send(`{"type":"typing_stop","data":{"conversation_id":12}}`)
	send(`{"type":"typing_stop","data":{"channel_id":7}}`)
	assertPublished(typingSignal{kind: "typing_stop", actor: 42, conversation: 12, peer: 9})

	timer := time.NewTimer(time.Duration(chatRealtimeDetails.TypingMinIntervalMS) * time.Millisecond)
	defer timer.Stop()
	select {
	case <-timer.C:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	send(`{"type":"typing_start","data":{"channel_id":7}}`)
	assertPublished(typingSignal{kind: "typing_start", actor: 42, channel: 7})

	now := time.Now().UnixMilli()
	typingFrame := func(actor, timestamp int64, scope string, id int64) string {
		return fmt.Sprintf(`{"type":"typing_start","data":{"%s":%d,"user_id":%d},"timestamp":%d}`, scope, id, actor, timestamp)
	}
	sendReceipt := func(record string) { userEvents.send(42, record) }
	sendReceipt(typingFrame(42, now, "conversation_id", 12))
	sendReceipt(typingFrame(8, now, "conversation_id", 12))
	sendReceipt(typingFrame(9, now-5000, "conversation_id", 12))
	sendReceipt(typingFrame(9, now, "conversation_id", 12))
	if frame := socketRead(t, conn); frame["type"] != "typing_start" || frame["timestamp"] != float64(now) ||
		frame["data"].(map[string]any)["user_id"] != float64(9) {
		t.Fatal(frame)
	}
	sessions.direct.Store(false)
	send(`{"type":"typing_stop","data":{"conversation_id":12}}`)
	assertPublished()
	sendReceipt(typingFrame(9, now, "conversation_id", 12))
	sendReceipt(`{"type":"direct_read_updated","data":{"conversation_id":12,"reader_id":9,"last_read_message_id":10,"unread_count":1},"timestamp":1}`)
	sendReceipt(`{"type":"direct_read_updated","data":{"conversation_id":12,"reader_id":8,"last_read_message_id":10},"timestamp":1}`)
	sendReceipt(`{"type":"direct_read_updated","data":{"conversation_id":12,"reader_id":9,"last_read_message_id":11},"timestamp":1}`)
	sendReceipt(`{"type":"direct_read_updated","data":{"conversation_id":12,"reader_id":9,"last_read_message_id":10},"timestamp":1}`)
	if frame := socketRead(t, conn); frame["type"] != directReadUpdatedEvent ||
		frame["data"].(map[string]any)["reader_id"] != float64(9) ||
		frame["data"].(map[string]any)["last_read_message_id"] != float64(10) {
		t.Fatal(frame)
	}

	// Denied originators and the viewer never appear, even on an authorized room.
	chatFrame := func(actor int64) []byte { return []byte(typingFrame(actor, now, "channel_id", 7)) }
	channelEvents.events <- chatFrame(42)
	channelEvents.events <- chatFrame(8)
	channelEvents.events <- chatFrame(9)
	if frame := socketRead(t, conn); frame["type"] != "typing_start" || frame["data"].(map[string]any)["user_id"] != float64(9) {
		t.Fatal(frame)
	}
	sessions.roomViewer.Store(false)
	channelEvents.events <- chatFrame(9)
	select {
	case <-channelEvents.left:
	case <-ctx.Done():
		t.Fatal("revoked room was not released")
	}
	assertPublished()
}

func TestChatRealtimeLocalPublisherRecipients(t *testing.T) {
	broker := &eventFake{}
	hub, err := NewLocalPresenceEvents(nil, &UserEventPublisher{client: broker, serverID: "test", clock: time.Now})
	if err != nil {
		t.Fatal(err)
	}
	defer hub.Close()
	ctx := context.Background()
	subscribe := func(id int64) <-chan []byte {
		t.Helper()
		events, _, err := hub.Subscribe(ctx, id)
		if err != nil {
			t.Fatal(err)
		}
		readRemoteStatus(t, events, "unavailable")
		return events
	}
	reader, peer, unrelated := subscribe(42), subscribe(9), subscribe(8)
	if err := hub.PublishTyping(ctx, typingSignal{kind: "typing_start", actor: 42, conversation: 12, peer: 9}); err != nil ||
		broker.calls != 1 || broker.channel != "ws:user:9" {
		t.Fatal("typing did not use only the peer's channel", err, broker.channel)
	}
	if err := hub.PublishDirectRead(ctx, 42, 9, 12, 10); err != nil || broker.calls != 3 || broker.channel != "ws:user:9" {
		t.Fatal("read status did not use both user channels", err, broker.channel)
	}
	if err := hub.PublishTyping(ctx, typingSignal{kind: "typing_start", actor: 42, channel: 7}); err != nil ||
		broker.calls != 4 || broker.channel != "ws:chat:channel:7" || !validChatSocketEvent(7, broker.payload) ||
		strings.Contains(string(broker.payload), `"room"`) {
		t.Fatal("channel typing did not use the existing broker room", err, broker.channel)
	}
	readLocalKind(t, peer, "typing_start")
	readLocalKind(t, reader, directReadUpdatedEvent)
	readLocalKind(t, peer, directReadUpdatedEvent)
	select {
	case <-unrelated:
		t.Fatal("private event delivered outside the conversation")
	case <-time.After(20 * time.Millisecond):
	}
}
