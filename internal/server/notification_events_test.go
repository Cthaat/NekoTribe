package server

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

func TestConfiguredPublisherUsesSameRedisSettingsAsSubscriber(t *testing.T) {
	values := map[string]string{"REDIS_URL": "rediss://:url-secret@redis.example:6380/2", "REDIS_HOST": "redis.internal", "REDIS_PORT": "6381", "REDIS_DB": "4", "REDIS_PASSWORD": "override-secret"}
	lookup := func(key string) (string, bool) { v, ok := values[key]; return v, ok }
	publisher, err := NewConfiguredUserEventPublisher(lookup)
	if err != nil {
		t.Fatal(err)
	}
	defer publisher.Close()
	client, ok := publisher.client.(*redis.Client)
	if !ok {
		t.Fatal("expected Redis client")
	}
	opts := client.Options()
	if opts.Addr != "redis.internal:6381" || opts.DB != 4 || opts.Password != "override-secret" || opts.TLSConfig == nil {
		t.Fatal("configuration mismatch")
	}
	values["REDIS_PORT"] = "bad-private-value"
	_, err = NewConfiguredUserEventPublisher(lookup)
	if err == nil || strings.Contains(err.Error(), "private") {
		t.Fatal("invalid config must fail safely")
	}
}

type eventFake struct {
	channel  string
	payload  []byte
	deadline bool
	fail     bool
	calls    int
	closed   bool
}

func (f *eventFake) Publish(ctx context.Context, channel string, message interface{}) *redis.IntCmd {
	f.calls++
	f.channel = channel
	f.payload = append([]byte(nil), message.([]byte)...)
	_, f.deadline = ctx.Deadline()
	if f.fail {
		return redis.NewIntResult(0, errors.New("private redis detail"))
	}
	return redis.NewIntResult(1, nil)
}
func (f *eventFake) Close() error { f.closed = true; return nil }

func TestNotificationEventSharedVectors(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/scenarios/notification-event-vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors struct {
		Cases []struct {
			ID, Type  string
			ServerID  string `json:"server_id"`
			UserID    int64  `json:"user_id"`
			Data      map[string]interface{}
			Timestamp int64
			Valid     bool
		} `json:"cases"`
	}
	if json.Unmarshal(raw, &vectors) != nil || len(vectors.Cases) != 8 {
		t.Fatal("invalid vectors")
	}
	for _, v := range vectors.Cases {
		t.Run(v.ID, func(t *testing.T) {
			original := v.Data["server_id"]
			channel, payload, err := buildNotificationEvent(v.UserID, v.Type, v.Data, v.ServerID, v.Timestamp)
			if (err == nil) != v.Valid {
				t.Fatal(channel, string(payload), err)
			}
			if !v.Valid {
				return
			}
			var result struct {
				Type      string                 `json:"type"`
				Data      map[string]interface{} `json:"data"`
				Timestamp int64                  `json:"timestamp"`
			}
			if json.Unmarshal(payload, &result) != nil || result.Type != v.Type || result.Timestamp != v.Timestamp || result.Data["server_id"] != v.ServerID || channel != "ws:user:"+strconv.FormatInt(v.UserID, 10) || v.Data["server_id"] != original {
				t.Fatal(channel, string(payload))
			}
			expected := make(map[string]interface{}, len(v.Data)+1)
			for key, value := range v.Data {
				expected[key] = value
			}
			expected["server_id"] = v.ServerID
			if !reflect.DeepEqual(result.Data, expected) {
				t.Fatal("event data changed")
			}
		})
	}
}
func TestPublisherTimeoutFailureAndClose(t *testing.T) {
	fake := &eventFake{}
	p := &UserEventPublisher{client: fake, serverID: "instance", clock: func() time.Time { return time.UnixMilli(1700000000123) }}
	if err := p.Publish(context.Background(), 42, "notification_created", map[string]interface{}{"notification_type": "like"}); err != nil || !fake.deadline || fake.calls != 1 || fake.channel != "ws:user:42" {
		t.Fatal(err, fake)
	}
	fake.fail = true
	err := p.Publish(context.Background(), 42, "notification_created", nil)
	if err != errNotificationEvent || strings.Contains(err.Error(), "private") || fake.calls != 2 {
		t.Fatal(err)
	}
	if err = p.Close(); err != nil || !fake.closed {
		t.Fatal(err)
	}
}

func TestPublisherRejectsCanceledAndInvalidRequestsBeforeSending(t *testing.T) {
	fake := &eventFake{}
	p := &UserEventPublisher{client: fake, serverID: "instance", clock: time.Now}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if p.Publish(ctx, 42, "notification_created", nil) == nil || p.Publish(context.Background(), 0, "notification_created", nil) == nil || fake.calls != 0 {
		t.Fatal("invalid request reached transport")
	}
}
func TestPublisherURLValidationDoesNotExposeSecrets(t *testing.T) {
	_, err := NewUserEventPublisher("invalid://user:secret@example.test")
	if err == nil || strings.Contains(err.Error(), "secret") {
		t.Fatal(err)
	}
	p, err := NewUserEventPublisher("redis://:synthetic-secret@127.0.0.1:6379/0")
	if err != nil {
		t.Fatal(err)
	}
	if p.Close() != nil {
		t.Fatal("close")
	}
}

func TestRedisClientPublishesToIsolatedProtocolServer(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	type result struct {
		channel, body string
		err           error
	}
	got := make(chan result, 1)
	go func() {
		conn, e := listener.Accept()
		if e != nil {
			got <- result{err: e}
			return
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
		reader := bufio.NewReader(conn)
		for {
			header, e := reader.ReadString('\n')
			if e != nil {
				got <- result{err: e}
				return
			}
			if !strings.HasPrefix(header, "*") {
				got <- result{err: errors.New("invalid array")}
				return
			}
			n, e := strconv.Atoi(strings.TrimSpace(header[1:]))
			if e != nil || n < 1 || n > 32 {
				got <- result{err: errors.New("invalid count")}
				return
			}
			args := make([]string, n)
			for i := range args {
				line, e := reader.ReadString('\n')
				if e != nil || !strings.HasPrefix(line, "$") {
					got <- result{err: errors.New("invalid bulk")}
					return
				}
				size, e := strconv.Atoi(strings.TrimSpace(line[1:]))
				if e != nil || size < 0 || size > 100000 {
					got <- result{err: errors.New("invalid length")}
					return
				}
				buf := make([]byte, size+2)
				if _, e = io.ReadFull(reader, buf); e != nil {
					got <- result{err: e}
					return
				}
				args[i] = string(buf[:size])
			}
			switch strings.ToUpper(args[0]) {
			case "HELLO":
				_, e = io.WriteString(conn, "-ERR unknown command 'HELLO'\r\n")
			case "PUBLISH":
				if len(args) != 3 {
					got <- result{err: errors.New("bad publish")}
					return
				}
				_, e = io.WriteString(conn, ":1\r\n")
				got <- result{channel: args[1], body: args[2], err: e}
				return
			default:
				_, e = io.WriteString(conn, "+OK\r\n")
			}
			if e != nil {
				got <- result{err: e}
				return
			}
		}
	}()
	pub, err := NewUserEventPublisher("redis://" + listener.Addr().String() + "/0")
	if err != nil {
		t.Fatal(err)
	}
	defer pub.Close()
	if err = pub.Publish(context.Background(), 42, "notification_created", map[string]interface{}{"notification_type": "like"}); err != nil {
		t.Fatal(err)
	}
	out := <-got
	if out.err != nil || out.channel != "ws:user:42" {
		t.Fatal(out.err, out.channel)
	}
	var event map[string]interface{}
	if json.Unmarshal([]byte(out.body), &event) != nil || event["type"] != "notification_created" {
		t.Fatal("invalid event")
	}
}
